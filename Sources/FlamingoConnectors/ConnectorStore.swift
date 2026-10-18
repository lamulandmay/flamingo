import Foundation

/// Why a refresh or a save failed. `message` is short and never contains a feed address, so it
/// can be shown and stored as is.
public enum ConnectorError: Error, Equatable, Codable, Sendable, LocalizedError {
    case invalidID
    case invalidSource
    /// The card's feed address isn't in the Keychain or the environment.
    case missingSecret
    case unsupported(ConnectorAdapter)
    case network
    case httpStatus(Int)
    case tooLarge
    /// The feed isn't iCalendar: usually an expired link answering with a login page.
    case notCalendar
    case unreadable
    /// Calendar or Reminders access isn't granted.
    case accessDenied
    case keychain(Int32)
    case storage
    /// Claude's reply had no usable card.
    case badDraft

    public var message: String {
        switch self {
        case .invalidID: return "Invalid connector id"
        case .invalidSource: return "Not a feed address"
        case .missingSecret: return "Feed address missing"
        case .unsupported(let adapter): return "\(adapter.title) not available yet"
        case .network: return "Offline or not reachable"
        case .httpStatus(let code) where code == 401 || code == 403: return "Access denied (\(code))"
        case .httpStatus(404): return "Feed not found (404)"
        case .httpStatus(let code): return "Server error (\(code))"
        case .tooLarge: return "Feed over 20 MB"
        case .notCalendar: return "Not a calendar"
        case .unreadable: return "Unreadable feed"
        case .accessDenied: return "No access to Calendar or Reminders"
        case .keychain(let status): return "Keychain error \(status)"
        case .storage: return "Couldn't save connector"
        case .badDraft: return "No card in the reply"
        }
    }

    public var errorDescription: String? { message }

    /// Worth retrying soon: the network, a busy server, a full disk. The rest wait a full
    /// refresh interval.
    public var isTransient: Bool {
        switch self {
        case .network, .storage: return true
        case .httpStatus(let code): return code == 408 || code == 429 || code >= 500
        default: return false
        }
    }
}

/// What a connector remembers between refreshes.
public struct ConnectorState: Codable, Equatable, Sendable {
    /// The feed's version tag and date, sent back so an unchanged feed answers "not modified".
    public var etag: String?
    public var lastModified: String?
    /// The last attempt, successful or not.
    public var refreshedAt: Date?
    public var lastError: ConnectorError?
    /// Transient failures in a row; each doubles the wait (2, 4, 8… minutes, never more than
    /// the card's interval).
    public var failures: Int

    public init(etag: String? = nil, lastModified: String? = nil, refreshedAt: Date? = nil,
                lastError: ConnectorError? = nil, failures: Int = 0) {
        self.etag = etag; self.lastModified = lastModified; self.refreshedAt = refreshedAt
        self.lastError = lastError; self.failures = failures
    }

    enum CodingKeys: String, CodingKey { case etag, lastModified, refreshedAt, lastError, failures }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        etag = try? c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try? c.decodeIfPresent(String.self, forKey: .lastModified)
        refreshedAt = try? c.decodeIfPresent(Date.self, forKey: .refreshedAt)
        // An error case from another version reads as no error rather than losing the state.
        lastError = try? c.decodeIfPresent(ConnectorError.self, forKey: .lastError)
        failures = (try? c.decodeIfPresent(Int.self, forKey: .failures)) ?? 0
    }

    /// The wait after `failures` transient failures in a row: 2, 4, 8… minutes, capped.
    public static func backoff(failures: Int, interval: TimeInterval) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, 60 * pow(2, Double(min(failures, 20))))
    }

    /// When the card is next due; nil means now.
    public func nextRefresh(for card: PurposeCard) -> Date? {
        guard let refreshedAt else { return nil }
        let interval = TimeInterval(card.clamped().refreshMinutes * 60)
        return refreshedAt.addingTimeInterval(Self.backoff(failures: failures, interval: interval))
    }

    public func isStale(for card: PurposeCard, now: Date) -> Bool {
        guard let next = nextRefresh(for: card) else { return true }
        return now >= next
    }
}

/// Connectors on disk. App-wide, not per vault:
///
///     <root>/<id>.json          the purpose card
///     <root>/items/<id>.json    what it brought in
///     <root>/state/<id>.json    version tag, last refresh, last error
///
/// Every write goes to a temp file that is then swapped in.
public struct ConnectorStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Flamingo/Connectors` for the app itself. Any other bundle
    /// (a QA copy, the CLI, a test run) gets `Connectors-<bundle id or process>` beside it, so it
    /// can never change the real connectors.
    public static func defaultRoot(bundleID: String? = Bundle.main.bundleIdentifier,
                                   process: String = ProcessInfo.processInfo.processName,
                                   testing: Bool = NSClassFromString("XCTestCase") != nil,
                                   support: URL? = nil) -> URL {
        let support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Flamingo", isDirectory: true)
        if !testing && bundleID == "com.flamingo.app" {
            return base.appendingPathComponent("Connectors", isDirectory: true)
        }
        let raw = (bundleID?.isEmpty == false ? bundleID! : process)
        let key = String(raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "-" ? Character(scalar) : "_"
        })
        return base.appendingPathComponent("Connectors-" + (testing ? "tests-" : "") + key, isDirectory: true)
    }

    /// Lowercase letters, digits and dashes, at most 48 characters, no leading dash. Rules out
    /// `../` and anything else that would leave `root`.
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= PurposeCard.maxIDLength, !id.hasPrefix("-") else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: Cards

    /// Every readable card, by name. Broken files and files whose name isn't their id are skipped.
    public func cards() -> [PurposeCard] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let cards: [PurposeCard] = names.compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            let id = String(name.dropLast(5))
            guard Self.isValidID(id), let card = read(PurposeCard.self, at: cardURL(id)), card.id == id else { return nil }
            return card.clamped()
        }
        return cards.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func card(_ id: String) -> PurposeCard? {
        guard Self.isValidID(id), let card = read(PurposeCard.self, at: cardURL(id)), card.id == id else { return nil }
        return card.clamped()
    }

    /// Saves the card clamped.
    public func save(_ card: PurposeCard) throws {
        guard Self.isValidID(card.id) else { throw ConnectorError.invalidID }
        try write(card.clamped(), to: cardURL(card.id))
    }

    /// Removes the card, its items and its state. The Keychain secret is `ConnectorSecrets.remove`'s.
    public func delete(_ id: String) throws {
        guard Self.isValidID(id) else { throw ConnectorError.invalidID }
        for url in [cardURL(id), itemsURL(id), stateURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { throw ConnectorError.storage }
        }
    }

    /// The slug of `name`, or `slug-2`, `slug-3`… when it is taken.
    public func freshID(for name: String) -> String {
        let base = PurposeCard.slug(name)
        func taken(_ id: String) -> Bool { FileManager.default.fileExists(atPath: cardURL(id).path) }
        guard taken(base) else { return base }
        var n = 2
        while true {
            let suffix = "-\(n)"
            var stem = String(base.prefix(PurposeCard.maxIDLength - suffix.count))
            while stem.hasSuffix("-") { stem.removeLast() }
            let id = stem + suffix
            if !taken(id) { return id }
            n += 1
        }
    }

    // MARK: Items and state

    public func items(_ id: String) -> [ConnectorItem] {
        guard Self.isValidID(id) else { return [] }
        return read([ConnectorItem].self, at: itemsURL(id)) ?? []
    }

    public func saveItems(_ items: [ConnectorItem], for id: String) throws {
        guard Self.isValidID(id) else { throw ConnectorError.invalidID }
        try write(items, to: itemsURL(id))
    }

    /// Items of every enabled card, soonest first. The same thing reached through two connectors
    /// (same title, ignoring case and accents, at the same time) appears once: a deadline over an
    /// event, then the card listed first.
    public func allItems() -> [ConnectorItem] {
        var kept: [String: ConnectorItem] = [:]
        var order: [String] = []
        for card in cards() where card.enabled {
            for item in items(card.id) {
                let key = PurposeCard.words(item.title).joined(separator: " ") + "|"
                    + (item.when.map { String(Int($0.timeIntervalSince1970)) } ?? "-")
                if let existing = kept[key] {
                    if existing.kind != .deadline && item.kind == .deadline { kept[key] = item }
                } else {
                    kept[key] = item
                    order.append(key)
                }
            }
        }
        return order.compactMap { kept[$0] }.sorted(by: ConnectorItem.ordered)
    }

    /// The saved state, or a fresh one (due now).
    public func state(_ id: String) -> ConnectorState {
        guard Self.isValidID(id) else { return ConnectorState() }
        return read(ConnectorState.self, at: stateURL(id)) ?? ConnectorState()
    }

    public func saveState(_ state: ConnectorState, for id: String) throws {
        guard Self.isValidID(id) else { throw ConnectorError.invalidID }
        try write(state, to: stateURL(id))
    }

    // MARK: Files

    func cardURL(_ id: String) -> URL { root.appendingPathComponent(id + ".json") }
    func itemsURL(_ id: String) -> URL { root.appendingPathComponent("items", isDirectory: true).appendingPathComponent(id + ".json") }
    func stateURL(_ id: String) -> URL { root.appendingPathComponent("state", isDirectory: true).appendingPathComponent(id + ".json") }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConnectorError.storage
        }
    }
}
