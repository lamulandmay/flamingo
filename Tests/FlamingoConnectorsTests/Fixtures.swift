import Foundation
@testable import FlamingoConnectors

/// Made-up feeds. "Now" is 2026-10-18 12:00 UTC (a Sunday), 08:00 in New York, the local zone.
/// Europe leaves summer time on 25 October, the US on 1 November. Every epoch below was checked
/// with `date -u -r`.
enum Fixtures {
    static let now = Date(timeIntervalSince1970: 1_792_324_800)
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let utcZone = TimeZone(identifier: "UTC")!

    static func utc(_ iso: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: iso) else { fatalError("bad fixture date \(iso)") }
        return date
    }

    static func epoch(_ iso: String) -> Int { Int(utc(iso).timeIntervalSince1970) }

    static func card(_ id: String = "school", adapter: ConnectorAdapter = .ical, role: ConnectorRole = .deadlines,
                     window: ConnectorWindow = ConnectorWindow(), include: [String] = [], exclude: [String] = [],
                     refreshMinutes: Int = 30, enabled: Bool = true) -> PurposeCard {
        PurposeCard(id: id, name: id.capitalized, adapter: adapter, source: "https://school.example",
                    described: "School planner", purpose: "Deadlines", role: role, refreshMinutes: refreshMinutes,
                    window: window, include: include, exclude: exclude, enabled: enabled)
    }

    static func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    /// An assignment (folded, escaped title, an alarm inside), a maths exam in Amsterdam time, a
    /// cancelled all-day trip, an essay to-do in an Outlook zone, and band practice with no zone
    /// and no UID (DURATION instead of DTEND).
    static let schoolText = crlf(#"""
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example School//Planner//EN
    X-WR-CALNAME:School
    BEGIN:VTIMEZONE
    TZID:Europe/Amsterdam
    BEGIN:STANDARD
    DTSTART:19701025T030000
    TZOFFSETFROM:+0200
    TZOFFSETTO:+0100
    TZNAME:CET
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    UID:assign-1@school.example
    DTSTAMP:20261001T000000Z
    DTSTART:20261020T220000Z
    SUMMARY:History essay\, draft 2: the long
      road
    CATEGORIES:History,Essay\,Draft
    DESCRIPTION:Upload to the portal.\nTwo pages.
    URL:https://school.example/tasks/1
    BEGIN:VALARM
    ACTION:DISPLAY
    TRIGGER:-PT1H
    SUMMARY:Alarm inside
    END:VALARM
    END:VEVENT
    BEGIN:VEVENT
    UID:exam-maths@school.example
    DTSTART;TZID=Europe/Amsterdam:20261027T090000
    DTEND;TZID=Europe/Amsterdam:20261027T103000
    SUMMARY:Maths exam
    CATEGORIES:Exams
    END:VEVENT
    BEGIN:VEVENT
    UID:trip@school.example
    DTSTART;VALUE=DATE:20261022
    DTEND;VALUE=DATE:20261023
    SUMMARY:Museum trip
    STATUS:CANCELLED
    END:VEVENT
    BEGIN:VTODO
    UID:essay-todo@school.example
    DUE;TZID="Eastern Standard Time":20261101T235900
    SUMMARY:English essay
    END:VTODO
    BEGIN:VEVENT
    DTSTART:20261019T160000
    DURATION:PT1H30M
    SUMMARY:Band practice
    END:VEVENT
    END:VCALENDAR
    """#)

    static var school: Data { Data(schoolText.utf8) }

    /// Swim club every Monday and Wednesday at 9:00 Amsterdam (across the DST change), minus one
    /// EXDATE, one occurrence moved and one cancelled by RECURRENCE-ID overrides; a standup every
    /// other day six times; a yearly all-day birthday; a chess club every second Tuesday.
    static let recurringText = crlf(#"""
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:swim@club.example
    DTSTART;TZID=Europe/Amsterdam:20261012T090000
    DTEND;TZID=Europe/Amsterdam:20261012T100000
    RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261028T235959Z
    EXDATE;TZID=Europe/Amsterdam:20261021T090000
    SUMMARY:Swim club
    END:VEVENT
    BEGIN:VEVENT
    UID:swim@club.example
    RECURRENCE-ID;TZID=Europe/Amsterdam:20261026T090000
    DTSTART;TZID=Europe/Amsterdam:20261026T110000
    DTEND;TZID=Europe/Amsterdam:20261026T120000
    SUMMARY:Swim club (moved)
    END:VEVENT
    BEGIN:VEVENT
    UID:swim@club.example
    RECURRENCE-ID;TZID=Europe/Amsterdam:20261028T090000
    DTSTART;TZID=Europe/Amsterdam:20261028T090000
    SUMMARY:Swim club
    STATUS:CANCELLED
    END:VEVENT
    BEGIN:VEVENT
    UID:standup@work.example
    DTSTART:20261010T080000Z
    RRULE:FREQ=DAILY;INTERVAL=2;COUNT=6
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:birthday@home.example
    DTSTART;VALUE=DATE:20201030
    RRULE:FREQ=YEARLY
    SUMMARY:Birthday
    END:VEVENT
    BEGIN:VEVENT
    UID:chess@school.example
    DTSTART:20260908T150000Z
    DTEND:20260908T160000Z
    RRULE:FREQ=MONTHLY;BYDAY=2TU
    SUMMARY:Chess club
    END:VEVENT
    END:VCALENDAR
    """#)

    /// A calendar of the given VEVENT/VTODO blocks.
    static func calendar(_ body: String) -> Data {
        Data(crlf("BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR").utf8)
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlamingoConnectorsTests-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
