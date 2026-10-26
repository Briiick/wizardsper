import Foundation
import Security

/// The user's Anthropic API key, kept in the login keychain.
///
/// Not in `Settings`: those are `UserDefaults`, a plain plist that any process
/// running as the user can read and that ends up in backups and dotfile repos.
/// A key that bills the user's account belongs where macOS keeps passwords.
public enum AnthropicKeychain {

    private static let service = "com.bricken.wizardsper.anthropic"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or nil when there is none or it cannot be read.
    public static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.ui.error("Keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    public static var hasKey: Bool { read() != nil }

    /// Store `key`, replacing any previous one. An empty key deletes it.
    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Log.ui.error("Keychain update failed: \(update, privacy: .public)")
            return false
        }

        var item = query
        item[kSecValueData as String] = data
        let add = SecItemAdd(item as CFDictionary, nil)
        if add != errSecSuccess {
            Log.ui.error("Keychain add failed: \(add, privacy: .public)")
        }
        return add == errSecSuccess
    }

    @discardableResult
    public static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
