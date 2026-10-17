import Foundation
import FlamingoCore
import FlamingoIndex

/// What else is known about a thought when ranking it, worked out by the snapshot builder
/// from the index, the trail and the briefing's history.
public struct ThoughtSignals: Sendable, Equatable {
    /// Its file, or a file it names, was edited after the thought was written.
    public var editedAfter = false
    /// A reply from a model arrived that the person hasn't seen.
    public var newAIReply = false
    /// The file was opened since, and the thought has no reply.
    public var openedWithoutReply = false
    /// Files joined to its file by thoughts and connections.
    public var degree = 0
    /// A memo for it is waiting to be read.
    public var memoReady = false
    /// A memo or a model's reply the person hasn't seen.
    public var awaitingUnseen = false
    /// A model's reply is a question for the person.
    public var aiQuestionAwaiting = false
    /// Briefings it was on in the last seven days without being acted on.
    public var timesSkipped = 0

    public init(editedAfter: Bool = false, newAIReply: Bool = false, openedWithoutReply: Bool = false, degree: Int = 0,
                memoReady: Bool = false, awaitingUnseen: Bool = false, aiQuestionAwaiting: Bool = false, timesSkipped: Int = 0) {
        self.editedAfter = editedAfter; self.newAIReply = newAIReply; self.openedWithoutReply = openedWithoutReply
        self.degree = degree; self.memoReady = memoReady; self.awaitingUnseen = awaitingUnseen
        self.aiQuestionAwaiting = aiQuestionAwaiting; self.timesSkipped = timesSkipped
    }
}

/// The terms of a thought's score, each before its weight.
public struct ScoreTerms: Sendable, Equatable {
    public var due = 0.0, kind = 0.0, strength = 0.0, staleness = 0.0, activity = 0.0
    public var centrality = 0.0, awaiting = 0.0, skips = 0.0
}

/// Why a thought is up there: its strongest reason.
public enum RankReason: Sendable, Equatable {
    case due, activity, awaiting, none

    /// SF Symbol for the row; nil when nothing stands out.
    public var symbol: String? {
        switch self {
        case .due: return "clock"
        case .activity: return "arrow.triangle.2.circlepath"
        case .awaiting: return "sparkle"
        case .none: return nil
        }
    }
}

public struct RankedThought: Identifiable, Sendable, Equatable {
    public var record: ThoughtRecord
    public var score: Double
    /// Overdue or due today: listed first, in due order.
    public var pinned: Bool
    public var reason: RankReason
    public var terms: ScoreTerms
    public var id: String { record.id }
}

/// Which thoughts to address first. Pure.
///
///     score = 3.0·Due + 1.6·Kind + 0.7·Strength + 1.0·Staleness + 1.2·Activity
///           + 0.5·Centrality + 1.5·Awaiting − 0.35·min(3, times skipped)
public struct AttentionRanker: Sendable {
    public var limit = 12
    public var calendar: Calendar

    public init(limit: Int = 12, calendar: Calendar = .current) { self.limit = limit; self.calendar = calendar }

    public static let weights = (due: 3.0, kind: 1.6, strength: 0.7, staleness: 1.0, activity: 1.2, centrality: 0.5, awaiting: 1.5, skip: 0.35)

    /// The top `limit` of `candidates`, best first. Done and dismissed thoughts are left out, as
    /// are snoozed ones until their snooze ends. Replies and thoughts a model wrote are never
    /// candidates themselves (their thread's root carries them).
    public func rank(_ candidates: [(record: ThoughtRecord, signals: ThoughtSignals)], now: Date) -> [RankedThought] {
        let maxDegree = max(1, candidates.map(\.signals.degree).max() ?? 1)
        var out: [RankedThought] = []
        for (r, s) in candidates {
            guard r.parent == nil, r.origin == .human else { continue }
            switch r.state {
            case .open: break
            case .snoozed: guard let until = r.snoozeUntil, until <= now else { continue }
            case .done, .dismissed: continue
            }
            let age = max(0, now.timeIntervalSince(r.comment.timestamp)) / 86_400
            let strength = ThoughtStrength(r.comment)
            let activity = s.editedAfter ? 1.0 : s.newAIReply ? 0.8 : s.openedWithoutReply ? 0.4 : 0.0
            let awaiting = s.awaitingUnseen ? 1.0 : 0.0

            let eligible = age <= 45 || r.due != nil || awaiting == 1 || (strength == .woven && r.kind != .idea)
            guard eligible else { continue }
            // Ideas don't nag: only when something happened around them or something is waiting.
            if r.kind == .idea, activity == 0, awaiting == 0 { continue }

            let terms = ScoreTerms(
                due: dueTerm(r.due, now: now),
                kind: kindTerm(r.kind, s),
                strength: [0.0, 0.5, 1.0][strength.rawValue],
                staleness: min(1, age / 1.5) * exp(-max(0, age - 7) / 21),
                activity: activity,
                centrality: log(1 + Double(max(0, s.degree))) / log(1 + Double(maxDegree)),
                awaiting: awaiting,
                skips: Double(min(3, max(0, s.timesSkipped))))
            let w = Self.weights
            let score = w.due * terms.due + w.kind * terms.kind + w.strength * terms.strength + w.staleness * terms.staleness
                + w.activity * terms.activity + w.centrality * terms.centrality + w.awaiting * terms.awaiting - w.skip * terms.skips
            let pinned = r.due.map { dayDelta(from: now, to: $0) <= 0 } ?? false
            out.append(RankedThought(record: r, score: score, pinned: pinned, reason: reason(terms), terms: terms))
        }
        out.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.pinned, let x = a.record.due, let y = b.record.due, x != y { return x < y }
            if a.score != b.score { return a.score > b.score }
            if a.record.comment.timestamp != b.record.comment.timestamp { return a.record.comment.timestamp > b.record.comment.timestamp }
            if a.record.file.relativePath != b.record.file.relativePath { return a.record.file.relativePath < b.record.file.relativePath }
            return a.record.id < b.record.id
        }
        return Array(out.prefix(limit))
    }

    /// Whole days from `now`'s day to `date`'s day: negative when overdue.
    func dayDelta(from now: Date, to date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    func dueTerm(_ due: Date?, now: Date) -> Double {
        guard let due else { return 0 }
        let d = dayDelta(from: now, to: due)
        switch d {
        case ..<0: return 1.0 + min(0.5, 0.1 * Double(-d))
        case 0: return 0.9
        case 1: return 0.55
        case 2...6: return 0.3 - 0.03 * Double(d)
        default: return 0
        }
    }

    func kindTerm(_ kind: ThoughtKind, _ s: ThoughtSignals) -> Double {
        var k: Double
        switch kind {
        case .todo: k = 1.0
        case .question: k = 0.85
        case .intent: k = s.memoReady ? 1.0 : 0.8
        case .idea: k = 0.2
        }
        if s.aiQuestionAwaiting { k = max(k, 0.9) }
        return k
    }

    func reason(_ t: ScoreTerms) -> RankReason {
        let w = Self.weights
        let due = w.due * t.due, awaiting = w.awaiting * t.awaiting, activity = w.activity * t.activity
        let best = max(due, awaiting, activity)
        guard best > 0 else { return .none }
        if due == best { return .due }
        if awaiting == best { return .awaiting }
        return .activity
    }
}
