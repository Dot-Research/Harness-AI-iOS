import Foundation

/// The embedding app supplies this decision. The dictation library stays independent of StoreKit.
public enum DictationAccessDecision: Equatable, Sendable {
    case allowed
    case denied(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var denialMessage: String? {
        if case let .denied(message) = self { return message }
        return nil
    }
}

/// Construct only after StoreKit verifies the transaction. A grace date also requires verified
/// renewal information in the billing-grace state; a locally stored paid flag is never evidence.
public struct VerifiedSubscription: Equatable, Sendable {
    public var productID: String
    public var expiration: Date
    public var revocation: Date?
    public var isUpgraded: Bool
    public var graceExpiration: Date?

    public init(productID: String, expiration: Date, revocation: Date? = nil, isUpgraded: Bool = false, graceExpiration: Date? = nil) {
        self.productID = productID
        self.expiration = expiration
        self.revocation = revocation
        self.isUpgraded = isUpgraded
        self.graceExpiration = graceExpiration
    }

    public var accessExpiration: Date { max(expiration, graceExpiration ?? expiration) }
}

public enum SubscriptionAccessState: Equatable, Sendable {
    case unconfigured
    case checking
    case notSubscribed
    case active(productID: String, expiration: Date)
    case expired(Date)
    case revoked
    case verificationFailed

    /// Check the clock at each use, even while the app is suspended between StoreKit updates.
    public func access(at now: Date = Date()) -> DictationAccessDecision {
        switch self {
        case let .active(_, expiration) where expiration > now: return .allowed
        case .active, .expired: return .denied("Your Harness subscription has expired. Review access in Me → Harness subscription.")
        case .unconfigured: return .denied("Subscriptions are not configured in this build. Speak access is unavailable.")
        case .checking: return .denied("Checking your Harness subscription. Try Speak again in a moment.")
        case .notSubscribed: return .denied("Speak and the system-wide keyboard require a Harness subscription. Open Me → Harness subscription.")
        case .revoked: return .denied("App Store access to this subscription has been revoked. Review it in Me → Harness subscription.")
        case .verificationFailed: return .denied("The App Store subscription could not be verified. Restore purchases in Me → Harness subscription.")
        }
    }
}

public enum SubscriptionEntitlementPolicy {
    public static func evaluate(productIDs: Set<String>, transactions: [VerifiedSubscription], hadVerificationFailure: Bool = false, now: Date = Date()) -> SubscriptionAccessState {
        guard !productIDs.isEmpty else { return .unconfigured }
        let matching = transactions.filter { productIDs.contains($0.productID) && !$0.isUpgraded }
        let available = matching.filter { $0.revocation == nil }
        if let active = available.filter({ $0.accessExpiration > now }).max(by: { $0.accessExpiration < $1.accessExpiration }) {
            return .active(productID: active.productID, expiration: active.accessExpiration)
        }
        if hadVerificationFailure { return .verificationFailed }
        if let expired = available.max(by: { $0.accessExpiration < $1.accessExpiration }) {
            return .expired(expired.accessExpiration)
        }
        if matching.contains(where: { $0.revocation != nil }) { return .revoked }
        return .notSubscribed
    }
}
