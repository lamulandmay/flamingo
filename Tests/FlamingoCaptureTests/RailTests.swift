import XCTest
@testable import FlamingoCapture
import FlamingoCore

final class RailTextTests: XCTestCase {
    private func seg(_ text: String, _ target: String? = nil) -> RailSegment { RailSegment(text: text, target: target) }

    func testPlainTextIsOneSegment() {
        XCTAssertEqual(RailText.segments("Needs a better title"), [seg("Needs a better title")])
        XCTAssertEqual(RailText.segments(""), [])
    }

    func testLinkDropsBrackets() {
        XCTAssertEqual(RailText.segments("Pricing contradicts [[q3-model.xlsx]]"),
                       [seg("Pricing contradicts "), seg("q3-model.xlsx", "q3-model.xlsx")])
    }

    func testAliasIsShownTargetIsKept() {
        XCTAssertEqual(RailText.segments("see [[decks/q3.pptx|the deck]] now"),
                       [seg("see "), seg("the deck", "decks/q3.pptx"), seg(" now")])
    }

    func testAnchorStaysOnTarget() {
        XCTAssertEqual(RailText.segments("[[q3.pptx#slide 2]]"), [seg("q3.pptx#slide 2", "q3.pptx#slide 2")])
        XCTAssertEqual(RailText.segments("[[q3.pptx#slide 2|pricing]]"), [seg("pricing", "q3.pptx#slide 2")])
    }

    func testEmptyAliasFallsBackToTarget() {
        XCTAssertEqual(RailText.segments("[[a.md|]]"), [seg("a.md", "a.md")])
    }

    func testMultipleLinks() {
        XCTAssertEqual(RailText.segments("[[a]] and [[b]]"), [seg("a", "a"), seg(" and "), seg("b", "b")])
    }

    func testUnclosedAndEmptyLinksStayLiteral() {
        XCTAssertEqual(RailText.segments("see [[q3"), [seg("see [[q3")])
        XCTAssertEqual(RailText.segments("[[]] x"), [seg("[[]] x")])
        XCTAssertEqual(RailText.segments("[[  |alias]]"), [seg("[[  |alias]]")])
    }

    func testLinksDoNotSpanLines() {
        XCTAssertEqual(RailText.segments("[[a\nb]]"), [seg("[[a\nb]]")])
    }

    func testNestedOpenerIsLiteral() {
        XCTAssertEqual(RailText.segments("[[a [[b]]"), [seg("[[a "), seg("b", "b")])
    }

    func testMultiLineTextKeepsNewlines() {
        XCTAssertEqual(RailText.segments("one\n  two [[x]]"), [seg("one\n  two "), seg("x", "x")])
    }

    func testLinkURLRoundTrips() {
        for target in ["q3.pptx", "decks/q3 final.pptx#slide 2", "a&b=c?.md", "Café/naïve.key", "100%.txt"] {
            let url = RailText.linkURL(for: target)
            XCTAssertNotNil(url, target)
            XCTAssertEqual(url.flatMap(RailText.linkTarget(from:)), target)
        }
        XCTAssertNil(RailText.linkTarget(from: URL(string: "https://example.com")!))
    }

    func testAttributedStringLinksOnlyWikilinks() {
        let a = RailText.attributed("see [[q3.pptx|deck]] ok")
        XCTAssertEqual(String(a.characters), "see deck ok")
        let links = a.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(RailText.linkTarget(from: links[0]), "q3.pptx")
    }

    func testAnchorLabel() {
        XCTAssertEqual(RailText.anchorLabel(FileAnchor(kind: .slide, value: "7")), "slide 7")
        XCTAssertEqual(RailText.anchorLabel(FileAnchor(kind: .cell, value: "Q3!B12")), "cell Q3!B12")
    }

    func testTimestamps() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2026, 10, 14, 23, 30)
        XCTAssertEqual(RailText.timestamp(date(2026, 10, 14, 22, 5), now: now, calendar: cal, locale: locale), "22:05")
        XCTAssertEqual(RailText.timestamp(date(2026, 10, 14, 0, 0), now: now, calendar: cal, locale: locale), "00:00")
        XCTAssertEqual(RailText.timestamp(date(2026, 10, 12), now: now, calendar: cal, locale: locale), "Oct 12")
        XCTAssertEqual(RailText.timestamp(date(2026, 1, 3), now: now, calendar: cal, locale: locale), "Jan 3")
        XCTAssertEqual(RailText.timestamp(date(2025, 10, 12), now: now, calendar: cal, locale: locale), "Oct 12, 2025")
    }
}
