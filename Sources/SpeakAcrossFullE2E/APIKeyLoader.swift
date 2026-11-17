import Foundation
import Security
import SpeakAcrossCore

enum FullE2EKeyError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No OpenAI API key found. Set OPENAI_API_KEY in .env, the shell, or SpeakAcross Keychain."
        }
    }
}

enum FullE2EKeyLoader {
    static func load() throws -> String {
        if let key = DotEnv.value(for: "OPENAI_API_KEY") {
            return key
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.speakacross",
            kSecAttrAccount as String: "openai-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FullE2EKeyError.missingAPIKey
        }

        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
