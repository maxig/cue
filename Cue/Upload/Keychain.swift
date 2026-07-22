import Foundation
import Security

/// Minimal Keychain wrapper for storing the MinIO/S3 secret key. Secrets never
/// touch UserDefaults.
enum Keychain {
    private static let service = "com.max.Cue"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }

        // Update in place first so changing a credential never creates a window
        // where the old item has been deleted but the replacement is not durable.
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { NSLog("Cue: Keychain update failed (\(status))") }
            return
        }

        var add = query
        changes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { NSLog("Cue: Keychain add failed (\(addStatus))") }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}
