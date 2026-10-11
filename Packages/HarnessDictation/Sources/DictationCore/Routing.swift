import Foundation

/// Where speech becomes text. Ordered from most to least private.
public enum TranscriptionRoute: String, Codable, Hashable, Sendable, CaseIterable {
    /// Apple's on-device speech models. Nothing leaves the iPhone.
    case onDevice
    /// The user's paired Mac/Windows/Linux computer (e.g. Whisper on their GPU), over the encrypted
    /// pairing channel.
    case myComputer
    /// A cloud speech-to-text endpoint the user configured with their own key.
    case cloud

    public var displayName: String {
        switch self {
        case .onDevice: return "On Device"
        case .myComputer: return "My Computer"
        case .cloud: return "Cloud"
        }
    }

    var privacyRank: Int {
        switch self {
        case .onDevice: return 0
        case .myComputer: return 1
        case .cloud: return 2
        }
    }
}

public enum RoutePreference: String, Codable, Hashable, Sendable, CaseIterable {
    /// On device first, then the paired computer, then cloud only if the user allowed it.
    case automatic
    case onDevice
    case myComputer
    case cloud

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .onDevice: return "On Device"
        case .myComputer: return "My Computer"
        case .cloud: return "Cloud"
        }
    }
}

/// What is possible right now. Filled in by the engine before each dictation.
public struct RouteAvailability: Equatable, Sendable {
    /// The device supports on-device transcription for this language.
    public var onDeviceSupported: Bool
    /// The on-device model for the language is already installed (otherwise a download is needed,
    /// which still keeps audio on device).
    public var onDeviceInstalled: Bool
    public var computerPaired: Bool
    public var computerReachable: Bool
    public var cloudConfigured: Bool
    public var networkAvailable: Bool

    public init(
        onDeviceSupported: Bool,
        onDeviceInstalled: Bool,
        computerPaired: Bool,
        computerReachable: Bool,
        cloudConfigured: Bool,
        networkAvailable: Bool
    ) {
        self.onDeviceSupported = onDeviceSupported
        self.onDeviceInstalled = onDeviceInstalled
        self.computerPaired = computerPaired
        self.computerReachable = computerReachable
        self.cloudConfigured = cloudConfigured
        self.networkAvailable = networkAvailable
    }

    func isUsable(_ route: TranscriptionRoute) -> Bool {
        switch route {
        case .onDevice: return onDeviceSupported && (onDeviceInstalled || networkAvailable)
        case .myComputer: return computerPaired && computerReachable
        case .cloud: return cloudConfigured && networkAvailable
        }
    }
}

public struct RouteDecision: Equatable, Sendable {
    public var route: TranscriptionRoute?
    /// True when the chosen route is not the one the user asked for.
    public var fellBack: Bool
    /// The on-device model must be downloaded first (audio still stays on device).
    public var needsModelDownload: Bool
    /// Short, user-facing explanation.
    public var explanation: String
}

public enum RouteSelector {
    /// Picks a route. Never uses the cloud unless the user chose it or allowed cloud fallback, and
    /// never falls back to a less private route silently: `fellBack` and `explanation` say so.
    public static func select(
        preference: RoutePreference,
        allowCloudFallback: Bool,
        availability: RouteAvailability
    ) -> RouteDecision {
        let order: [TranscriptionRoute]
        switch preference {
        case .automatic, .onDevice:
            order = allowCloudFallback ? [.onDevice, .myComputer, .cloud] : [.onDevice, .myComputer]
        case .myComputer:
            order = allowCloudFallback ? [.myComputer, .onDevice, .cloud] : [.myComputer, .onDevice]
        case .cloud:
            // The user picked cloud; if it's unreachable, more private routes are fine.
            order = [.cloud, .myComputer, .onDevice]
        }
        let requested: TranscriptionRoute? = {
            switch preference {
            case .automatic: return nil
            case .onDevice: return .onDevice
            case .myComputer: return .myComputer
            case .cloud: return .cloud
            }
        }()

        for route in order where availability.isUsable(route) {
            let fellBack = requested.map { $0 != route } ?? (route != .onDevice)
            let needsDownload = route == .onDevice && !availability.onDeviceInstalled
            return RouteDecision(
                route: route,
                fellBack: fellBack,
                needsModelDownload: needsDownload,
                explanation: explanation(for: route, requested: requested, fellBack: fellBack, needsDownload: needsDownload, availability: availability)
            )
        }

        var reason = "No transcription route is available."
        if !availability.onDeviceSupported {
            reason = availability.networkAvailable
                ? "This language isn't supported on device. Pair a computer or allow cloud transcription."
                : "This language isn't supported on device, and you're offline."
        } else if !availability.onDeviceInstalled && !availability.networkAvailable {
            reason = "The on-device model for this language isn't downloaded yet, and you're offline."
        }
        return RouteDecision(route: nil, fellBack: false, needsModelDownload: false, explanation: reason)
    }

    private static func explanation(
        for route: TranscriptionRoute,
        requested: TranscriptionRoute?,
        fellBack: Bool,
        needsDownload: Bool,
        availability: RouteAvailability
    ) -> String {
        switch route {
        case .onDevice:
            return needsDownload ? "Downloading the on-device model. Audio stays on this iPhone." : "On device. Audio stays on this iPhone."
        case .myComputer:
            return fellBack ? "On-device isn't available for this language, so your computer is transcribing." : "Your computer is transcribing over the paired connection."
        case .cloud:
            if fellBack { return "Using your cloud endpoint because nothing more private is available." }
            return availability.networkAvailable ? "Your cloud endpoint is transcribing. Audio is sent, then discarded." : "Cloud"
        }
    }
}
