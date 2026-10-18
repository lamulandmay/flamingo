import XCTest
@testable import FlamingoConnectors

final class PurposeCardTests: XCTestCase {
    private func keeps(include: [String] = [], exclude: [String] = [], _ title: String, _ categories: [String] = []) -> Bool {
        Fixtures.card(include: include, exclude: exclude).keeps(title: title, categories: categories)
    }

    func testWholeWordsNotSubstrings() {
        XCTAssertTrue(keeps(include: ["exam"], "Maths Exams"))
        XCTAssertTrue(keeps(include: ["exam"], "Exam-prep session"))
        XCTAssertFalse(keeps(include: ["exam"], "Example essay"))
        XCTAssertFalse(keeps(include: ["art"], "Start of term"))
        XCTAssertTrue(keeps(include: ["art"], "Art history"))
        XCTAssertTrue(keeps(include: ["class"], "Classes resume"), "a plural -es")
        XCTAssertFalse(keeps(include: ["class"], "Classroom move"))
    }

    func testPhrasesCaseAndAccents() {
        XCTAssertTrue(keeps(include: ["maths exam"], "MATHS EXAM, room 4"))
        XCTAssertFalse(keeps(include: ["maths exam"], "Exam: maths"), "the words in a row")
        XCTAssertTrue(keeps(include: ["ecole"], "École trip"))
        XCTAssertTrue(keeps(include: ["école"], "Ecole trip"))
    }

    func testExcludeWinsAndCategoriesCount() {
        XCTAssertFalse(keeps(include: ["exam"], exclude: ["mock"], "Mock exam"))
        XCTAssertTrue(keeps(include: ["exam"], exclude: ["mock"], "Final exam"))
        XCTAssertTrue(keeps(include: ["history"], "Essay", ["History", "Year 10"]))
        XCTAssertFalse(keeps(exclude: ["sport"], "Match", ["Sports"]))
        XCTAssertTrue(keeps(exclude: ["sport"], "Match", ["Transport"]))
    }

    func testBlankTermsAreIgnored() {
        XCTAssertTrue(keeps(include: ["  ", "!!"], "Anything"), "an include list of nothing filters nothing")
        XCTAssertTrue(keeps(exclude: ["—"], "Anything"))
        XCTAssertFalse(keeps(include: ["exam"], ""))
    }

    func testSlug() {
        XCTAssertEqual(PurposeCard.slug("École Calendar!"), "ecole-calendar")
        XCTAssertEqual(PurposeCard.slug("  --Year 10 / Maths--  "), "year-10-maths")
        XCTAssertEqual(PurposeCard.slug("日本語"), "connector")
        XCTAssertEqual(PurposeCard.slug(""), "connector")
        let cut = PurposeCard.slug(String(repeating: "a", count: 47) + " bcd")
        XCTAssertEqual(cut, String(repeating: "a", count: 47), "no trailing dash after the cut")
        XCTAssertTrue(ConnectorStore.isValidID(cut))
    }

    func testClamped() {
        var card = Fixtures.card(refreshMinutes: 100_000)
        card.window = ConnectorWindow(daysBack: 400, daysAhead: 0)
        card.weight = 7
        card.exclude = (1...30).map { "word\($0)" }
        let c = card.clamped()
        XCTAssertEqual(c.refreshMinutes, 1_440)
        XCTAssertEqual(c.window, ConnectorWindow(daysBack: 30, daysAhead: 1))
        XCTAssertEqual(c.weight, 2)
        XCTAssertEqual(c.exclude.count, 20)
    }

    func testDecodingIsForgiving() throws {
        let json = #"{"id":"x","name":"X","adapter":"ical","role":"party","refreshMinutes":1e300,"weight":"heavy","enabled":"yes","window":{"daysAhead":14}}"#
        let card = try JSONDecoder().decode(PurposeCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.role, .reference)
        XCTAssertEqual(card.clamped().refreshMinutes, 1_440)
        XCTAssertEqual(card.weight, 1)
        XCTAssertTrue(card.enabled)
        XCTAssertEqual(card.window, ConnectorWindow(daysBack: 1, daysAhead: 14))
        XCTAssertThrowsError(try JSONDecoder().decode(PurposeCard.self, from: Data(#"{"id":"x","name":"X","adapter":"fax"}"#.utf8)))
    }

    func testWindowIsWholeLocalDays() {
        let range = ConnectorWindow(daysBack: 1, daysAhead: 60).range(now: Fixtures.now, timeZone: Fixtures.newYork)
        XCTAssertEqual(range.lowerBound, Fixtures.utc("2026-10-17T04:00:00Z"))
        XCTAssertEqual(range.upperBound, Fixtures.utc("2026-12-18T05:00:00Z"), "past the US clock change")
    }

    func testItemFallsInWindow() {
        let range = Fixtures.utc("2026-10-17T04:00:00Z")..<Fixtures.utc("2026-10-20T04:00:00Z")
        func event(_ start: String, _ end: String?) -> ConnectorItem {
            ConnectorItem(id: "e", connector: "c", kind: .event, title: "E", start: Fixtures.utc(start),
                          end: end.map(Fixtures.utc), fetchedAt: Fixtures.now)
        }
        XCTAssertTrue(event("2026-10-16T22:00:00Z", "2026-10-17T06:00:00Z").falls(in: range), "overlaps the start")
        XCTAssertFalse(event("2026-10-16T22:00:00Z", "2026-10-17T04:00:00Z").falls(in: range), "ends as it opens")
        XCTAssertFalse(event("2026-10-20T04:00:00Z", nil).falls(in: range))
        XCTAssertFalse(ConnectorItem(id: "e", connector: "c", kind: .event, title: "E", fetchedAt: Fixtures.now).falls(in: range))
        XCTAssertTrue(ConnectorItem(id: "d", connector: "c", kind: .deadline, title: "D", fetchedAt: Fixtures.now).falls(in: range),
                      "an undated deadline stays")
    }
}
