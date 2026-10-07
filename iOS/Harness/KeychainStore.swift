import Foundation
import Security

/// Credentials never enter the SQLite workspace, model context, exports, or logs.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let service = "org.harnessai.Harness.credentials"

    func token(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: status)
        }
        return token
    }

    func set(_ token: String, for account: String) throws {
        guard let data = token.data(using: .utf8), !account.isEmpty else { throw KeychainFailure(status: errSecParam) }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = baseQuery(account)
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var new = query
            new.merge(attributes) { _, value in value }
            let status = SecItemAdd(new as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        } else if update != errSecSuccess { throw KeychainFailure(status: update) }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

struct KeychainFailure: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "The credential could not be accessed in this device's Keychain (\(status)). Unlock this iPhone and try again." }
}
