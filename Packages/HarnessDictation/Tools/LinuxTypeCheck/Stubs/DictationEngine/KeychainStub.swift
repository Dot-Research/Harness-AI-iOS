import Foundation
public final class KeychainCredentialProvider: CredentialProvider, Sendable {
    public init(service: String = "org.harness.ios.dictation") {}
    public func secret(for id: String) -> String? { nil }
    @discardableResult public func setSecret(_ value: String, for id: String) -> Bool { false }
    public func removeSecret(for id: String) {}
    public func hasSecret(for id: String) -> Bool { false }
}
