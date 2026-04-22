import Foundation
import Security

/// Simple Keychain wrapper for storing strings and Codable objects securely.
///
/// Uses a shared Keychain access group so multiple apps signed by the same
/// team (e.g. main app + editorial re-skin) can share credentials.
/// New writes go to the shared group; reads fall back to the legacy
/// (app-scoped) location for backward compatibility. Legacy items are
/// never deleted — they remain as a safety net.
enum KeychainHelper {

    private static let service = "com.jasongelman.LutronHome"
    private static let sharedAccessGroup = "WRS5YQAAC6.com.jasongelman.shared"

    // MARK: - String Storage

    static func save(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(data: data, for: key)
    }

    static func loadString(for key: String) -> String? {
        guard let data = loadData(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Codable Storage

    static func save<T: Encodable>(_ object: T, for key: String) {
        guard let data = try? JSONEncoder().encode(object) else { return }
        save(data: data, for: key)
    }

    static func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = loadData(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Delete

    static func delete(for key: String) {
        // Delete from shared group
        let sharedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedAccessGroup,
        ]
        SecItemDelete(sharedQuery as CFDictionary)

        // Also delete from legacy location
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    // MARK: - Private

    private static func save(data: Data, for key: String) {
        // Delete existing item in shared group first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedAccessGroup,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Write to shared group
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }

        // If shared group write fails (entitlement not provisioned), fall back
        // to writing without an access group so the app still works.
        if status == errSecMissingEntitlement || status == errSecParam {
            print("Keychain: shared group unavailable for '\(key)', writing to app-scoped Keychain")
            let fallbackDelete: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecAttrService as String: service,
            ]
            SecItemDelete(fallbackDelete as CFDictionary)

            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecAttrService as String: service,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let fallbackStatus = SecItemAdd(fallbackQuery as CFDictionary, nil)
            if fallbackStatus != errSecSuccess {
                print("Keychain: save failed for '\(key)' — status \(fallbackStatus)")
            }
        } else if status != errSecSuccess {
            print("Keychain: save failed for '\(key)' — status \(status)")
        }
    }

    private static func loadData(for key: String) -> Data? {
        // Try shared access group first
        let sharedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(sharedQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }

        // Fall back to legacy (no access group) — handles the case where the
        // shared group entitlement isn't provisioned yet or items haven't been
        // re-saved to the shared group.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        result = nil
        status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
