import Foundation

public enum AppleRewriteRoute: String, Codable, CaseIterable, Sendable {
    case localOnly
    case privateCloudOnly
    case localWithCloudFallback

    public var displayName: String {
        switch self {
        case .localOnly: "On device"
        case .privateCloudOnly: "Apple Private Cloud"
        case .localWithCloudFallback: "On device, then Apple Private Cloud"
        }
    }
    public var permitsNetwork: Bool { self != .localOnly }
}

public enum AppleRewriteBackend: String, Sendable { case onDevice, privateCloud }

/// Routing is explicit. An unavailable local model never grants permission to upload text.
public enum AppleRewriteRouting {
    public static func candidates(for route: AppleRewriteRoute, localAvailable: Bool,
                                  cloudAvailable: Bool, networkAllowed: Bool) -> [AppleRewriteBackend] {
        switch route {
        case .localOnly: return localAvailable ? [.onDevice] : []
        case .privateCloudOnly: return cloudAvailable && networkAllowed ? [.privateCloud] : []
        case .localWithCloudFallback:
            var result: [AppleRewriteBackend] = localAvailable ? [.onDevice] : []
            if cloudAvailable && networkAllowed { result.append(.privateCloud) }
            return result
        }
    }
}
