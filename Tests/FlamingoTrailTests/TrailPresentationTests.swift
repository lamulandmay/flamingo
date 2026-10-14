import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailPresentationTests: XCTestCase {

    private func session(_ events: [TrailEvent]) -> TrailSession {
        TrailClustering.session(from: events, tuning: TrailTuning())
    }

    private func describe(_ stops: [TrailStop]) -> [String] {
        stops.map { stop in
            switch stop.kind {
            case let .file(f, a, notes):
                let n = notes.map(\.text).joined(separator: "|")
                return [f.relativePath, a.map { "\($0.kind.rawValue) \($0.value)" } ?? "", n].joined(separator: " · ")
            case let .search(q):
                return "⌕ " + q
            }
        }
    }

    func testStopsKeepFirstAppearanceOrderAndPutCommentsUnderTheirFile() {
        let slide7 = FileAnchor(kind: .slide, value: "7")
        let s = session([
            ev(.opened, 0, file: "decks/q3.pptx"),
            ev(.opened, 60, file: "decks/q3.pptx", anchor: slide7),
            ev(.opened, 120, file: "finance/model.xlsx"),
            ev(.searched, 180, text: "churn"),
            ev(.commented, 200, file: "decks/q3.pptx", text: "Pricing contradicts [[model.xlsx]]", anchor: slide7),
            ev(.opened, 260, file: "notes/a.md"),
        ])
        XCTAssertEqual(describe(TrailPresentation.stops(for: s)), [
            "decks/q3.pptx · slide 7 · Pricing contradicts [[model.xlsx]]",
            "finance/model.xlsx ·  · ",
            "⌕ churn",
            "notes/a.md ·  · ",
        ])
    }

    func testCommentOnAFileNeverOpenedStillGetsAStop() {
        let s = session([ev(.commented, 0, file: "inbox.md", text: "loose thought")])
        XCTAssertEqual(describe(TrailPresentation.stops(for: s)), ["inbox.md ·  · loose thought"])
    }

    func testLinkedEventEchoingACommentIsHidden() {
        let s = session([
            ev(.opened, 0, file: "deck.pptx"),
            ev(.commented, 10, file: "deck.pptx", text: "see [[q3-model.xlsx]]"),
            ev(.linked, 20, file: "deck.pptx", text: "q3-model.xlsx"),
            ev(.linked, 30, file: "deck.pptx", text: "brief.docx"),
            ev(.linked, 40, file: "deck.pptx", text: "brief.docx"),
            ev(.opened, 50, file: "notes.md"),
            ev(.linked, 60, file: "notes.md", text: "q3-model"),
        ])
        XCTAssertEqual(describe(TrailPresentation.stops(for: s)), [
            "deck.pptx ·  · see [[q3-model.xlsx]]|[[brief.docx]]",
            "notes.md ·  · [[q3-model]]",
        ])
    }

    func testLinkWithoutExtensionMatchesCommentLinkWithExtension() {
        let s = session([
            ev(.commented, 0, file: "a.md", text: "[[q3-model.xlsx#cell B2]] is stale"),
            ev(.linked, 5, file: "a.md", text: "q3-model"),
        ])
        XCTAssertEqual(describe(TrailPresentation.stops(for: s)), ["a.md ·  · [[q3-model.xlsx#cell B2]] is stale"])
    }

    func testSegmentsSplitLinksAndUseAliases() {
        let segs = TrailPresentation.segments("A [[q3.pptx#slide 3]] and [[model.xlsx|the model]].")
        XCTAssertEqual(segs.map(\.text), ["A ", "q3.pptx#slide 3", " and ", "the model", "."])
        XCTAssertEqual(segs.map(\.isLink), [false, true, false, true, false])
        XCTAssertEqual(TrailPresentation.segments("no links").map(\.text), ["no links"])
        XCTAssertEqual(TrailPresentation.segments("[[open").map(\.text), ["[[open"])
    }

    func testTimeRangeFormats() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let locale = Locale(identifier: "en_US")
        func date(_ s: String) -> Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = cal.timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: s)!
        }
        let now = date("2026-10-14 22:00")   // a Wednesday
        XCTAssertEqual(TrailPresentation.timeRange(start: date("2026-10-13 14:05"), end: date("2026-10-13 15:40"),
                                                   now: now, calendar: cal, locale: locale), "Tue 14:05 – 15:40")
        XCTAssertEqual(TrailPresentation.timeRange(start: date("2026-10-14 09:30"), end: date("2026-10-14 09:30"),
                                                   now: now, calendar: cal, locale: locale), "Wed 09:30")
        XCTAssertEqual(TrailPresentation.timeRange(start: date("2026-10-03 23:40"), end: date("2026-10-04 00:15"),
                                                   now: now, calendar: cal, locale: locale), "Oct 3 23:40 – 00:15")
        XCTAssertEqual(TrailPresentation.timeRange(start: date("2025-12-30 10:00"), end: date("2025-12-30 11:00"),
                                                   now: now, calendar: cal, locale: locale), "Dec 30, 2025 10:00 – 11:00")
    }

    func testGutterFitsTheWidestRange() {
        let narrow = TrailMetrics.gutter(for: ["Wed 09:30"])
        let wide = TrailMetrics.gutter(for: ["Wed 09:30", "Dec 30, 2025 10:00 – 11:00"])
        XCTAssertLessThan(narrow, wide)
        XCTAssertEqual(wide, wide.rounded(.up))
    }
}
