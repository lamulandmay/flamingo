import XCTest
@testable import FlamingoConnectors

final class ICalAdapterTests: XCTestCase {
    private func items(_ data: Data = Fixtures.school, card: PurposeCard = Fixtures.card()) throws -> [ConnectorItem] {
        try ICalAdapter.items(from: data, card: card, now: Fixtures.now, timeZone: Fixtures.newYork)
    }

    func testDeadlinesFeed() throws {
        let list = try items()
        XCTAssertEqual(list.map(\.title), ["Band practice", "History essay, draft 2: the long road", "Maths exam", "English essay"],
                       "soonest first; the cancelled trip is gone")
        XCTAssertTrue(list.allSatisfy { $0.kind == .deadline && $0.connector == "school" })
        let band = list[0], history = list[1], exam = list[2], essay = list[3]
        XCTAssertTrue(band.id.hasPrefix("h-"))
        XCTAssertEqual(band.due, Fixtures.utc("2026-10-19T20:00:00Z"))
        XCTAssertEqual(history.id, "assign-1@school.example")
        XCTAssertEqual(history.due, Fixtures.utc("2026-10-20T22:00:00Z"))
        XCTAssertEqual(history.categories, ["History", "Essay,Draft"])
        XCTAssertEqual(history.link, "https://school.example/tasks/1")
        XCTAssertEqual(history.summary, "Upload to the portal.\nTwo pages.")
        XCTAssertEqual(exam.due, Fixtures.utc("2026-10-27T08:00:00Z"), "an event is due at its start")
        XCTAssertEqual(exam.end, Fixtures.utc("2026-10-27T09:30:00Z"))
        XCTAssertEqual(essay.id, "essay-todo@school.example")
        XCTAssertEqual(essay.due, Fixtures.utc("2026-11-02T04:59:00Z"))
        XCTAssertNil(essay.start)
        XCTAssertEqual(essay.fetchedAt, Fixtures.now)
    }

    func testScheduleFeed() throws {
        let list = try items(card: Fixtures.card(role: .schedule))
        let byTitle = Dictionary(uniqueKeysWithValues: list.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Maths exam"]?.kind, .event)
        XCTAssertNil(byTitle["Maths exam"]?.due)
        XCTAssertEqual(byTitle["Maths exam"]?.start, Fixtures.utc("2026-10-27T08:00:00Z"))
        XCTAssertEqual(byTitle["English essay"]?.kind, .deadline, "a to-do stays a deadline")
        XCTAssertEqual(byTitle["Band practice"]?.end, Fixtures.utc("2026-10-19T21:30:00Z"), "DURATION gives the end")
        XCTAssertNil(byTitle["History essay, draft 2: the long road"]?.end, "a timed event without an end has none")
    }

    func testIncludeAndExclude() throws {
        let list = try items(card: Fixtures.card(include: ["exam", "essay"], exclude: ["english"]))
        XCTAssertEqual(list.map(\.title), ["History essay, draft 2: the long road", "Maths exam"])
        let byCategory = try items(card: Fixtures.card(include: ["essay, draft"]))
        XCTAssertEqual(byCategory.map(\.title), ["History essay, draft 2: the long road"], "categories match too")
    }

    func testWindowEdges() throws {
        // Window: 2026-10-18 00:00 to 2026-10-20 00:00 New York = 04:00Z to 04:00Z.
        let data = Fixtures.calendar("""
        BEGIN:VTODO
        UID:at-lower
        DUE:20261018T040000Z
        SUMMARY:At the lower edge
        END:VTODO
        BEGIN:VTODO
        UID:at-upper
        DUE:20261020T040000Z
        SUMMARY:At the upper edge
        END:VTODO
        BEGIN:VEVENT
        UID:overlaps
        DTSTART:20261017T230000Z
        DTEND:20261018T050000Z
        SUMMARY:Overlaps the start
        END:VEVENT
        BEGIN:VEVENT
        UID:ends-at-lower
        DTSTART:20261018T030000Z
        DTEND:20261018T040000Z
        SUMMARY:Ends as it opens
        END:VEVENT
        BEGIN:VEVENT
        UID:last-second
        DTSTART:20261020T035959Z
        SUMMARY:Last second
        END:VEVENT
        """)
        let card = Fixtures.card(role: .schedule, window: ConnectorWindow(daysBack: 0, daysAhead: 1))
        XCTAssertEqual(Set(try items(data, card: card).map(\.id)), ["at-lower", "overlaps", "last-second"])
    }

    func testDropsOldUndatedCancelledAndUntitled() throws {
        let data = Fixtures.calendar("""
        BEGIN:VEVENT
        UID:old
        DTSTART:20260901T100000Z
        SUMMARY:Old
        END:VEVENT
        BEGIN:VEVENT
        UID:no-date
        SUMMARY:No date
        END:VEVENT
        BEGIN:VTODO
        UID:someday
        SUMMARY:Someday
        END:VTODO
        BEGIN:VTODO
        UID:done
        DUE:20261020T100000Z
        STATUS:COMPLETED
        SUMMARY:Done
        END:VTODO
        BEGIN:VEVENT
        UID:untitled
        DTSTART:20261020T100000Z
        SUMMARY:
        END:VEVENT
        BEGIN:VEVENT
        UID:soon
        DTSTART:20261020T100000Z
        SUMMARY:Soon
        END:VEVENT
        """)
        let list = try items(data, card: Fixtures.card(role: .schedule))
        XCTAssertEqual(list.map(\.id), ["soon", "someday"], "an undated to-do stays, last")
    }

    func testRepeatedUIDsAreStableWhateverTheOrder() throws {
        let body = """
        BEGIN:VEVENT
        UID:dup@x
        DTSTART:20261019T100000Z
        SUMMARY:Lesson
        END:VEVENT
        BEGIN:VEVENT
        UID:dup@x
        DTSTART:20261021T100000Z
        SUMMARY:Lesson
        END:VEVENT
        BEGIN:VEVENT
        UID:dup@x
        DTSTART:20261019T100000Z
        SUMMARY:Lesson
        END:VEVENT
        """
        let cal = try ICalendar(parsing: Fixtures.crlf("BEGIN:VCALENDAR\n" + body + "\nEND:VCALENDAR"))
        let card = Fixtures.card(role: .schedule)
        let forward = ICalAdapter.items(from: cal, card: card, now: Fixtures.now, timeZone: Fixtures.newYork)
        let backward = ICalAdapter.items(from: ICalendar(components: cal.components.reversed()), card: card,
                                         now: Fixtures.now, timeZone: Fixtures.newYork)
        let first = Fixtures.epoch("2026-10-19T10:00:00Z"), second = Fixtures.epoch("2026-10-21T10:00:00Z")
        XCTAssertEqual(Set(forward.map(\.id)), ["dup@x@\(first)", "dup@x@\(first)#2", "dup@x@\(second)"])
        XCTAssertEqual(Set(backward.map(\.id)), Set(forward.map(\.id)))
    }

    func testStableHashWithoutUID() throws {
        let a = try items().first { $0.title == "Band practice" }
        let b = try items().first { $0.title == "Band practice" }
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertEqual(a?.id.count, 18)
        XCTAssertEqual(ICalAdapter.stableHash("Band practice|1792440000"), ICalAdapter.stableHash("Band practice|1792440000"))
        XCTAssertNotEqual(ICalAdapter.stableHash("Band practice|1792440000"), ICalAdapter.stableHash("Band practice|1792440001"))
    }

    func testFeedURLs() {
        XCTAssertEqual(ICalAdapter.feedURL("webcal://school.example/f.ics?t=1")?.absoluteString, "https://school.example/f.ics?t=1")
        XCTAssertEqual(ICalAdapter.feedURL("WEBCALS://school.example/f.ics")?.absoluteString, "https://school.example/f.ics")
        XCTAssertEqual(ICalAdapter.feedURL("  http://school.example/f.ics \n")?.absoluteString, "http://school.example/f.ics")
        for bad in ["ftp://school.example/f.ics", "not a url", "https://", "file:///etc/passwd", "school.example/f.ics", ""] {
            XCTAssertNil(ICalAdapter.feedURL(bad), bad)
        }
    }

    func testLatin1Feed() throws {
        var data = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:c\r\nDTSTART:20261020T100000Z\r\nSUMMARY:Caf".utf8)
        data.append(0xE9)
        data.append(Data("\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8))
        XCTAssertEqual(try items(data, card: Fixtures.card(role: .schedule)).first?.title, "Café")
    }
}
