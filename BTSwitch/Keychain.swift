import Foundation
import Security

/// Minimal generic-password wrapper for storing the shared token.
enum Keychain {
    private static let service = AppInfo.bundleID
    private static let account = "shared-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readToken() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func writeToken(_ token: String) -> Bool {
        if token.isEmpty {
            let rc = SecItemDelete(baseQuery as CFDictionary)
            return rc == errSecSuccess || rc == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let rc = SecItemUpdate(baseQuery as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
        if rc == errSecSuccess { return true }
        guard rc == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
