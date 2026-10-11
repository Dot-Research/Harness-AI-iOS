#if os(iOS)
import Foundation
import Security

// MARK: - Keychain

/// Reads and writes secrets in the app's Keychain. Items are available after first unlock (so a
/// warm session keeps working while the phone is locked in a pocket) and never sync to iCloud.
public final class KeychainCredentialProvider: CredentialProvider, Sendable {
    private let service: String

    public init(service: String = "org.harness.ios.dictation") {
        self.service = service
    }

    public func secret(for id: String) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func setSecret(_ value: String, for id: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(id)
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func removeSecret(for id: String) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }

    public func hasSecret(for id: String) -> Bool {
        var query = baseQuery(id)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
#endif
