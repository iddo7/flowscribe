import Foundation
import LocalAuthentication
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

    /// Checks metadata without decrypting the key or displaying an access prompt.
    /// nil means Keychain status could not be checked, rather than a missing key.
    static func containsKeychainKey(account: String = keychainAccount) -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    static func readKeychain(account: String = keychainAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
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
    static func saveKey(_ key: String, account: String = keychainAccount) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let data = Data(trimmed.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        // Delete then add: simpler than update flow, avoids errSecItemNotFound juggling.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteKey(account: String = keychainAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
