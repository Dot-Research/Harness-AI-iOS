import Combine
import Foundation
import StoreKit
import UIKit
import DictationCore

/// App Store evidence is the only source of paid access. Nothing is persisted as a local paid flag.
@MainActor
final class SubscriptionModel: ObservableObject {
    @Published private(set) var state: SubscriptionAccessState
    @Published private(set) var products: [Product] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var notice: String?
    @Published private(set) var error: String?

    let productIDs: Set<String>
    private var updatesTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Verified renewal evidence is tied to a transaction, never a local paid flag.
    private var verifiedGrace: [UInt64: Date] = [:]

    init(productIDs: [String]? = nil, bundle: Bundle = .main) {
        let configured = productIDs ?? bundle.object(forInfoDictionaryKey: "HarnessSubscriptionProductIDs") as? [String] ?? []
        self.productIDs = Set(configured.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("$(") })
        state = self.productIDs.isEmpty ? .unconfigured : .checking
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.received(result)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    var accessDecision: DictationAccessDecision { state.access() }

    func refresh() async {
        guard !productIDs.isEmpty else { state = .unconfigured; return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        error = nil
        defer { if generation == refreshGeneration { isRefreshing = false } }

        // Entitlements are read independently of product availability. A catalog/network failure
        // must not erase a still-valid, locally verified subscription.
        var transactions: [String: StoreKit.Transaction] = [:]
        var verificationFailed = false
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case let .verified(transaction) where accepts(transaction):
                transactions[transaction.productID] = transaction
            case let .unverified(transaction, _) where productIDs.contains(transaction.productID):
                verificationFailed = true
            default: break
            }
        }
        for productID in productIDs {
            guard let result = await StoreKit.Transaction.latest(for: productID) else { continue }
            switch result {
            case let .verified(transaction) where accepts(transaction):
                transactions[productID] = transaction
            case .unverified:
                transactions.removeValue(forKey: productID)
                verificationFailed = true
            default: break
            }
        }
        let now = Date()
        verifiedGrace = verifiedGrace.filter { $0.value > now }
        var receipts = transactions.compactMapValues { receipt($0, graceExpiration: verifiedGrace[$0.id]) }
        guard generation == refreshGeneration else { return }
        // Publish once after resolving grace. Publishing an expired intermediate value
        // would stop a subscriber's recording before verified renewal info arrives.
        defer {
            if generation == refreshGeneration {
                state = SubscriptionEntitlementPolicy.evaluate(productIDs: productIDs, transactions: Array(receipts.values), hadVerificationFailure: verificationFailed)
            }
        }

        do {
            let available = try await Product.products(for: Array(productIDs))
                .filter { $0.type == .autoRenewable }
                .sorted { $0.price < $1.price }
            guard generation == refreshGeneration else { return }
            products = available
            if available.isEmpty {
                error = "The App Store returned no subscription plans for this build. Try again later."
            }

            // Billing grace is access only when both the transaction and renewal information
            // verify, and StoreKit explicitly reports the grace-period state.
            var checkedGroups = Set<String>()
            for product in available {
                guard let info = product.subscription, checkedGroups.insert(info.subscriptionGroupID).inserted else { continue }
                let statuses = try await info.status
                for status in statuses where status.state == .inGracePeriod {
                    guard case let .verified(transaction) = status.transaction,
                          accepts(transaction),
                          case let .verified(renewal) = status.renewalInfo,
                          let grace = renewal.gracePeriodExpirationDate,
                          transactions[transaction.productID]?.id == transaction.id,
                          let verified = receipt(transaction, graceExpiration: grace) else { continue }
                    receipts[transaction.productID] = verified
                    verifiedGrace[transaction.id] = grace
                }
            }
            guard generation == refreshGeneration else { return }
        } catch {
            guard generation == refreshGeneration else { return }
            self.error = "Couldn't load App Store subscription details. \(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing, productIDs.contains(product.id), product.type == .autoRenewable else { return }
        isPurchasing = true
        notice = nil
        error = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case let .success(result):
                switch result {
                case let .verified(transaction) where accepts(transaction):
                    await transaction.finish()
                    await refresh()
                    notice = accessDecision.isAllowed ? "Your Harness subscription is ready. Speak includes the system-wide keyboard." : "Purchase received. Subscription access is still being checked."
                default:
                    state = .verificationFailed
                    error = "The purchase could not be verified. Access has not been granted."
                }
            case .pending:
                notice = "The App Store is waiting for approval. Speak becomes available after the purchase is verified."
            case .userCancelled:
                notice = "Purchase cancelled."
            @unknown default:
                notice = "The App Store has not completed this purchase."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore() async {
        guard !productIDs.isEmpty, !isPurchasing else { return }
        isPurchasing = true
        notice = nil
        error = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refresh()
            if state == .verificationFailed {
                notice = "Subscription verification failed. Access could not be restored."
            } else {
                notice = accessDecision.isAllowed ? "Your Harness subscription has been restored." : "No active Harness subscription was found for this App Store account."
            }
        } catch {
            self.error = "Couldn't restore purchases. \(error.localizedDescription)"
        }
    }

    func manage() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            error = "Open Harness in the foreground to manage your subscription."
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await refresh()
        } catch {
            self.error = "Couldn't open App Store subscriptions. \(error.localizedDescription)"
        }
    }

    private func received(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case let .verified(transaction) where accepts(transaction):
            await transaction.finish()
            await refresh()
        case let .unverified(transaction, _) where productIDs.contains(transaction.productID):
            // Invalidate an older in-flight refresh so it cannot overwrite failed verification.
            refreshGeneration += 1
            isRefreshing = false
            state = .verificationFailed
            error = "An App Store subscription update could not be verified. Restore purchases to check access."
        default: break
        }
    }

    private func accepts(_ transaction: StoreKit.Transaction) -> Bool {
        productIDs.contains(transaction.productID) && transaction.productType == .autoRenewable
    }

    private func receipt(_ transaction: StoreKit.Transaction, graceExpiration: Date? = nil) -> VerifiedSubscription? {
        guard let expiration = transaction.expirationDate else { return nil }
        return VerifiedSubscription(productID: transaction.productID, expiration: expiration,
            revocation: transaction.revocationDate, isUpgraded: transaction.isUpgraded, graceExpiration: graceExpiration)
    }
}
