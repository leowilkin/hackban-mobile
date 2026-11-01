import Foundation
import Security

public struct Tokens: Codable, Hashable, Sendable {
    public var access: String
    public var refresh: String
    public var expiresAt: Date

    public var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

/// Tokens live in the shared Keychain access group so the widget extension can use them too.
/// Unsigned simulator builds have no access group; those fall back to the app's own keychain.
public enum TokenStore {
    private static let service = "com.hackclub.hackban.tokens"

    private static func query(_ account: UUID, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    public static func read(_ account: UUID) -> Tokens? {
        for group in [Shared.keychainGroup, nil] {
            var q = query(account, group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return try? JSONDecoder().decode(Tokens.self, from: data)
            }
            if group == nil { break }
        }
        return nil
    }

    public static func write(_ tokens: Tokens, for account: UUID) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        for group in [Shared.keychainGroup, nil] {
            let q = query(account, group: group)
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = q
                add.merge(attrs) { $1 }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess || group == nil { return }
        }
    }

    public static func delete(_ account: UUID) {
        SecItemDelete(query(account, group: Shared.keychainGroup) as CFDictionary)
        SecItemDelete(query(account, group: nil) as CFDictionary)
    }
}
