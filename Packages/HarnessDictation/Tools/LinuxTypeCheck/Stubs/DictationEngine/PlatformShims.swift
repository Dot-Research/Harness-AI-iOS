// Interfaces of the two engine files that use CoreFoundation/Security APIs Linux lacks
// (DarwinNotifications.swift and Keychain.swift), so code depending on them can be checked.
import Foundation

public final class DarwinNotificationObserver {
    public init(name: String, handler: @escaping () -> Void) {}
    public static func post(_ name: String) {}
}

#if os(Linux)
extension FileManager {
    public func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { nil }
}

extension URL {
    public func startAccessingSecurityScopedResource() -> Bool { false }
    public func stopAccessingSecurityScopedResource() {}
}
#endif
