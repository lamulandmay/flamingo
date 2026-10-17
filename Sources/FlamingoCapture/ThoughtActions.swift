import Foundation
import FlamingoCore
import FlamingoDesign

extension KindGlyph {
    /// The glyph for a Core thought.
    public init(kind: ThoughtKind, state: ThoughtState = .open, size: CGFloat = Theme.Size.iconSmall) {
        self.init(kind: KindGlyph.Kind(rawValue: kind.rawValue) ?? .idea,
                  state: KindGlyph.State(rawValue: state.rawValue) ?? .open, size: size)
    }
}

/// A recipe the rail can ask for on one thought ("Work on This Now").
public enum RailRecipe: String, CaseIterable, Identifiable, Sendable {
    case reviewConflict = "review-conflict"
    case compareVersions = "compare-versions"
    case summarize
    case answer
    case findRelated = "find-related"

    public var id: String { rawValue }
    /// The menu item.
    public var title: String {
        switch self {
        case .reviewConflict: "Review Conflict"
        case .compareVersions: "Compare Versions"
        case .summarize: "Summarize"
        case .answer: "Answer"
        case .findRelated: "Find Related"
        }
    }
}

/// When a snoozed thought comes back.
public enum RailSnooze: String, CaseIterable, Identifiable, Sendable {
    case tomorrow, nextWeek
    public var id: String { rawValue }
    public var title: String { self == .tomorrow ? "Tomorrow" : "Next Week" }

    /// Tomorrow 09:00, or next Monday 09:00.
    public func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        var day = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        if self == .nextWeek {
            while calendar.component(.weekday, from: day) != 2 { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}

extension Comment {
    /// This thought with a new state. Done and dismissed clear a snooze; snoozed records when it
    /// returns. Carries a uid, so the copy can be saved with `SidecarStore.update(uid:in:)`.
    public func settingState(_ state: ThoughtState, snoozeUntil: Date? = nil, now: Date = Date()) -> Comment {
        var copy = stamped(now: now)
        copy.meta?.state = state == .open ? nil : state
        copy.meta?.stateAt = ThoughtDates.stamp(now)
        copy.meta?.snoozeUntil = state == .snoozed ? snoozeUntil.map { ThoughtDates.stamp($0) } : nil
        return copy
    }

    /// This thought with the kind the person chose (`kindBy: user`).
    public func settingKind(_ kind: ThoughtKind) -> Comment {
        var copy = stamped()
        copy.meta?.kind = kind
        copy.meta?.kindBy = .user
        return copy
    }

    /// This thought as an answer to the thought with `parentUID`.
    public func replying(toUID parentUID: String) -> Comment {
        var copy = stamped()
        copy.meta?.parent = parentUID
        return copy
    }
}

/// How a rail row reads a thought: the kind and due it shows. A person's or a model's decision
/// (`meta.kind`) wins; otherwise the words are read (`ThoughtRules`), which is instant.
struct RailReading: Equatable {
    var kind: ThoughtKind
    var due: Date?

    nonisolated(unsafe) private static var cache: [String: RailReading] = [:]
    private static let lock = NSLock()

    static func of(_ c: Comment, calendar: Calendar = .current) -> RailReading {
        // Replies from an AI and their like say what they say; only stored decisions count.
        let storedDue = c.meta?.due.flatMap { ThoughtDates.parse($0, calendar: calendar)?.date }
        let ai = c.provenance?.origin == .ai
        if ai { return RailReading(kind: c.meta?.kind ?? .idea, due: storedDue) }
        let key = "\(c.timestamp.timeIntervalSince1970)|\(c.text)"
        lock.lock()
        var read = cache[key]
        lock.unlock()
        if read == nil {
            let r = ThoughtRules.read(c.text, at: c.timestamp, calendar: calendar)
            let value = RailReading(kind: r.kind, due: r.due?.date)
            lock.lock()
            if cache.count > 4_000 { cache.removeAll() }
            cache[key] = value
            lock.unlock()
            read = value
        }
        return RailReading(kind: c.meta?.kind ?? read!.kind, due: storedDue ?? read!.due)
    }

    /// `fri` for a day in the coming week, `Oct 23` otherwise (also for a day already past).
    static func dueLabel(_ due: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 99
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        if (0..<7).contains(days) {
            f.setLocalizedDateFormatFromTemplate("EEE")
            return f.string(from: due).lowercased()
        }
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: due)
    }
}
