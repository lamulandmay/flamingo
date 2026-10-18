import XCTest
@testable import FlamingoConnectors

final class ICalendarTests: XCTestCase {
    private let ny = Fixtures.newYork

    func testComponentsSkipAlarmsAndTimeZones() throws {
        let cal = try ICalendar(parsing: Fixtures.schoolText)
        XCTAssertEqual(cal.components.map(\.kind), [.event, .event, .event, .todo, .event])
        let all = cal.components.flatMap(\.properties)
        XCTAssertFalse(all.contains { $0.value == "Alarm inside" }, "an alarm's properties are not the event's")
        XCTAssertFalse(all.contains { $0.name == "ACTION" || $0.name == "TZOFFSETFROM" })
        XCTAssertEqual(cal.components[0].text("SUMMARY"), "History essay, draft 2: the long road")
        XCTAssertEqual(cal.components[0].text("DESCRIPTION"), "Upload to the portal.\nTwo pages.")
    }

    func testPropertiesAndParameters() throws {
        let p = try XCTUnwrap(ICalendar.property(#"dtstart;TZID="Europe/Amsterdam";X-NOTE="a;b:c":20261027T090000"#))
        XCTAssertEqual(p.name, "DTSTART")
        XCTAssertEqual(p.params["TZID"], "Europe/Amsterdam")
        XCTAssertEqual(p.params["X-NOTE"], "a;b:c")
        XCTAssertEqual(p.value, "20261027T090000")
        XCTAssertEqual(ICalendar.property("URL:https://x.example/a?b=c:d")?.value, "https://x.example/a?b=c:d")
        XCTAssertNil(ICalendar.property("no colon here"))
        XCTAssertNil(ICalendar.property(":value"))
    }

    func testEscapedCommasInLists() {
        XCTAssertEqual(ICalendar.list(#"History,Essay\,Draft"#), ["History", "Essay,Draft"])
        XCTAssertEqual(ICalendar.list(" a , ,b "), ["a", "b"])
        XCTAssertEqual(ICalendar.list(""), [])
    }

    func testDateKinds() throws {
        func date(_ line: String) throws -> ICalDate {
            try XCTUnwrap(ICalendar.date(try XCTUnwrap(ICalendar.property(line)), local: ny), line)
        }
        let allDay = try date("DTSTART;VALUE=DATE:20261022")
        XCTAssertTrue(allDay.allDay)
        XCTAssertEqual(allDay.date, Fixtures.utc("2026-10-22T04:00:00Z"), "midnight in the local zone")
        XCTAssertTrue(try date("DTSTART:20261022").allDay, "8 digits alone is a date")
        let utc = try date("DTSTART:20261020T220000Z")
        XCTAssertEqual(utc.date, Fixtures.utc("2026-10-20T22:00:00Z"))
        XCTAssertFalse(utc.allDay)
        XCTAssertEqual(utc.timeZone.secondsFromGMT(), 0)
        let amsterdam = try date("DTSTART;TZID=Europe/Amsterdam:20261027T090000")
        XCTAssertEqual(amsterdam.date, Fixtures.utc("2026-10-27T08:00:00Z"), "CET after 25 October")
        XCTAssertEqual(amsterdam.timeZone.identifier, "Europe/Amsterdam")
        XCTAssertEqual(try date("DTSTART:20261019T160000").date, Fixtures.utc("2026-10-19T20:00:00Z"), "floating is local")
        XCTAssertEqual(try date("DTSTART;TZID=Mars/Base:20261019T160000").date, Fixtures.utc("2026-10-19T20:00:00Z"),
                       "an unknown zone reads as local")
        XCTAssertEqual(try date(#"DUE;TZID="Eastern Standard Time":20261101T235900"#).date, Fixtures.utc("2026-11-02T04:59:00Z"),
                       "EST after 1 November")
        let exdates = ICalendar.dates(try XCTUnwrap(ICalendar.property("EXDATE:20261020T080000Z,20261022T080000Z")), local: ny)
        XCTAssertEqual(exdates.map(\.date), [Fixtures.utc("2026-10-20T08:00:00Z"), Fixtures.utc("2026-10-22T08:00:00Z")])
    }

    func testLineEndingsAndFolding() throws {
        let lf = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:1\nSUMMARY:Long\n\ttitle\nEND:VEVENT\nEND:VCALENDAR\n"
        for text in [lf, lf.replacingOccurrences(of: "\n", with: "\r\n"), lf.replacingOccurrences(of: "\n", with: "\r"),
                     "\u{FEFF}" + lf] {
            let cal = try ICalendar(parsing: text)
            XCTAssertEqual(cal.components.count, 1)
            XCTAssertEqual(cal.components.first?.text("SUMMARY"), "Longtitle", "the fold's one whitespace is dropped")
        }
    }

    func testLoginPageIsNotACalendar() {
        for text in ["<!doctype html><html><body>Sign in to ManageBac</body></html>", "", "BEGIN:VEVENT\nEND:VEVENT"] {
            XCTAssertThrowsError(try ICalendar(parsing: text)) { XCTAssertEqual($0 as? ConnectorError, .notCalendar) }
        }
    }

    func testUnescape() {
        XCTAssertEqual(ICalendar.unescape(#"a\nb\,c\;d\\e\Nf\:g"#), "a\nb,c;d\\e\nf:g")
        XCTAssertEqual(ICalendar.unescape(#"odd\q end\"#), #"odd\q end\"#)
    }

    func testBadDatesAreRejected() {
        for value in ["20261340", "20260230", "2026101", "20261020T250000Z", "20261020T2200", "2026-10-20", "20261020X220000",
                      "20261020T220000+0100"] {
            XCTAssertNil(ICalendar.date(ICalendar.Property(name: "DTSTART", value: value), local: ny), value)
        }
        XCTAssertNotNil(ICalendar.date(ICalendar.Property(name: "DTSTART", value: "20280229"), local: ny), "a leap day")
    }

    func testZoneNames() {
        XCTAssertEqual(ICalendar.zone(named: "Eastern Standard Time")?.identifier, "America/New_York")
        XCTAssertEqual(ICalendar.zone(named: "W. Europe Standard Time")?.identifier, "Europe/Berlin")
        XCTAssertEqual(ICalendar.zone(named: "/mozilla.org/20050126_1/Europe/Amsterdam")?.identifier, "Europe/Amsterdam")
        XCTAssertEqual(ICalendar.zone(named: "\"Asia/Tokyo\"")?.identifier, "Asia/Tokyo")
        XCTAssertNil(ICalendar.zone(named: "Nowhere/Land"))
        XCTAssertNil(ICalendar.zone(named: ""))
    }

    func testWindowsTableCoversOutlookAndResolves() {
        XCTAssertGreaterThanOrEqual(ICalendar.windowsZones.count, 50)
        for (windows, iana) in ICalendar.windowsZones {
            XCTAssertNotNil(TimeZone(identifier: iana), "\(windows) → \(iana)")
        }
        for name in ["GMT Standard Time", "Romance Standard Time", "India Standard Time", "China Standard Time",
                     "AUS Eastern Standard Time", "Pacific Standard Time", "Central Standard Time", "Singapore Standard Time"] {
            XCTAssertNotNil(ICalendar.zone(named: name), name)
        }
    }

    func testDurations() {
        XCTAssertEqual(ICalendar.duration("PT1H30M"), ICalDuration(days: 0, seconds: 5_400))
        XCTAssertEqual(ICalendar.duration("P1D"), ICalDuration(days: 1, seconds: 0))
        XCTAssertEqual(ICalendar.duration("P2W"), ICalDuration(days: 14, seconds: 0))
        XCTAssertEqual(ICalendar.duration("-PT15M"), ICalDuration(days: 0, seconds: -900))
        XCTAssertEqual(ICalendar.duration("P1DT12H"), ICalDuration(days: 1, seconds: 43_200))
        for bad in ["P", "PT", "1H", "P1H", "PT1D", "P1.5D", ""] { XCTAssertNil(ICalendar.duration(bad), bad) }
        // Calendar days keep the wall clock across the DST change.
        let start = Fixtures.utc("2026-10-24T07:00:00Z")   // 9:00 in Amsterdam, summer time
        let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
        XCTAssertEqual(ICalDuration(days: 2, seconds: 0).added(to: start, in: amsterdam), Fixtures.utc("2026-10-26T08:00:00Z"))
    }
}
