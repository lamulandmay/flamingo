import Foundation
import Security

/// The Anthropic API key: `ANTHROPIC_API_KEY` from the environment, else the login Keychain
/// item `com.flamingo.anthropic`. The key is never logged or shown.
enum KeyStore {
    static let service = "com.flamingo.anthropic"
    static let account = "api-key"

    static func key() -> String? { environment() ?? stored() }

    /// A key from the environment wins, so storing a new one can't replace it.
    static var fromEnvironment: Bool { environment() != nil }

    private static func environment() -> String? {
        guard let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty else { return nil }
        return env
    }

    static func stored() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AskError.noKey }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(key.utf8)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Flamingo — Anthropic API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AskError.keychain(status) }
    }

    static func remove() throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(match as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AskError.keychain(status) }
    }
}
