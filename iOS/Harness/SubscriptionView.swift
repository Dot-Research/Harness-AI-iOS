import SwiftUI
import StoreKit
import DictationCore

struct SubscriptionView: View {
    @EnvironmentObject private var subscription: SubscriptionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Speak, across your apps.").font(.system(.largeTitle, design: .serif))
                Text("A Harness subscription includes Speak and the system-wide Harness keyboard.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)

                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(statusTitle, systemImage: subscription.accessDecision.isAllowed ? "checkmark.seal" : "keyboard")
                            .font(.headline).foregroundStyle(subscription.accessDecision.isAllowed ? HarnessTheme.green : HarnessTheme.amber)
                        Text(statusDetail).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                        if subscription.isRefreshing { ProgressView("Checking App Store…").font(.caption) }
                    }
                }

                if let notice = subscription.notice {
                    Text(notice).font(.subheadline).foregroundStyle(HarnessTheme.green)
                }
                if let error = subscription.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(HarnessTheme.coral)
                }

                if !subscription.productIDs.isEmpty {
                    if !subscription.accessDecision.isAllowed {
                        ForEach(subscription.products) { product in
                            HarnessCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(product.displayName).font(.title3.weight(.medium))
                                    Text(product.description).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                                    Text(priceDescription(product)).font(.headline)
                                    Button { Task { await subscription.purchase(product) } } label: {
                                        Text(subscription.isPurchasing ? "Waiting for App Store…" : "Subscribe")
                                    }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .disabled(subscription.isPurchasing || subscription.isRefreshing)
                                }
                            }
                        }
                    }
                    VStack(spacing: 14) {
                        Button("Restore purchases") { Task { await subscription.restore() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        Button("Manage in App Store") { Task { await subscription.manage() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        Button("Check access again") { Task { await subscription.refresh() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(subscription.isPurchasing || subscription.isRefreshing)
                    Text("Payment and renewal are handled by the App Store. Review the price and terms in Apple's purchase sheet before confirming.")
                        .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                }
            }
            .padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .navigationTitle("Harness subscription").navigationBarTitleDisplayMode(.inline)
        .harnessScreen()
        .task { await subscription.refresh() }
    }

    private var statusTitle: String {
        switch subscription.state {
        case .unconfigured: return "Subscription setup unavailable"
        case .checking: return "Checking your subscription"
        case .notSubscribed: return "No active subscription"
        case .active: return subscription.accessDecision.isAllowed ? "Subscription active" : "Subscription expired"
        case .expired: return "Subscription expired"
        case .revoked: return "Subscription access revoked"
        case .verificationFailed: return "Subscription not verified"
        }
    }

    private var statusDetail: String {
        switch subscription.state {
        case .unconfigured:
            return "This build has no App Store subscription products configured. Purchases and Speak access are unavailable until setup is complete."
        case let .active(_, expiration) where subscription.accessDecision.isAllowed:
            return "Speak and the system-wide keyboard are included. Verified access ends \(expiration.formatted(date: .abbreviated, time: .shortened))."
        default:
            return subscription.accessDecision.denialMessage ?? "Your subscription includes Speak and the system-wide keyboard."
        }
    }

    private func priceDescription(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: return product.displayPrice
        }
        return "\(product.displayPrice) / \(period.value == 1 ? "" : "\(period.value) ")\(unit)"
    }
}
