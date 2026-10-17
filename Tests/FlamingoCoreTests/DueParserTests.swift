import XCTest
@testable import FlamingoCore

final class DueParserTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = 2
        return c
    }

    private func date(_ stamp: String, _ cal: Calendar) -> Date {
        let parts = stamp.split(whereSeparator: { " :-".contains($0) }).map { Int($0)! }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts.count > 3 ? parts[3] : 0, minute: parts.count > 4 ? parts[4] : 0))!
    }

    /// The due string for `text` written at `stamp` (a Friday: 2026-10-16, unless noted).
    private func due(_ text: String, at stamp: String = "2026-10-16 18:40", zone: String = "America/New_York") -> String? {
        let cal = calendar(zone)
        return DueParser.parse(text, relativeTo: date(stamp, cal), calendar: cal)?.string(calendar: cal)
    }

    func testToday() {
        XCTAssertEqual(due("finish it today"), "2026-10-16")
        XCTAssertEqual(due("call him tonight"), "2026-10-16")
        XCTAssertEqual(due("eod please"), "2026-10-16")
        XCTAssertEqual(due("今天要发出去"), "2026-10-16")
    }

    func testTomorrowIsRelativeToTheThoughtNotToNow() {
        XCTAssertEqual(due("call Tom tomorrow", at: "2026-10-13 09:00"), "2026-10-14")
        XCTAssertEqual(due("call Tom tmr", at: "2026-01-31 23:59"), "2026-02-01")
        XCTAssertEqual(due("明天联系 Tom", at: "2026-10-13 09:00"), "2026-10-14")
        XCTAssertEqual(due("后天交付", at: "2026-10-13 09:00"), "2026-10-15")
        XCTAssertEqual(due("the day after tomorrow", at: "2026-10-13 09:00"), "2026-10-15")
    }

    func testWeekdaysAreTheNextOneStrictlyAfterTheThoughtsDay() {
        // 2026-10-16 is a Friday.
        XCTAssertEqual(due("review before friday"), "2026-10-23", "friday written on a friday")
        XCTAssertEqual(due("ship by fri"), "2026-10-23", "fri written on a friday")
        XCTAssertEqual(due("fri"), "2026-10-23")
        XCTAssertEqual(due("by monday"), "2026-10-19")
        XCTAssertEqual(due("by sat"), "2026-10-17")
        XCTAssertEqual(due("on Sunday"), "2026-10-18")
        XCTAssertEqual(due("friday", at: "2026-10-13 09:00"), "2026-10-16")
        XCTAssertEqual(due("thurs", at: "2026-10-13 09:00"), "2026-10-15")
        XCTAssertEqual(due("周五之前", at: "2026-10-13 09:00"), "2026-10-16")
        XCTAssertEqual(due("星期一开会"), "2026-10-19")
    }

    func testAmbiguousAbbreviationsNeedAPreposition() {
        XCTAssertNil(due("we sat down with Maya"))
        XCTAssertNil(due("the mon key is stuck"))
        XCTAssertNil(due("sun and moon"))
        XCTAssertNil(due("Wed"), "wed alone is a verb as often as a day")
    }

    func testNextWeekAndNextWeekday() {
        XCTAssertEqual(due("next week", at: "2026-10-13 09:00"), "2026-10-19")
        XCTAssertEqual(due("next week"), "2026-10-19")
        XCTAssertEqual(due("下周", at: "2026-10-13 09:00"), "2026-10-19")
        XCTAssertEqual(due("next friday", at: "2026-10-13 09:00"), "2026-10-23", "friday of next week")
        XCTAssertEqual(due("下周三", at: "2026-10-13 09:00"), "2026-10-21")
        XCTAssertEqual(due("这周五", at: "2026-10-13 09:00"), "2026-10-16")
    }

    func testInNDaysAndEndOfWeek() {
        XCTAssertEqual(due("in 3 days"), "2026-10-19")
        XCTAssertEqual(due("in two weeks"), "2026-10-30")
        XCTAssertEqual(due("within a week"), "2026-10-23")
        XCTAssertEqual(due("3天后"), "2026-10-19")
        XCTAssertEqual(due("eow", at: "2026-10-13 09:00"), "2026-10-16")
        XCTAssertEqual(due("by end of week"), "2026-10-16", "on a friday, the end of the week is today")
        XCTAssertEqual(due("eow", at: "2026-10-17 09:00"), "2026-10-23", "on a saturday, the coming friday")
        XCTAssertEqual(due("end of month"), "2026-10-31")
    }

    func testDaylightSavingDays() {
        // US clocks go back on 2026-11-01 (a 25 hour day) and forward on 2026-03-08 (23 hours).
        XCTAssertEqual(due("tomorrow", at: "2026-10-31 20:00"), "2026-11-01")
        XCTAssertEqual(due("in 2 days", at: "2026-10-31 20:00"), "2026-11-02")
        XCTAssertEqual(due("monday", at: "2026-10-31 20:00"), "2026-11-02")
        XCTAssertEqual(due("tomorrow", at: "2026-03-07 23:30"), "2026-03-08")
        XCTAssertEqual(due("in 7 days", at: "2026-03-07 23:30"), "2026-03-14")
        XCTAssertEqual(due("next week", at: "2026-03-07 23:30"), "2026-03-09")
        let cal = calendar()
        let parsed = DueParser.parse("tomorrow", relativeTo: date("2026-11-01 00:30", cal), calendar: cal)
        XCTAssertEqual(parsed?.date, cal.startOfDay(for: date("2026-11-02 12:00", cal)))
        XCTAssertEqual(due("tomorrow", at: "2026-10-31 20:00", zone: "Asia/Shanghai"), "2026-11-01")
    }

    func testAbsoluteDates() {
        XCTAssertEqual(due("PO has to go out by October 20 to make the December 12 last-ship date"), "2026-10-20")
        XCTAssertEqual(due("January 5", at: "2026-12-20 10:00"), "2027-01-05", "a date without a year is the next one")
        XCTAssertEqual(due("Oct 20, 2025"), "2025-10-20")
        XCTAssertEqual(due("20 November"), "2026-11-20")
        XCTAssertEqual(due("due 2026-11-02"), "2026-11-02")
        XCTAssertEqual(due("by 11/2"), "2026-11-02")
        XCTAssertEqual(due("12月3日之前"), "2026-12-03")
        XCTAssertNil(due("Arc at $249 and 3,000 units"))
    }

    func testTimeOfDay() {
        let cal = calendar()
        let p = DueParser.parse("send it tomorrow at 3pm", relativeTo: date("2026-10-13 09:00", cal), calendar: cal)
        XCTAssertEqual(p?.hasTime, true)
        XCTAssertEqual(p?.string(calendar: cal), "2026-10-14 15:00")
        XCTAssertEqual(due("friday 15:30", at: "2026-10-13 09:00"), "2026-10-16 15:30")
        XCTAssertEqual(due("tomorrow 9am", at: "2026-10-13 09:00"), "2026-10-14 09:00")
        XCTAssertEqual(due("tomorrow", at: "2026-10-13 09:00"), "2026-10-14")
        XCTAssertEqual(due("tomorrow [[interview.m4a#time 0:39]]", at: "2026-10-13 09:00"), "2026-10-14", "a link's anchor is not a time of day")
        XCTAssertEqual(due("see page 12 tomorrow", at: "2026-10-13 09:00"), "2026-10-14")
    }

    func testEarliestPhraseWinsAndQuotesAreIgnored() {
        XCTAssertEqual(due("tomorrow, or friday at the latest", at: "2026-10-13 09:00"), "2026-10-14")
        XCTAssertEqual(due("> by monday\nCall Tom", at: "2026-10-13 09:00"), nil)
    }

    func testThoughtDatesRoundTrip() {
        let cal = calendar()
        let d = date("2026-10-23 09:05", cal)
        XCTAssertEqual(ThoughtDates.string(from: d, hasTime: true, calendar: cal), "2026-10-23 09:05")
        XCTAssertEqual(ThoughtDates.parse("2026-10-23", calendar: cal)?.hasTime, false)
        XCTAssertEqual(ThoughtDates.parse("2026-10-23 09:05", calendar: cal)?.date, d)
        XCTAssertNil(ThoughtDates.parse("2026-10-23 25:00", calendar: cal))
        XCTAssertNil(ThoughtDates.parse("soon", calendar: cal))
    }
}
