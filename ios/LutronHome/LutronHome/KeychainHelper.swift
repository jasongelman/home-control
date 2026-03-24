import Foundation
import Security

/// Simple Keychain wrapper for storing strings and Codable objects securely
enum KeychainHelper {

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.jasongelman.LutronHome",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private static func save(data: Data, for key: String) {
        // Delete existing item first
        delete(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.jasongelman.LutronHome",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Keychain: save failed for '\(key)' — status \(status)")
        }
    }

    private static func loadData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.jasongelman.LutronHome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
