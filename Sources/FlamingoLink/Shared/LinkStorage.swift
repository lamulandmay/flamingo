// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import Foundation
import Security

/// A Mac this one paired with: its public key and the name it gave. Not secret; the private
/// half never leaves its own Mac.
public struct LinkPairedPeer: Codable, Equatable, Sendable {
    public var id: String
    public var publicKey: Data
    public var name: String
    /// "capybara" or "flamingo".
    public var app: String
    public var paired: Date

    public init(id: String, publicKey: Data, name: String, app: String, paired: Date = Date()) {
        self.id = id; self.publicKey = publicKey; self.name = name; self.app = app; self.paired = paired
    }
}

/// A message that must arrive even if the other Mac is away: kept until it says it has it.
public struct LinkOutgoing: Codable, Equatable, Sendable {
    public var id: String
    public var peer: String
    public var json: Data
    public var queued: Date

    public init(id: String, peer: String, json: Data, queued: Date = Date()) {
        self.id = id; self.peer = peer; self.json = json; self.queued = queued
    }
}

/// Everything the link keeps between launches, in one 0600 file (`link.json`) beside the
/// app's own data, and the private key in the Keychain (or a 0600 file for tests).
public final class LinkStorage {
    struct Saved: Codable {
        var peers: [LinkPairedPeer] = []
        var outbox: [LinkOutgoing] = []
        /// Ids of messages already handled, newest last, so a resend after a lost
        /// acknowledgement is acknowledged again but not acted on twice.
        var seen: [String] = []
    }

    public let directory: URL
    let keychainService: String?
    var saved: Saved

    /// `keychainService` nil keeps the private key in a file: the self-tests and `--serve`.
    public init(directory: URL, keychainService: String?) {
        self.directory = directory
        self.keychainService = keychainService
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        saved = (try? Data(contentsOf: directory.appendingPathComponent("link.json")))
            .flatMap { try? Self.decoder.decode(Saved.self, from: $0) } ?? Saved()
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func save() {
        let file = directory.appendingPathComponent("link.json")
        guard let data = try? Self.encoder.encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public var peers: [LinkPairedPeer] { saved.peers }
    public var outbox: [LinkOutgoing] { saved.outbox }

    public func setPeers(_ peers: [LinkPairedPeer]) { saved.peers = peers; save() }
    public func setOutbox(_ items: [LinkOutgoing]) { saved.outbox = items; save() }

    func seen(_ id: String) -> Bool { saved.seen.contains(id) }
    func markSeen(_ id: String) {
        saved.seen.append(id)
        if saved.seen.count > 2000 { saved.seen.removeFirst(saved.seen.count - 2000) }
        save()
    }

    // MARK: Identity

    /// This Mac's key, made the first time it's asked for.
    public func identity() -> LinkIdentity {
        if let raw = loadKey(), let id = LinkIdentity(raw: raw) { return id }
        let fresh = LinkIdentity()
        storeKey(fresh.raw)
        return fresh
    }

    var keyFile: URL { directory.appendingPathComponent("link-identity.key") }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService ?? "",
         kSecAttrAccount as String: "identity"]
    }

    func loadKey() -> Data? {
        guard keychainService != nil else { return try? Data(contentsOf: keyFile) }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    func storeKey(_ raw: Data) {
        guard keychainService != nil else {
            try? raw.write(to: keyFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            return
        }
        SecItemDelete(keychainQuery as CFDictionary)
        var add = keychainQuery
        add[kSecValueData as String] = raw
        add[kSecAttrLabel as String] = "Capybara and Flamingo link key"
        add[kSecAttrDescription as String] = "This Mac's key for the encrypted link between Capybara and Flamingo"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
