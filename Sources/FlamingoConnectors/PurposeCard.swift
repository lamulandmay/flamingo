import Foundation

/// Where a connector's items come from. A card names one; the code for each lives in this module,
/// so a card is config and never code.
public enum ConnectorAdapter: String, Codable, Sendable, CaseIterable {
    case ical, eventkit, imap, json

    /// What the user calls it, for "not available yet".
    public var title: String {
        switch self {
        case .ical: return "Calendar feeds"
        case .eventkit: return "Apple Calendar"
        case .imap: return "Mail"
        case .json: return "JSON feeds"
        }
    }
}

/// What a connector's items are for.
public enum ConnectorRole: String, Codable, Sendable, CaseIterable {
    /// Things due: assignments, exams. Events become deadlines due at their start.
    case deadlines
    /// Things to attend.
    case schedule
    /// Messages that may need a reply.
    case inbox
    /// Background, ranked low.
    case reference
}

/// Who wrote the card.
public enum CardAuthor: String, Codable, Sendable {
    case claude, local, person
}

/// How far back and ahead a connector keeps items, in whole days around today.
public struct ConnectorWindow: Codable, Equatable, Sendable {
    public var daysBack: Int
    public var daysAhead: Int

    public init(daysBack: Int = 1, daysAhead: Int = 60) {
        self.daysBack = daysBack; self.daysAhead = daysAhead
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysBack = (try? c.decodeIfPresent(Int.self, forKey: .daysBack)) ?? 1
        daysAhead = (try? c.decodeIfPresent(Int.self, forKey: .daysAhead)) ?? 60
    }

    /// From the start of today minus `daysBack` up to the start of the day after the last day
    /// ahead, in `timeZone`.
    public func range(now: Date, timeZone: TimeZone) -> Range<Date> {
        let cal = feedCalendar(timeZone)
        let today = cal.startOfDay(for: now)
        let lower = cal.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let upper = cal.date(byAdding: .day, value: daysAhead + 1, to: today) ?? today
        return lower..<max(lower, upper)
    }
}

/// One connector: what it reads, what it is for, and which of its items matter. Written by Claude
/// from the person's description (or by the person), stored as JSON by `ConnectorStore`.
/// Keys this version doesn't know are kept and written back, so a newer card survives a save.
public struct PurposeCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var adapter: ConnectorAdapter
    /// What the card may show: `https://host` for a feed (the full address is a secret), a
    /// selection for EventKit. Never a token.
    public var source: String
    /// The person's own description, verbatim.
    public var described: String
    public var purpose: String
    public var role: ConnectorRole
    public var refreshMinutes: Int
    public var window: ConnectorWindow
    /// Whole words or phrases; an item must match one when the list isn't empty.
    public var include: [String]
    /// Whole words or phrases; a match drops the item, even when it is included.
    public var exclude: [String]
    /// How much its items count next to other connectors: 0 to 2, 1 is normal.
    public var weight: Double
    public var createdBy: CardAuthor
    public var enabled: Bool
    var extra: [String: JSONValue] = [:]

    public init(id: String, name: String, adapter: ConnectorAdapter, source: String, described: String = "",
                purpose: String = "", role: ConnectorRole = .reference, refreshMinutes: Int = 30,
                window: ConnectorWindow = ConnectorWindow(), include: [String] = [], exclude: [String] = [],
                weight: Double = 1, createdBy: CardAuthor = .person, enabled: Bool = true) {
        self.id = id; self.name = name; self.adapter = adapter; self.source = source
        self.described = described; self.purpose = purpose; self.role = role
        self.refreshMinutes = refreshMinutes; self.window = window; self.include = include
        self.exclude = exclude; self.weight = weight; self.createdBy = createdBy; self.enabled = enabled
    }

    public static let maxIDLength = 48

    /// "École Calendar!" → `ecole-calendar`. Lowercase ASCII letters, digits and single dashes,
    /// at most 48 characters, never starting or ending in a dash; `connector` when nothing is left.
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        out = String(out.prefix(maxIDLength))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "connector" : out
    }

    /// The numbers a model can't be trusted with, limited: refresh 5 minutes to a day, 0 to 30
    /// days back, 1 to 366 ahead, weight 0 to 2 (anything not a number becomes 1). Words are
    /// trimmed, blanks dropped, at most 20 of each.
    public func clamped() -> PurposeCard {
        var card = self
        card.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        card.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        card.refreshMinutes = min(max(refreshMinutes, 5), 24 * 60)
        card.window.daysBack = min(max(window.daysBack, 0), 30)
        card.window.daysAhead = min(max(window.daysAhead, 1), 366)
        card.weight = weight.isFinite ? min(max(weight, 0), 2) : 1
        func words(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                .prefix(20).map { $0 }
        }
        card.include = words(include)
        card.exclude = words(exclude)
        return card
    }

    /// Whether an item with this title and these categories stays. Exclude wins; a non-empty
    /// include list needs one match. Terms match whole words, ignoring case and accents, a
    /// several-word term matches those words in a row, and the item's word may add a plural
    /// `s` or `es`: "exam" matches "Exams" but not "example", "art" doesn't match "start".
    public func keeps(title: String, categories: [String]) -> Bool {
        let texts = ([title] + categories).map(Self.words)
        func matches(_ term: String) -> Bool {
            let needle = Self.words(term)
            guard !needle.isEmpty else { return false }
            return texts.contains { Self.contains($0, needle) }
        }
        let excludes = exclude.filter { !Self.words($0).isEmpty }
        if excludes.contains(where: matches) { return false }
        let includes = include.filter { !Self.words($0).isEmpty }
        return includes.isEmpty || includes.contains(where: matches)
    }

    public func keeps(_ item: ConnectorItem) -> Bool { keeps(title: item.title, categories: item.categories) }

    /// Lowercased, accent-free words: runs of letters and digits.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func contains(_ hay: [String], _ needle: [String]) -> Bool {
        guard hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) {
            var all = true
            for (offset, term) in needle.enumerated() {
                let word = hay[start + offset]
                if word != term && word != term + "s" && word != term + "es" { all = false; break }
            }
            if all { return true }
        }
        return false
    }
}

extension PurposeCard: Codable {
    private static let known: Set<String> = ["id", "name", "adapter", "source", "described", "purpose", "role",
                                             "refreshMinutes", "window", "include", "exclude", "weight",
                                             "createdBy", "enabled"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ name: String) -> AnyKey { AnyKey(name) }
        func string(_ name: String) -> String? { (try? c.decodeIfPresent(String.self, forKey: key(name))) ?? nil }
        func number(_ name: String) -> Double? {
            if let int = (try? c.decodeIfPresent(Int.self, forKey: key(name))) ?? nil { return Double(int) }
            return (try? c.decodeIfPresent(Double.self, forKey: key(name))) ?? nil
        }
        func strings(_ name: String) -> [String] { ((try? c.decodeIfPresent([String].self, forKey: key(name))) ?? nil) ?? [] }

        id = try c.decode(String.self, forKey: key("id"))
        name = try c.decode(String.self, forKey: key("name"))
        adapter = try c.decode(ConnectorAdapter.self, forKey: key("adapter"))
        source = string("source") ?? ""
        described = string("described") ?? ""
        purpose = string("purpose") ?? ""
        role = string("role").flatMap(ConnectorRole.init(rawValue:)) ?? .reference
        refreshMinutes = number("refreshMinutes").map { $0.isFinite ? Int(max(min($0, 1e6), -1e6)) : 30 } ?? 30
        window = ((try? c.decodeIfPresent(ConnectorWindow.self, forKey: key("window"))) ?? nil) ?? ConnectorWindow()
        include = strings("include")
        exclude = strings("exclude")
        weight = number("weight") ?? 1
        createdBy = string("createdBy").flatMap(CardAuthor.init(rawValue:)) ?? .person
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: key("enabled"))) ?? nil) ?? true
        for k in c.allKeys where !Self.known.contains(k.stringValue) {
            if let value = try? c.decode(JSONValue.self, forKey: k) { extra[k.stringValue] = value }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, value) in extra where !Self.known.contains(k) { try c.encode(value, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(adapter, forKey: AnyKey("adapter"))
        try c.encode(source, forKey: AnyKey("source"))
        try c.encode(described, forKey: AnyKey("described"))
        try c.encode(purpose, forKey: AnyKey("purpose"))
        try c.encode(role, forKey: AnyKey("role"))
        try c.encode(refreshMinutes, forKey: AnyKey("refreshMinutes"))
        try c.encode(window, forKey: AnyKey("window"))
        try c.encode(include, forKey: AnyKey("include"))
        try c.encode(exclude, forKey: AnyKey("exclude"))
        try c.encode(weight, forKey: AnyKey("weight"))
        try c.encode(createdBy, forKey: AnyKey("createdBy"))
        try c.encode(enabled, forKey: AnyKey("enabled"))
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Any JSON value, for keys a card carries that this version doesn't know.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Gregorian in `zone`, whatever calendar the user picked: feed dates are Gregorian.
func feedCalendar(_ zone: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal
}
