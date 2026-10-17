import Foundation
import FlamingoCore

/// One line of `.flamingo/work/ledger.jsonl`.
public struct LedgerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nightStart = "night-start"
        case queued, started, finished, replied, failed
        case nightEnd = "night-end"
        case catchUpStart = "catchup-start"
        case catchUpEnd = "catchup-end"
    }

    public var event: Kind
    public var at: Date
    /// The night (`yyyy-MM-dd`, the date its window opened) or the briefing day of a catch-up.
    public var night: String?
    /// `<uid>:<recipe>:<8 hex>`.
    public var job: String?
    public var uid: String?
    public var recipe: String?
    public var file: String?
    /// `finished`: the memo path relative to `.flamingo`.
    public var memo: String?
    public var model: String?
    public var tokens: Int?
    public var seconds: Double?
    /// `started` and `failed`: which try this was (1 or 2).
    public var attempt: Int?
    public var error: String?
    /// `failed`: no later try can help (the thought is gone, the files are).
    public var permanent: Bool?
    /// `night-end` and `catchup-end`: what happened, in a word.
    public var reason: String?

    public init(_ event: Kind, at: Date, night: String? = nil, job: String? = nil, uid: String? = nil, recipe: String? = nil,
                file: String? = nil, memo: String? = nil, model: String? = nil, tokens: Int? = nil, seconds: Double? = nil,
                attempt: Int? = nil, error: String? = nil, permanent: Bool? = nil, reason: String? = nil) {
        self.event = event; self.at = at; self.night = night; self.job = job; self.uid = uid; self.recipe = recipe
        self.file = file; self.memo = memo; self.model = model; self.tokens = tokens; self.seconds = seconds
        self.attempt = attempt; self.error = error; self.permanent = permanent; self.reason = reason
    }
}

/// Where a job stands, folded from its events.
public struct JobRecord: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Planned, never started.
        case queued
        /// Started and then nothing: a crash. Runs again if it has tries left.
        case interrupted
        /// The last try failed and another is allowed.
        case retryable
        /// A memo exists and its reply is not on the thought yet.
        case needsReply
        /// Memo and reply both done.
        case done
        /// Two tries, or a permanent failure. Left alone until its files change.
        case exhausted
    }

    public static let maxAttempts = 2

    public var id: String
    public var uid: String?
    public var recipe: String?
    public var attempts = 0
    public var finishedAt: Date?
    public var memo: String?
    public var repliedAt: Date?
    public var lastError: String?
    public var permanent = false
    public var lastEvent: LedgerEvent.Kind = .queued

    public var phase: Phase {
        if repliedAt != nil { return .done }
        if finishedAt != nil { return .needsReply }
        if permanent { return .exhausted }
        switch lastEvent {
        case .started: return attempts >= Self.maxAttempts ? .exhausted : .interrupted
        case .failed: return attempts >= Self.maxAttempts ? .exhausted : .retryable
        default: return .queued
        }
    }
}

/// The night shift's record of what it did, so a night never repeats itself and a crash
/// resumes where it stopped. Append-only; a torn last line (a crash mid-write) is ignored.
public final class WorkLedger: @unchecked Sendable {
    public let vault: Vault
    private let lock = NSLock()

    public init(vault: Vault) { self.vault = vault }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func append(_ event: LedgerEvent) throws {
        let data = try Self.encoder.encode(event)
        try lock.withLock { try WorkLedgerFile.append(String(decoding: data, as: UTF8.self), in: vault) }
    }

    /// Every complete, readable line, oldest first.
    public func events() -> [LedgerEvent] {
        lock.withLock { WorkLedgerFile.lines(in: vault) }.compactMap { try? Self.decoder.decode(LedgerEvent.self, from: Data($0.utf8)) }
    }

    /// Each job folded from its events.
    public func jobs() -> [String: JobRecord] { Self.fold(events()) }

    public func record(for job: String) -> JobRecord? { jobs()[job] }

    static func fold(_ events: [LedgerEvent]) -> [String: JobRecord] {
        var out: [String: JobRecord] = [:]
        for e in events {
            guard let id = e.job else { continue }
            var r = out[id] ?? JobRecord(id: id, uid: e.uid, recipe: e.recipe)
            r.uid = r.uid ?? e.uid; r.recipe = r.recipe ?? e.recipe
            switch e.event {
            case .queued: if r.attempts == 0 { r.lastEvent = .queued }
            case .started:
                r.attempts = max(r.attempts + 1, e.attempt ?? 0)
                r.lastEvent = .started
            case .finished:
                r.finishedAt = e.at; r.memo = e.memo ?? r.memo; r.lastEvent = .finished
            case .replied:
                r.repliedAt = e.at; r.lastEvent = .replied
            case .failed:
                r.lastError = e.error; r.lastEvent = .failed
                if e.permanent == true { r.permanent = true }
            case .nightStart, .nightEnd, .catchUpStart, .catchUpEnd: continue
            }
            out[id] = r
        }
        return out
    }

    /// What the gate needs: nights that ran to their end, days that had a catch-up.
    public func history() -> NightHistory {
        var h = NightHistory()
        for e in events() {
            switch e.event {
            case .nightEnd: if let n = e.night { h.endedNights.insert(n) }
            case .catchUpEnd: if let n = e.night { h.catchUpDays.insert(n) }
            default: break
            }
        }
        return h
    }

    /// The newest finished job for a thought and recipe, with when it finished: the planner's
    /// "sources changed, but it is too soon to look again".
    public func lastFinished(uid: String, recipe: String) -> (job: String, at: Date)? {
        jobs().values.filter { $0.uid == uid && $0.recipe == recipe && $0.finishedAt != nil }
            .compactMap { r in r.finishedAt.map { (r.id, $0) } }
            .max { $0.1 < $1.1 }
    }
}
