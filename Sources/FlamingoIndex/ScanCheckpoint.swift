import Foundation
import FlamingoCore

/// How far the index has followed the disk, so opening a vault replays FSEvents from there
/// instead of walking every file again. On a home folder the walk takes most of an hour;
/// replaying a day of changes takes seconds.
public struct ScanCheckpoint: Sendable, Equatable {
    /// Every change recorded before this FSEvents id is in the index.
    public var eventID: UInt64
    /// `VaultWatcher.historyID` of the vault's volume when `eventID` was taken. Ids from
    /// another history (a reformatted disk, a reset event log) mean nothing.
    public var history: String
    /// When the last complete walk finished.
    public var walkedAt: Date

    public init(eventID: UInt64, history: String, walkedAt: Date) {
        self.eventID = eventID; self.history = history; self.walkedAt = walkedAt
    }
}

extension IndexStore {
    /// A full walk at least this often, in case FSEvents lost something without saying so.
    public static let maxWalkAge: TimeInterval = 7 * 24 * 3600

    /// Where to resume from, or nil when the next pass has to walk: no complete walk yet, a
    /// different event history, a walk older than `maxWalkAge`, or rules that changed since
    /// (a new build's built-in rules, or ignore files edited while the app was closed).
    public func scanCheckpoint(history: String?, now: Date = Date()) -> ScanCheckpoint? {
        guard let history,
              let stored = try? read({ db in
                  try db.query("SELECT key, value FROM meta WHERE key IN ('scan_event_id', 'scan_history', 'scan_walked_at', 'scan_rules')") {
                      ($0.string(0), $0.string(1))
                  }
              }) else { return nil }
        let meta = Dictionary(stored, uniquingKeysWith: { a, _ in a })
        guard let id = meta["scan_event_id"].flatMap(UInt64.init), meta["scan_history"] == history,
              let walked = meta["scan_walked_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
              now.timeIntervalSince(walked) < Self.maxWalkAge, meta["scan_rules"] == Self.scanRules(in: vault)
        else { return nil }
        return ScanCheckpoint(eventID: id, history: history, walkedAt: walked)
    }

    /// Records that every change before `checkpoint.eventID` is indexed. Never moves backwards
    /// within one history.
    public func saveScanCheckpoint(_ checkpoint: ScanCheckpoint) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.transaction {
            let current = try writer.query("SELECT value FROM meta WHERE key = 'scan_history'") { $0.string(0) }.first
            let id = try writer.query("SELECT value FROM meta WHERE key = 'scan_event_id'") { $0.string(0) }.first.flatMap(UInt64.init)
            if current == checkpoint.history, let id, id > checkpoint.eventID { return }
            for (key, value) in [("scan_event_id", String(checkpoint.eventID)), ("scan_history", checkpoint.history),
                                 ("scan_walked_at", String(checkpoint.walkedAt.timeIntervalSince1970)),
                                 ("scan_rules", Self.scanRules(in: vault))] {
                try writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", key, value)
            }
        }
    }

    /// The next pass walks. For a failed write the index can't vouch for.
    public func clearScanCheckpoint() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.run("DELETE FROM meta WHERE key IN ('scan_event_id', 'scan_history', 'scan_walked_at', 'scan_rules')")
    }

    /// Everything that decides which files a walk lists, as one comparable string.
    static func scanRules(in vault: Vault) -> String {
        // The same two files `VaultScanner.ignoreRules(in:)` reads.
        let own = (try? String(contentsOf: vault.ignoreURL, encoding: .utf8)) ?? IgnoreRules.defaultText
        let legacy = (try? String(contentsOf: vault.root.appendingPathComponent(IgnoreRules.fileName), encoding: .utf8)) ?? ""
        return [VaultScanner.ignoredNames.sorted().joined(separator: "|"),
                VaultScanner.rootOnlyIgnoredNames.sorted().joined(separator: "|"),
                VaultScanner.packageExtensions.sorted().joined(separator: "|"),
                String(VaultScanner.limits.maxExtractableBytes), own, legacy].joined(separator: "\n")
    }

    /// Files whose rows an extractor change made stale. A walk re-reads them as it passes;
    /// a replay asks for them here instead.
    public func staleFiles() throws -> [FileRef] {
        try read { db in try db.query("SELECT path FROM files WHERE size = -1 ORDER BY path") { FileRef(relativePath: $0.string(0)) } }
    }

    /// How many files the index holds, for a walk's progress.
    public func fileCount() throws -> Int {
        try read { db in try db.scalarInt("SELECT count(*) FROM files") }
    }
}
