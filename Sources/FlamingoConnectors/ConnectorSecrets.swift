import Foundation
import Security

/// A pasted feed link split in two: what the card may keep, and the full address with its token.
public struct FeedLink: Equatable, Sendable {
    /// `https://host`: shown, stored in the card, and the only part Claude may see.
    public var source: String
    /// The whole `https://` address. Keychain only.
    public var secret: String
}

/// Feed addresses and passwords. `FLAMINGO_CONNECTOR_<ID>` in the environment first, then the
/// login Keychain (service `com.flamingo.connector`, account = connector id).
public enum ConnectorSecrets {
    public static let service = "com.flamingo.connector"

    /// Only the app itself touches the Keychain, the rule `KeyStore` follows: a test run or a QA
    /// copy would raise the Keychain's access prompt and wait on it. Those use the environment.
    static let keychainEnabled = NSClassFromString("XCTestCase") == nil
        && Bundle.main.bundleIdentifier == "com.flamingo.app"

    /// `managebac-2` → `FLAMINGO_CONNECTOR_MANAGEBAC_2`.
    public static func environmentName(for id: String) -> String {
        "FLAMINGO_CONNECTOR_" + id.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    public static func secret(for id: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let env = environment[environmentName(for: id)]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return stored(id)
    }

    /// The pasted link, normalised (`webcal://` → `https://`), split into host and secret.
    public static func feedLink(_ pasted: String) throws -> FeedLink {
        guard let url = ICalAdapter.feedURL(pasted) else { throw ConnectorError.invalidSource }
        return FeedLink(source: redacted(url), secret: url.absoluteString)
    }

    /// `https://host` (and port): a feed address with its path, query and any password removed.
    public static func redacted(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = (url.host ?? "").lowercased()
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    static func stored(_ id: String) -> String? {
        guard keychainEnabled, ConnectorStore.isValidID(id) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { return nil }
        return secret
    }

    public static func save(_ secret: String, for id: String) throws {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConnectorStore.isValidID(id) else { throw ConnectorError.invalidID }
        guard !secret.isEmpty else { throw ConnectorError.missingSecret }
        guard keychainEnabled else { throw ConnectorError.keychain(errSecNotAvailable) }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let data = Data(secret.utf8)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Flamingo — connector \(id)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectorError.keychain(status) }
    }

    public static func remove(for id: String) throws {
        guard keychainEnabled, ConnectorStore.isValidID(id) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(match as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectorError.keychain(status) }
    }
}
