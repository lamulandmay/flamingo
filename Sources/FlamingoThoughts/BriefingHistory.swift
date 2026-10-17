import Foundation
import FlamingoCore

/// What the briefing remembers, in `.flamingo/briefing.json`: how often each thought was shown
/// without being acted on, which memos and AI replies you have seen, which suggested pairs
/// you have seen. Plain JSON, never anything the person wrote.
public final class BriefingHistory: @unchecked Sendable {
    struct Stored: Codable, Equatable {
        var version = 1
        /// uid → the briefing days (`yyyy-MM-dd`) it was shown on without being acted on.
        var shown: [String: [String]] = [:]
        /// Memo paths relative to `.flamingo`.
        var seenMemos: [String] = []
        /// uids of AI replies.
        var seenReplies: [String] = []
        /// `BriefingHistory.pairKey` of suggested connections.
        var seenPairs: [String] = []
    }

    public let url: URL
    private let lock = NSLock()
    private var stored: Stored

    public static func url(in vault: Vault) -> URL { vault.stateDir.appendingPathComponent("briefing.json") }

    /// Reads the file; a missing or unreadable one is an empty history.
    public init(vault: Vault) {
        url = Self.url(in: vault)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Stored.self, from: data) { stored = decoded }
        else { stored = Stored() }
    }

    public static func pairKey(_ a: String, _ b: String) -> String { min(a, b) + "\u{1F}" + max(a, b) }

    // MARK: Reading

    /// How many briefing days in the last seven this thought was shown on without action.
    public func timesSkipped(_ uid: String, now: Date, calendar: Calendar = .current) -> Int {
        let earliest = BriefingDay.key(calendar.date(byAdding: .day, value: -7, to: now) ?? now, calendar: calendar)
        return lock.withLock { Set(stored.shown[uid] ?? []).filter { $0 > earliest }.count }
    }

    public func hasSeenMemo(_ path: String) -> Bool { lock.withLock { stored.seenMemos.contains(path) } }
    public func hasSeenReply(_ uid: String) -> Bool { lock.withLock { stored.seenReplies.contains(uid) } }
    public func hasSeenPair(_ a: String, _ b: String) -> Bool { lock.withLock { stored.seenPairs.contains(Self.pairKey(a, b)) } }
    public var seenMemos: Set<String> { lock.withLock { Set(stored.seenMemos) } }
    public var seenReplies: Set<String> { lock.withLock { Set(stored.seenReplies) } }

    // MARK: Writing

    /// These thoughts were on the briefing for `day`. Once a day each.
    public func recordShown(_ uids: [String], day: String) {
        lock.withLock {
            for uid in uids where !(stored.shown[uid] ?? []).contains(day) { stored.shown[uid, default: []].append(day) }
        }
    }

    /// The person did something with the thought (done, snoozed, replied, dismissed): it is no longer being skipped.
    public func recordAction(_ uid: String) { lock.withLock { stored.shown[uid] = nil } }

    public func markMemoSeen(_ path: String) { lock.withLock { if !stored.seenMemos.contains(path) { stored.seenMemos.append(path) } } }
    public func markReplySeen(_ uid: String) { lock.withLock { if !stored.seenReplies.contains(uid) { stored.seenReplies.append(uid) } } }
    public func markPairSeen(_ a: String, _ b: String) {
        let key = Self.pairKey(a, b)
        lock.withLock { if !stored.seenPairs.contains(key) { stored.seenPairs.append(key) } }
    }

    /// Writes the file (atomically), dropping shown-days older than two weeks.
    public func save(now: Date = Date(), calendar: Calendar = .current) throws {
        let data: Data = lock.withLock {
            let cutoff = BriefingDay.key(calendar.date(byAdding: .day, value: -14, to: now) ?? now, calendar: calendar)
            for (uid, days) in stored.shown {
                let kept = days.filter { $0 > cutoff }
                stored.shown[uid] = kept.isEmpty ? nil : kept
            }
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            return (try? e.encode(stored)) ?? Data()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
