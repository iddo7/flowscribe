import Foundation
import Security

/// Resolves the OpenAI API key: OPENAI_API_KEY env first, then Keychain
/// (service `com.flowscribe.app`, account `openai-api-key`).
enum APIKeyStore {
    static let environmentKey = "OPENAI_API_KEY"
    static let keychainService = "com.flowscribe.app"
    static let keychainAccount = "openai-api-key"

    /// Never log the returned value.
    static func resolveKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainReader: () -> String? = { APIKeyStore.readKeychain() }
    ) -> String? {
        if let env = environment[environmentKey] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return keychainReader()
    }

    // MARK: - Keychain (generic password items)

    static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or updates) the key. Returns false on Keychain failure.
    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let data = Data(trimmed.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        // Delete then add: simpler than update flow, avoids errSecItemNotFound juggling.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
