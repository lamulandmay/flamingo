import XCTest
@testable import FlamingoConnectors

final class RecurrenceTests: XCTestCase {
    private let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

    private func starts(_ rule: String, _ start: String, zone: TimeZone, from: String, to: String,
                        excluding: [String] = [], cap: Int = Recurrence.cap) throws -> [Date] {
        let rule = try XCTUnwrap(RecurrenceRule(rule))
        let first = try XCTUnwrap(ICalendar.date(start, tzid: nil, isDate: false, local: zone))
        let excluded = excluding.compactMap { ICalendar.date($0, tzid: nil, isDate: false, local: zone) }
        return Recurrence.occurrences(of: rule, start: first, from: Fixtures.utc(from), to: Fixtures.utc(to),
                                      excluding: excluded, cap: cap)
    }

    func testRuleParsing() throws {
        XCTAssertNil(RecurrenceRule("FREQ=MONTHLY;BYSETPOS=1;BYDAY=MO"), "would move the dates")
        XCTAssertNil(RecurrenceRule("FREQ=HOURLY"))
        XCTAssertNil(RecurrenceRule("FREQ=WEEKLY;BYMONTHDAY=1"))
        XCTAssertNil(RecurrenceRule("FREQ=WEEKLY;INTERVAL=0"))
        XCTAssertNil(RecurrenceRule("FREQ=DAILY;BYDAY=XX"))
        XCTAssertNil(RecurrenceRule("INTERVAL=2"))
        let weekly = try XCTUnwrap(RecurrenceRule("freq=weekly;byday=mo,2we;wkst=su;count=4"))
        XCTAssertEqual(weekly.byDay, [.init(ordinal: 0, weekday: 2), .init(ordinal: 0, weekday: 4)], "ordinals are monthly only")
        XCTAssertEqual(weekly.weekStart, 1)
        XCTAssertEqual(weekly.count, 4)
        XCTAssertEqual(RecurrenceRule("FREQ=MONTHLY;BYDAY=-1FR")?.byDay, [.init(ordinal: -1, weekday: 6)])
    }

    func testWallClockKeptAcrossDST() throws {
        let list = try starts("FREQ=WEEKLY;BYDAY=MO", "20261012T090000", zone: amsterdam,
                              from: "2026-10-17T00:00:00Z", to: "2026-11-05T00:00:00Z")
        XCTAssertEqual(list, ["2026-10-19T07:00:00Z", "2026-10-26T08:00:00Z", "2026-11-02T08:00:00Z"].map(Fixtures.utc))
    }

    func testCountIncludesExcludedDates() throws {
        let list = try starts("FREQ=DAILY;COUNT=3", "20261018T080000Z", zone: Fixtures.utcZone,
                              from: "2026-10-01T00:00:00Z", to: "2026-11-01T00:00:00Z", excluding: ["20261019T080000Z"])
        XCTAssertEqual(list, ["2026-10-18T08:00:00Z", "2026-10-20T08:00:00Z"].map(Fixtures.utc))
    }

    func testDateOnlyUntilIncludesThatDay() throws {
        let list = try starts("FREQ=DAILY;UNTIL=20261020", "20261018T080000Z", zone: Fixtures.utcZone,
                              from: "2026-10-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.last, Fixtures.utc("2026-10-20T08:00:00Z"))
    }

    func testMonthlyLastFridayAndMissingDays() throws {
        let fridays = try starts("FREQ=MONTHLY;BYDAY=-1FR", "20261030T100000Z", zone: Fixtures.utcZone,
                                 from: "2026-10-17T00:00:00Z", to: "2027-01-01T00:00:00Z")
        XCTAssertEqual(fridays, ["2026-10-30T10:00:00Z", "2026-11-27T10:00:00Z", "2026-12-25T10:00:00Z"].map(Fixtures.utc))
        let thirtyFirsts = try starts("FREQ=MONTHLY", "20261031T100000Z", zone: Fixtures.utcZone,
                                      from: "2026-10-17T00:00:00Z", to: "2027-01-01T00:00:00Z")
        XCTAssertEqual(thirtyFirsts, ["2026-10-31T10:00:00Z", "2026-12-31T10:00:00Z"].map(Fixtures.utc), "November has no 31st")
    }

    func testCapAndFarFuturePeriodsStayCheap() throws {
        XCTAssertEqual(try starts("FREQ=DAILY", "20261017T080000Z", zone: Fixtures.utcZone,
                                  from: "2026-10-17T00:00:00Z", to: "2028-10-17T00:00:00Z", cap: 10).count, 10)
        let yearly = try starts("FREQ=YEARLY", "19500101T120000Z", zone: Fixtures.utcZone,
                                from: "2026-10-17T00:00:00Z", to: "2027-12-31T00:00:00Z")
        XCTAssertEqual(yearly, [Fixtures.utc("2027-01-01T12:00:00Z")], "the 1950 start itself is before the window")
    }

    func testRecurringFeed() throws {
        let list = try ICalAdapter.items(from: Data(Fixtures.recurringText.utf8), card: Fixtures.card("club", role: .schedule),
                                         now: Fixtures.now, timeZone: Fixtures.newYork)
        XCTAssertEqual(list.map(\.title), ["Standup", "Swim club", "Standup", "Swim club (moved)", "Birthday", "Chess club", "Chess club"],
                       "EXDATE and the cancelled override are gone; COUNT ends the standups")
        XCTAssertEqual(list.map(\.start), ["2026-10-18T08:00:00Z", "2026-10-19T07:00:00Z", "2026-10-20T08:00:00Z",
                                           "2026-10-26T10:00:00Z", "2026-10-30T04:00:00Z", "2026-11-10T15:00:00Z",
                                           "2026-12-08T15:00:00Z"].map(Fixtures.utc))
        XCTAssertTrue(list.allSatisfy { $0.kind == .event })
        XCTAssertEqual(list[1].end, Fixtures.utc("2026-10-19T08:00:00Z"))
        XCTAssertEqual(list[3].id, "swim@club.example@\(Fixtures.epoch("2026-10-26T08:00:00Z"))", "an override keeps its original slot's id")
        XCTAssertEqual(list[0].id, "standup@work.example@\(Fixtures.epoch("2026-10-18T08:00:00Z"))")
        XCTAssertTrue(list[4].allDay)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
    }

    func testUnsupportedRuleKeepsTheFirstDate() throws {
        let data = Fixtures.calendar("""
        BEGIN:VEVENT
        UID:odd@x.example
        DTSTART:20261019T150000Z
        RRULE:FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO,TU,WE,TH,FR
        SUMMARY:Odd rule
        END:VEVENT
        """)
        let list = try ICalAdapter.items(from: data, card: Fixtures.card(role: .schedule), now: Fixtures.now, timeZone: Fixtures.newYork)
        XCTAssertEqual(list.map(\.start), [Fixtures.utc("2026-10-19T15:00:00Z")])
    }
}
