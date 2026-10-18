import Foundation

/// One thing a connector brought in. Items stay on this Mac (`ConnectorStore`) and are not
/// thoughts: they never go into a sidecar and nothing in them is sent to Claude.
public struct ConnectorItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case deadline, event, message
    }

    /// Stable across refreshes: the feed's UID, `uid@<occurrence epoch>` for a repeating or
    /// reused UID, or a hash of title and time when the feed has none.
    public var id: String
    /// The card it came from.
    public var connector: String
    public var kind: Kind
    public var title: String
    public var start: Date?
    public var end: Date?
    public var due: Date?
    public var allDay: Bool
    public var categories: [String]
    public var link: String?
    public var summary: String?
    public var needsReply: Bool
    public var fetchedAt: Date

    public init(id: String, connector: String, kind: Kind, title: String, start: Date? = nil, end: Date? = nil,
                due: Date? = nil, allDay: Bool = false, categories: [String] = [], link: String? = nil,
                summary: String? = nil, needsReply: Bool = false, fetchedAt: Date) {
        self.id = id; self.connector = connector; self.kind = kind; self.title = title
        self.start = start; self.end = end; self.due = due; self.allDay = allDay
        self.categories = categories; self.link = link; self.summary = summary
        self.needsReply = needsReply; self.fetchedAt = fetchedAt
    }

    /// The due date if there is one, otherwise the start.
    public var when: Date? { due ?? start }

    /// Inside a card's window: a deadline or message by its date (undated ones stay), an event
    /// when any part of it overlaps.
    public func falls(in range: Range<Date>) -> Bool {
        switch kind {
        case .deadline, .message:
            guard let when else { return true }
            return range.contains(when)
        case .event:
            guard let start else { return false }
            let finish = max(end ?? start, start)
            return start < range.upperBound && (start >= range.lowerBound || finish > range.lowerBound)
        }
    }

    /// Equal apart from when it was fetched: a newer fetch alone is not a change.
    public func sameContent(as other: ConnectorItem) -> Bool {
        var copy = other
        copy.fetchedAt = fetchedAt
        return copy == self
    }

    /// Soonest first, undated last, then by title and id.
    static func ordered(_ a: ConnectorItem, _ b: ConnectorItem) -> Bool {
        switch (a.when, b.when) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}
