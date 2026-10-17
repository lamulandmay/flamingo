import Foundation

/// A suggested connection someone said no to. Undirected, like `ManualConnection`.
public struct DismissedConnection: Codable, Equatable, Sendable, Identifiable {
    public var source: String
    public var target: String
    public var dismissedAt: Date
    public var id: String { source + "\u{1F}" + target }

    public init(_ a: String, _ b: String, dismissedAt: Date = Date()) {
        source = min(a, b); target = max(a, b); self.dismissedAt = dismissedAt
    }

    /// The key both orders of a pair share.
    public static func key(_ a: String, _ b: String) -> String { min(a, b) + "\u{1F}" + max(a, b) }
}

/// Suggestions (mentions, shared sessions, similar content) that were dismissed, at
/// `.flamingo/connections-dismissed.json`. Dismissing hides an inferred connection everywhere;
/// it never hides a link someone wrote or a connection someone made.
public final class DismissedConnectionStore: @unchecked Sendable {
    public let vault: Vault
    public var fileURL: URL { vault.stateDir.appendingPathComponent("connections-dismissed.json") }
    private static let lock = NSRecursiveLock()
    public init(vault: Vault) { self.vault = vault }

    public func all() throws -> [DismissedConnection] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([DismissedConnection].self, from: Data(contentsOf: fileURL))
    }

    /// Pair keys (`DismissedConnection.key`) for fast lookup.
    public func keys() -> Set<String> { Set(((try? all()) ?? []).map(\.id)) }

    public func dismiss(_ a: String, _ b: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard a != b else { return }
        var records = try all()
        let record = DismissedConnection(a, b)
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
        try save(records)
    }

    public func restore(_ a: String, _ b: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let key = DismissedConnection.key(a, b)
        let records = try all()
        guard records.contains(where: { $0.id == key }) else { return }
        try save(records.filter { $0.id != key })
    }

    /// Dismissals follow a file or folder when it is renamed or moved.
    public func reconcile(oldPath: String, newPath: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        func move(_ path: String) -> String {
            if path == oldPath { return newPath }
            return path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path
        }
        var byID: [String: DismissedConnection] = [:]
        for record in try all() {
            let a = move(record.source), b = move(record.target)
            guard a != b else { continue }
            let moved = DismissedConnection(a, b, dismissedAt: record.dismissedAt)
            byID[moved.id] = moved
        }
        try save(byID.values.sorted { $0.id < $1.id })
    }

    private func save(_ records: [DismissedConnection]) throws {
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
