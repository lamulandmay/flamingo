import Foundation

/// What a feed looks like, without what it says: counts, which standard properties appear, and
/// the span of its dates. Never titles, descriptions, places, people or UIDs. Together with the
/// person's description and the link's host, this is all Claude sees of a connector.
public struct FeedShape: Codable, Equatable, Sendable {
    public var events: Int
    public var todos: Int
    public var allDay: Int
    public var repeating: Int
    /// Standard RFC 5545 property names that appear, sorted.
    public var properties: [String]
    /// How many `X-` properties there are; their names are not passed on.
    public var extensions: Int
    public var earliest: Date?
    public var latest: Date?

    public init(events: Int = 0, todos: Int = 0, allDay: Int = 0, repeating: Int = 0, properties: [String] = [],
                extensions: Int = 0, earliest: Date? = nil, latest: Date? = nil) {
        self.events = events; self.todos = todos; self.allDay = allDay; self.repeating = repeating
        self.properties = properties; self.extensions = extensions; self.earliest = earliest; self.latest = latest
    }

    public init(_ calendar: ICalendar, timeZone: TimeZone) {
        self.init()
        var names = Set<String>()
        for c in calendar.components {
            if c.kind == .event { events += 1 } else { todos += 1 }
            if c.first("RRULE") != nil { repeating += 1 }
            for p in c.properties {
                if p.name.hasPrefix("X-") { extensions += 1 } else if Self.standard.contains(p.name) { names.insert(p.name) }
            }
            let name = c.kind == .todo && c.first("DUE") != nil ? "DUE" : "DTSTART"
            guard let anchor = c.first(name).flatMap({ ICalendar.date($0, local: timeZone) }) else { continue }
            if anchor.allDay { allDay += 1 }
            earliest = min(earliest ?? anchor.date, anchor.date)
            latest = max(latest ?? anchor.date, anchor.date)
        }
        properties = names.sorted()
    }

    static let standard: Set<String> = [
        "ATTACH", "ATTENDEE", "CATEGORIES", "CLASS", "COLOR", "COMMENT", "COMPLETED", "CONTACT", "CREATED",
        "DESCRIPTION", "DTEND", "DTSTAMP", "DTSTART", "DUE", "DURATION", "EXDATE", "GEO", "LAST-MODIFIED",
        "LOCATION", "ORGANIZER", "PERCENT-COMPLETE", "PRIORITY", "RDATE", "RECURRENCE-ID", "RELATED-TO",
        "RESOURCES", "RRULE", "SEQUENCE", "STATUS", "SUMMARY", "TRANSP", "UID", "URL",
    ]

    /// One line for the prompt: `34 events, 12 to-dos (5 all day, 3 repeating); properties: …;
    /// dates 2026-09-01 to 2026-12-18`.
    public var summary: String {
        var line = "\(events) events, \(todos) to-dos (\(allDay) all day, \(repeating) repeating)"
        if !properties.isEmpty { line += "; properties: " + properties.joined(separator: ", ") }
        if extensions > 0 { line += "; \(extensions) extension properties" }
        if let earliest, let latest {
            let format = Date.ISO8601FormatStyle().year().month().day()
            line += "; dates \(earliest.formatted(format)) to \(latest.formatted(format))"
        }
        return line
    }
}

/// A system and user message for whichever client sends them.
public struct CardPrompt: Equatable, Sendable {
    public var system: String
    public var user: String
}

/// Turning "my school's ManageBac calendar, I only care about exams and essays" into a card.
/// Claude writes it when there is an API key (`prompt`, then `card(fromReply:…)`); otherwise
/// `heuristicCard` guesses one without the network.
public enum CardDrafting {
    public static let system = """
    You write a purpose card for a connector in Flamingo, a Mac app that shows a student what matters next. \
    You see only the person's description, the link's host and the feed's shape (counts and property names), \
    never its items. Reply with one JSON object and nothing else:
    {"name": "≤ 32 characters", "purpose": "one sentence: what this connector is for", \
    "role": "deadlines" | "schedule" | "inbox" | "reference", "refreshMinutes": 5 to 1440, \
    "window": {"daysBack": 0 to 30, "daysAhead": 1 to 366}, "include": [], "exclude": [], "weight": 0 to 2}
    Roles: deadlines are things due (assignments, exams; events count as due at their start); schedule is \
    things to attend; inbox is messages that may need a reply; reference is background. \
    include and exclude are whole words or short phrases matched against item titles and categories: an item \
    must match one include term when there are any, and any exclude term drops it. Leave both empty unless the \
    description asks to filter. weight is how much this matters next to other connectors; 1 is normal.
    """

    /// The person's description, the host (never the full link) and the shape.
    public static func prompt(description: String, host: String?, shape: FeedShape?) -> CardPrompt {
        var user = "Description: " + description.trimmingCharacters(in: .whitespacesAndNewlines)
        user += "\nHost: " + ((host?.isEmpty == false ? host : nil) ?? "none")
        user += "\nShape: " + (shape?.summary ?? "unknown")
        return CardPrompt(system: system, user: user)
    }

    /// The first JSON object in the reply (fences and prose around it are ignored), as a clamped
    /// card written by Claude. `id` is the name's slug; the app picks a free one
    /// (`ConnectorStore.freshID`) before saving. Throws `badDraft` without an object or a name.
    public static func card(fromReply reply: String, description: String, source: String,
                            adapter: ConnectorAdapter) throws -> PurposeCard {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8))) as? [String: Any],
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { throw ConnectorError.badDraft }
        let window = object["window"] as? [String: Any] ?? [:]
        let card = PurposeCard(
            id: PurposeCard.slug(name), name: String(name.prefix(48)), adapter: adapter, source: source,
            described: description,
            purpose: object["purpose"] as? String ?? "",
            role: (object["role"] as? String).flatMap { ConnectorRole(rawValue: $0.lowercased()) } ?? .reference,
            refreshMinutes: number(object["refreshMinutes"]).map { Int(max(min($0, 1e6), -1e6)) } ?? 30,
            window: ConnectorWindow(daysBack: number(window["daysBack"] ?? object["daysBack"]).map { Int(max(min($0, 1e4), -1e4)) } ?? 1,
                                    daysAhead: number(window["daysAhead"] ?? object["daysAhead"]).map { Int(max(min($0, 1e4), -1e4)) } ?? 60),
            include: strings(object["include"]), exclude: strings(object["exclude"]),
            weight: number(object["weight"]) ?? 1, createdBy: .claude)
        return card.clamped()
    }

    /// No key, no network: a card from the description's words. Deadlines for homework, exams
    /// and due dates; inbox for mail; schedule for classes and events; otherwise by the feed's
    /// shape (mostly to-dos means deadlines).
    public static func heuristicCard(description: String, source: String, adapter: ConnectorAdapter,
                                     shape: FeedShape? = nil) -> PurposeCard {
        let words = Set(PurposeCard.words(description))
        func mentions(_ list: [String]) -> Bool { list.contains { words.contains($0) || words.contains($0 + "s") } }
        let role: ConnectorRole
        if adapter == .imap || mentions(["email", "mail", "inbox", "message"]) { role = .inbox }
        else if mentions(["deadline", "due", "homework", "assignment", "exam", "test", "essay", "task", "todo", "managebac", "coursework"]) { role = .deadlines }
        else if mentions(["class", "timetable", "schedule", "event", "meeting", "lesson", "practice", "calendar"]) { role = .schedule }
        else if let shape, shape.todos > shape.events { role = .deadlines }
        else { role = adapter == .json ? .reference : .schedule }

        let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = firstLine
        if name.count > 32 {
            let cut = name.prefix(32)
            name = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        }
        if name.isEmpty {
            let host = URL(string: source)?.host ?? source
            let labels = host.split(separator: ".").filter { !["www", "com", "org", "net", "edu"].contains($0.lowercased()) }
            name = labels.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? adapter.title
        }
        let (refresh, window, weight): (Int, ConnectorWindow, Double) = switch role {
        case .deadlines: (60, ConnectorWindow(daysBack: 1, daysAhead: 60), 1.5)
        case .schedule: (30, ConnectorWindow(daysBack: 0, daysAhead: 30), 1)
        case .inbox: (15, ConnectorWindow(daysBack: 7, daysAhead: 7), 1)
        case .reference: (360, ConnectorWindow(daysBack: 1, daysAhead: 60), 0.5)
        }
        return PurposeCard(id: PurposeCard.slug(name), name: name, adapter: adapter, source: source,
                           described: description, purpose: firstLine, role: role, refreshMinutes: refresh,
                           window: window, weight: weight, createdBy: .person).clamped()
    }

    /// A JSON number (not a bool, which `NSNumber` would also give) or a numeric string.
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String, let n = Double(s.trimmingCharacters(in: .whitespaces)), n.isFinite { return n }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let one = value as? String { return one.split(separator: ",").map(String.init) }
        return []
    }
}
