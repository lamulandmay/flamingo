import EventKit
import Foundation

/// Apple Calendar events and Reminders (adapter `eventkit`). The mapping is pure and tested;
/// `EventKitSource` reads the stores.
public enum EventKitAdapter {
    /// What an `eventkit` card's `source` selects: `events`, `reminders`, or both (empty or
    /// `all`), optionally limited to calendars and lists by title: `events: School, Family`.
    public struct Selection: Equatable, Sendable {
        public var events: Bool
        public var reminders: Bool
        /// Lowercased titles; empty means every calendar.
        public var calendars: [String]

        public init(events: Bool = true, reminders: Bool = true, calendars: [String] = []) {
            self.events = events; self.reminders = reminders; self.calendars = calendars
        }

        public init(source: String) {
            let parts = source.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let kind = parts.first?.lowercased() ?? ""
            events = kind != "reminders"
            reminders = kind != "events"
            calendars = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                : []
        }

        public func includes(calendar title: String) -> Bool {
            calendars.isEmpty || calendars.contains(title.lowercased())
        }
    }

    /// An event as EventKit returned it, one per occurrence.
    public struct EventSnapshot: Equatable, Sendable {
        public var identifier: String
        public var title: String
        public var start: Date
        public var end: Date?
        public var allDay: Bool
        public var calendar: String
        public var cancelled: Bool
        public var link: String?
        public var notes: String?

        public init(identifier: String, title: String, start: Date, end: Date?, allDay: Bool, calendar: String,
                    cancelled: Bool = false, link: String? = nil, notes: String? = nil) {
            self.identifier = identifier; self.title = title; self.start = start; self.end = end
            self.allDay = allDay; self.calendar = calendar; self.cancelled = cancelled
            self.link = link; self.notes = notes
        }
    }

    /// An incomplete reminder with a due date.
    public struct ReminderSnapshot: Equatable, Sendable {
        public var identifier: String
        public var title: String
        public var due: Date
        public var allDay: Bool
        public var list: String
        public var link: String?
        public var notes: String?

        public init(identifier: String, title: String, due: Date, allDay: Bool, list: String,
                    link: String? = nil, notes: String? = nil) {
            self.identifier = identifier; self.title = title; self.due = due; self.allDay = allDay
            self.list = list; self.link = link; self.notes = notes
        }
    }

    /// Events by the iCal rules (deadlines when the card's role is `deadlines`, ids
    /// `<identifier>@<start epoch>` since every occurrence shares one identifier); reminders
    /// become deadlines. The calendar or list title is the item's category, so include and
    /// exclude can name it.
    public static func items(events: [EventSnapshot], reminders: [ReminderSnapshot], card: PurposeCard,
                             now: Date, timeZone: TimeZone) -> [ConnectorItem] {
        let card = card.clamped()
        let range = card.window.range(now: now, timeZone: timeZone)
        let fetchedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        func clean(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
        var out: [ConnectorItem] = []
        var taken = Set<String>()
        func add(_ item: ConnectorItem) {
            guard !item.title.isEmpty, item.falls(in: range), card.keeps(item), taken.insert(item.id).inserted else { return }
            out.append(item)
        }
        for event in events where !event.cancelled {
            let deadline = card.role == .deadlines
            add(ConnectorItem(id: "\(event.identifier)@\(ICalAdapter.epoch(event.start))", connector: card.id,
                              kind: deadline ? .deadline : .event, title: clean(event.title), start: event.start,
                              end: event.end, due: deadline ? event.start : nil, allDay: event.allDay,
                              categories: [event.calendar], link: event.link,
                              summary: event.notes.map { String($0.prefix(1_000)) }, fetchedAt: fetchedAt))
        }
        for reminder in reminders {
            add(ConnectorItem(id: reminder.identifier, connector: card.id, kind: .deadline, title: clean(reminder.title),
                              due: reminder.due, allDay: reminder.allDay, categories: [reminder.list], link: reminder.link,
                              summary: reminder.notes.map { String($0.prefix(1_000)) }, fetchedAt: fetchedAt))
        }
        return out.sorted(by: ConnectorItem.ordered)
    }

    /// A reminder's due date from its components: midnight in its zone (or `local`) when it has
    /// no time of day.
    public static func due(_ components: DateComponents, local: TimeZone) -> (date: Date, allDay: Bool)? {
        var parts = components
        let zone = parts.timeZone ?? local
        parts.calendar = nil
        parts.timeZone = nil
        let allDay = parts.hour == nil
        if allDay { parts.hour = 0; parts.minute = 0; parts.second = 0 }
        guard parts.year != nil, parts.month != nil, parts.day != nil, let date = feedCalendar(zone).date(from: parts) else { return nil }
        return (date, allDay)
    }
}

/// Reads Calendar and Reminders through EventKit. Access is asked for by the app when the
/// person adds an `eventkit` card (`requestAccess`); a refresh never asks, it fails as
/// `accessDenied`.
public final class EventKitSource: @unchecked Sendable {
    public static let shared = EventKitSource()

    private let lock = NSLock()
    private var cached: EKEventStore?

    public init() {}

    /// Made on first use, so a process that never reads calendars never opens the store.
    private var store: EKEventStore {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let made = EKEventStore()
        cached = made
        return made
    }

    public static func hasAccess(to selection: EventKitAdapter.Selection) -> Bool {
        (!selection.events || EKEventStore.authorizationStatus(for: .event) == .fullAccess)
            && (!selection.reminders || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)
    }

    /// Asks for full access to what `selection` reads; true when everything it needs is granted.
    public func requestAccess(for selection: EventKitAdapter.Selection) async throws -> Bool {
        var granted = true
        if selection.events, EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            granted = try await store.requestFullAccessToEvents() && granted
        }
        if selection.reminders, EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            granted = try await store.requestFullAccessToReminders() && granted
        }
        return granted
    }

    public func items(for card: PurposeCard, now: Date, timeZone: TimeZone) async throws -> [ConnectorItem] {
        let selection = EventKitAdapter.Selection(source: card.source)
        guard Self.hasAccess(to: selection) else { throw ConnectorError.accessDenied }
        let store = self.store
        let range = card.clamped().window.range(now: now, timeZone: timeZone)
        var events: [EventKitAdapter.EventSnapshot] = []
        if selection.events {
            let calendars = store.calendars(for: .event).filter { selection.includes(calendar: $0.title) }
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: range.lowerBound, end: range.upperBound, calendars: calendars)
                events = store.events(matching: predicate).compactMap { EventKitSource.eventSnapshot($0) }
            }
        }
        var reminders: [EventKitAdapter.ReminderSnapshot] = []
        if selection.reminders {
            let lists = store.calendars(for: .reminder).filter { selection.includes(calendar: $0.title) }
            if !lists.isEmpty {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: range.lowerBound,
                                                                      ending: range.upperBound, calendars: lists)
                reminders = await withCheckedContinuation { (done: CheckedContinuation<[EventKitAdapter.ReminderSnapshot], Never>) in
                    _ = store.fetchReminders(matching: predicate) { found in
                        done.resume(returning: (found ?? []).compactMap { EventKitSource.reminderSnapshot($0, local: timeZone) })
                    }
                }
            }
        }
        return EventKitAdapter.items(events: events, reminders: reminders, card: card, now: now, timeZone: timeZone)
    }

    // EventKit's Objective-C properties are implicitly unwrapped; `as T?` reads them either way.
    static func eventSnapshot(_ event: EKEvent) -> EventKitAdapter.EventSnapshot? {
        guard let start = event.startDate as Date? else { return nil }
        let identifier = (event.eventIdentifier as String?) ?? event.calendarItemIdentifier
        return EventKitAdapter.EventSnapshot(identifier: identifier, title: (event.title as String?) ?? "", start: start,
                                             end: event.endDate as Date?, allDay: event.isAllDay,
                                             calendar: (event.calendar as EKCalendar?)?.title ?? "", cancelled: event.status == .canceled,
                                             link: event.url?.absoluteString, notes: event.notes)
    }

    static func reminderSnapshot(_ reminder: EKReminder, local: TimeZone) -> EventKitAdapter.ReminderSnapshot? {
        guard !reminder.isCompleted, let components = reminder.dueDateComponents,
              let due = EventKitAdapter.due(components, local: local) else { return nil }
        return EventKitAdapter.ReminderSnapshot(identifier: reminder.calendarItemIdentifier, title: (reminder.title as String?) ?? "",
                                                due: due.date, allDay: due.allDay, list: (reminder.calendar as EKCalendar?)?.title ?? "",
                                                link: reminder.url?.absoluteString, notes: reminder.notes)
    }
}
