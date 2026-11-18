import Foundation
import Security

/// Minimal generic-password wrapper. Holds the pairing (peer + shared key).
enum Keychain {
    private static let service = AppInfo.bundleID

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(account: String, data: Data) -> Bool {
        let rc = SecItemUpdate(query(account) as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
        if rc == errSecSuccess { return true }
        guard rc == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let rc = SecItemDelete(query(account) as CFDictionary)
        return rc == errSecSuccess || rc == errSecItemNotFound
    }
}
