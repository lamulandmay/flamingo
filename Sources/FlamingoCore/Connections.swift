import Foundation

/// An explicit, undirected connection made in Graph. These are independent of links in
/// documents and comments: removing one never changes a user's source files.
public struct ManualConnection: Codable, Equatable, Sendable, Identifiable {
    public var source: String
    public var target: String
    public var createdAt: Date
    public var label: String?
    public var origin: String
    public var id: String { source + "\u{1F}" + target }

    public init(source: String, target: String, createdAt: Date = Date(), label: String? = nil) {
        self.source = min(source, target); self.target = max(source, target)
        self.createdAt = createdAt; self.label = label; self.origin = "Graph"
    }
    public var edge: Graph.Edge { Graph.Edge(source: source, target: target, kind: .manual) }
}

/// Atomic, portable storage at `.flamingo/connections.json`. Multiple windows/stores in the
/// same process serialize read-modify-write operations so adding one pair cannot lose another.
public final class ConnectionStore: @unchecked Sendable {
    public let vault: Vault
    public var fileURL: URL { vault.stateDir.appendingPathComponent("connections.json") }
    private static let lock = NSRecursiveLock()
    public init(vault: Vault) { self.vault = vault }

    public func all() throws -> [ManualConnection] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ManualConnection].self, from: Data(contentsOf: fileURL))
    }
    public func edges() throws -> [Graph.Edge] { try all().map(\.edge) }

    /// Restore a captured state only if no other editor has changed the store.
    /// Both the comparison and write share the normal read-modify-write lock.
    public func replaceConnections(_ replacement: [ManualConnection], expecting expected: [ManualConnection]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try all() == expected else { throw ReplacementError.changedSinceAction }
        guard replacement.allSatisfy({ Self.validPath($0.source) && Self.validPath($0.target) && $0.source < $0.target }),
              Set(replacement.map(\.id)).count == replacement.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try save(replacement)
    }

    public enum ReplacementError: LocalizedError {
        case changedSinceAction

        public var errorDescription: String? {
            "Connections changed since this action. The newer connections were preserved."
        }
    }

    /// Capture the inverse under the same lock as the write, so another window's
    /// connection cannot be accidentally included in this action's history.
    public func setConnectionsUndoably(between files: [FileRef], connected: Bool, label: String? = nil)
        throws -> (before: [ManualConnection], after: [ManualConnection]) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let before = try all()
        let after = try setConnections(between: files, connected: connected, label: label)
        return (before, after)
    }

    /// Connect or disconnect every pair in the selection. Existing metadata is preserved.
    @discardableResult
    public func setConnections(between files: [FileRef], connected: Bool, label: String? = nil) throws -> [ManualConnection] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let paths = Array(Set(files.map(\.relativePath))).sorted()
        guard paths.allSatisfy(Self.validPath) else { throw CocoaError(.fileWriteInvalidFileName) }
        var records = try all()
        if connected, paths.count > 1 {
            // Deliberately connected files need durable identity before the relation is
            // saved, so a subsequent filesystem rename can carry this relation with it.
            // Metadata errors are surfaced to Graph; source content is never rewritten.
            for path in paths { _ = try FileIdentity.id(for: vault.url(for: FileRef(relativePath: path))) }
        }
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in paths.indices {
            for j in paths.indices where j > i {
                let record = ManualConnection(source: paths[i], target: paths[j], label: label)
                if connected { if byID[record.id] == nil { byID[record.id] = record } }
                else { byID[record.id] = nil }
            }
        }
        records = byID.values.sorted { $0.id < $1.id }
        try save(records)
        return records
    }

    /// Preserve explicit connections when a file or an ancestor folder is renamed or moved.
    public func reconcile(oldPath: String, newPath: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.validPath(oldPath), Self.validPath(newPath) else { throw CocoaError(.fileWriteInvalidFileName) }
        func move(_ path: String) -> String {
            if path == oldPath { return newPath }
            return path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path
        }
        var byID: [String: ManualConnection] = [:]
        for var record in try all() {
            let a = move(record.source), b = move(record.target)
            guard a != b else { continue }
            record.source = min(a, b); record.target = max(a, b)
            if let existing = byID[record.id], existing.createdAt < record.createdAt { continue }
            byID[record.id] = record
        }
        try save(byID.values.sorted { $0.id < $1.id })
    }

    private func save(_ records: [ManualConnection]) throws {
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~") && !path.hasSuffix("/")
            && !path.split(separator: "/").contains("..") && path.split(separator: "/").first != ".flamingo"
    }
}
