import Foundation

public enum ThoughtKind: String, Codable, Sendable, CaseIterable { case idea, question, todo, intent }
public enum ThoughtState: String, Codable, Sendable, CaseIterable { case open, done, snoozed, dismissed }
/// Who decided a thought's kind. Only `model` and `user` decisions are persisted; the
/// deterministic reading of the text (`ThoughtRules`) is recomputed whenever it is needed.
public enum ThoughtDecider: String, Codable, Sendable { case rules, model, user }

/// What a thought asks to be done, as understood by a local model.
public struct ThoughtIntent: Hashable, Codable, Sendable {
    /// `review-conflict`, `compare-versions`, `summarize`, `answer`, `find-related`, `remind`, `connect`, `open`.
    public var action: String
    /// `finance/q3-model.xlsx` or `decks/q3.pptx#slide 7`; at most six.
    public var objects: [String]
    public var confidence: Double?
    public var model: String?
    /// `yyyy-MM-dd HH:mm`, local.
    public var at: String?

    public init(action: String, objects: [String] = [], confidence: Double? = nil, model: String? = nil, at: String? = nil) {
        self.action = action; self.objects = Array(objects.prefix(6)); self.confidence = confidence; self.model = model; self.at = at
    }
}

/// Everything a thought carries beyond its text, timestamp and anchor. Lives in the same
/// hidden `<!-- flamingo: {...} -->` line as the provenance, so Obsidian shows none of it.
///
/// Only decisions are persisted; see `ThoughtRules` for what is read from the text instead.
public struct ThoughtMeta: Hashable, Codable, Sendable {
    /// `t` + 9 Crockford base32 characters, stable across text edits (see `ThoughtUID`).
    public var uid: String?
    /// The uid of the thought this one answers (same note). Replies are separate bullets.
    public var parent: String?
    public var kind: ThoughtKind?
    public var kindBy: ThoughtDecider?
    public var state: ThoughtState?
    /// `yyyy-MM-dd HH:mm`, local: when `state` last changed.
    public var stateAt: String?
    /// `yyyy-MM-dd` or `yyyy-MM-dd HH:mm`, local.
    public var due: String?
    public var snoozeUntil: String?
    /// `yyyy-MM-dd HH:mm`, local: when the text was last edited.
    public var modified: String?
    public var intent: ThoughtIntent?
    /// The memo path relative to `.flamingo`, on an AI reply that carries a work memo.
    public var work: String?

    /// Keys this build does not know, kept so a note round-trips.
    var extra: [String: MetaJSON] = [:]
    /// Hidden lines that were not a JSON object, verbatim (one per line), written back as they were.
    var unparsed: String?

    public init(uid: String? = nil, parent: String? = nil, kind: ThoughtKind? = nil, kindBy: ThoughtDecider? = nil,
                state: ThoughtState? = nil, stateAt: String? = nil, due: String? = nil, snoozeUntil: String? = nil,
                modified: String? = nil, intent: ThoughtIntent? = nil, work: String? = nil) {
        self.uid = uid; self.parent = parent; self.kind = kind; self.kindBy = kindBy; self.state = state
        self.stateAt = stateAt; self.due = due; self.snoozeUntil = snoozeUntil; self.modified = modified
        self.intent = intent; self.work = work
    }

    /// True when nothing would be written to the JSON line.
    var hasFields: Bool {
        uid != nil || parent != nil || kind != nil || kindBy != nil || state != nil || stateAt != nil || due != nil
            || snoozeUntil != nil || modified != nil || intent != nil || work != nil || !extra.isEmpty
    }

    /// Names of keys carried through unchanged that this build does not understand.
    public var unknownKeys: [String] { extra.keys.sorted() }

    /// The effective state: a missing state is open.
    public var effectiveState: ThoughtState { state ?? .open }

    // MARK: Line mapping

    static let keys: Set<String> = ["uid", "parent", "kind", "kindBy", "state", "stateAt", "due", "snoozeUntil", "modified", "intent", "work"]

    /// The keys of the hidden line this meta contributes, never including provenance keys.
    func fields() -> [String: MetaJSON] {
        var out = extra
        func put(_ key: String, _ value: String?) { if let value { out[key] = .string(value) } }
        put("uid", uid); put("parent", parent); put("kind", kind?.rawValue); put("kindBy", kindBy?.rawValue)
        put("state", state?.rawValue); put("stateAt", stateAt); put("due", due); put("snoozeUntil", snoozeUntil)
        put("modified", modified); put("work", work)
        if let intent, let object = MetaJSON.object(from: intent) { out["intent"] = .object(object) }
        return out
    }

    /// Takes the keys it understands out of `object`. A key with a value of the wrong type
    /// is left in `extra`, so a note written by a different build is never damaged.
    init(taking object: inout [String: MetaJSON]) {
        func string(_ key: String) -> String? {
            guard case .string(let s)? = object[key] else { return nil }
            object[key] = nil
            return s
        }
        func raw<T: RawRepresentable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
            guard case .string(let s)? = object[key], let v = T(rawValue: s) else { return nil }
            object[key] = nil
            return v
        }
        uid = string("uid"); parent = string("parent")
        kind = raw("kind", ThoughtKind.self); kindBy = raw("kindBy", ThoughtDecider.self)
        state = raw("state", ThoughtState.self); stateAt = string("stateAt")
        due = string("due"); snoozeUntil = string("snoozeUntil"); modified = string("modified"); work = string("work")
        if let value = object["intent"], let decoded = MetaJSON.decode(ThoughtIntent.self, from: value) {
            intent = decoded
            object["intent"] = nil
        }
        extra = object
    }
}

/// Dates in thought metadata are local `yyyy-MM-dd` or `yyyy-MM-dd HH:mm` strings.
public enum ThoughtDates {
    private static func components(_ date: Date, _ calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    public static func string(from date: Date, hasTime: Bool, calendar: Calendar = .current) -> String {
        let c = components(date, calendar)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return hasTime ? day + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0) : day
    }

    /// `(date, hasTime)` for `yyyy-MM-dd` (start of that day) or `yyyy-MM-dd HH:mm`.
    public static func parse(_ text: String, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard day.count == 3, parts[0].count == 10 else { return nil }
        var c = DateComponents(year: day[0], month: day[1], day: day[2])
        if parts.count == 2 {
            let time = parts[1].split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard time.count == 2, (0..<24).contains(time[0]), (0..<60).contains(time[1]) else { return nil }
            c.hour = time[0]; c.minute = time[1]
        }
        guard let date = calendar.date(from: c) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == day[0], back.month == day[1], back.day == day[2] else { return nil }
        return (date, parts.count == 2)
    }

    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        string(from: date, hasTime: true, calendar: calendar)
    }
}
