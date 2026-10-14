import XCTest
import AppKit
import FlamingoCore
@testable import FlamingoAsk

final class MarkdownLiteTests: XCTestCase {
    private let deck = Citation(file: FileRef(relativePath: "decks/q3.pptx"), anchor: FileAnchor(kind: .slide, value: "7"))
    private var sources: [Int: Citation] { [2: deck, 3: deck, 5: deck] }

    private func render(_ md: String, streaming: Bool = false) -> NSAttributedString {
        MarkdownLite.render(md, sources: sources, streaming: streaming)
    }

    private func citations(_ s: NSAttributedString) -> [(number: Int, text: String, link: URL?)] {
        var runs: [(Int, String, URL?)] = []
        s.enumerateAttribute(.flamingoCitation, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let n = value as? Int else { return }
            runs.append((n, (s.string as NSString).substring(with: range), s.attribute(.link, at: range.location, effectiveRange: nil) as? URL))
        }
        return runs
    }

    private func hasLink(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, _, _ in if v != nil { found = true } }
        return found
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of needle: String, in s: NSAttributedString) -> T? {
        let r = (s.string as NSString).range(of: needle)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(key, at: r.location, effectiveRange: nil) as? T
    }

    func testKnownCitationIsLink() {
        let s = render("Price is $40 [3].")
        XCTAssertEqual(s.string, "Price is $40 [3].")
        let runs = citations(s)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.number, 3)
        XCTAssertEqual(runs.first?.text, "[3]")
        XCTAssertEqual(runs.first?.link, URL(string: "flamingo-cite:3"))
    }

    func testUnknownCitationIsPlainTertiary() {
        let s = render("See [9].")
        XCTAssertEqual(s.string, "See [9].")
        XCTAssertTrue(citations(s).isEmpty)
        XCTAssertFalse(hasLink(s))
        XCTAssertEqual(attribute(.foregroundColor, of: "[9]", in: s), NSColor.tertiaryLabelColor)
    }

    func testGroupsYieldOneRunPerNumber() {
        for md in ["x [2, 5] y", "x [2,5] y", "x [2][5] y"] {
            let s = render(md)
            XCTAssertEqual(citations(s).map(\.number), [2, 5], md)
            XCTAssertTrue(citations(s).allSatisfy { $0.link != nil }, md)
        }
        let mixed = render("[2, 9]")
        XCTAssertEqual(citations(mixed).map(\.number), [2])
    }

    func testMarkdownLinksAndWikilinksAreNotCitations() {
        let s = render("[text](http://x) and [[q3-model.xlsx]] and [3](y) and [[3]]")
        XCTAssertTrue(citations(s).isEmpty)
        XCTAssertTrue(s.string.contains("[[q3-model.xlsx]]"))
        XCTAssertTrue(s.string.contains("[3](y)"))
    }

    func testBoldItalicAndCode() {
        let s = render("a **bold** and *soft* and `q3!B12`")
        XCTAssertEqual(s.string, "a bold and soft and q3!B12")
        XCTAssertEqual(attribute(.font, of: "bold", in: s), NSFont.systemFont(ofSize: 13, weight: .semibold))
        let italic: NSFont? = attribute(.font, of: "soft", in: s)
        XCTAssertTrue(italic?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        let code: NSFont? = attribute(.font, of: "q3!B12", in: s)
        XCTAssertEqual(code, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertEqual(attribute(.font, of: "a ", in: s), NSFont.systemFont(ofSize: 13))
    }

    func testUnderscoresInsideWordsStayLiteral() {
        XCTAssertEqual(render("use snake_case_name here").string, "use snake_case_name here")
        let s = render("_this_ matters")
        XCTAssertEqual(s.string, "this matters")
        let f: NSFont? = attribute(.font, of: "this", in: s)
        XCTAssertTrue(f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertEqual(render("2 * 3 * 4").string, "2 * 3 * 4")
    }

    func testUnclosedMarkersAreLiteralWhenDone() {
        XCTAssertEqual(render("Price **forty").string, "Price **forty")
        XCTAssertEqual(render("tick ` mark").string, "tick ` mark")
    }

    func testBullets() {
        let s = render("Intro\n- one [2]\n- two\n\nAfter")
        XCTAssertEqual(s.string, "Intro\n•\tone [2]\n•\ttwo\nAfter")
        let style: NSParagraphStyle? = attribute(.paragraphStyle, of: "one", in: s)
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
        XCTAssertEqual(style?.firstLineHeadIndent, 0)
        XCTAssertEqual(citations(s).map(\.number), [2])
        let intro: NSParagraphStyle? = attribute(.paragraphStyle, of: "Intro", in: s)
        XCTAssertEqual(intro?.headIndent, 0)
        XCTAssertEqual(attribute(.foregroundColor, of: "•", in: s), NSColor.secondaryLabelColor)
    }

    func testOrderedListKeepsNumbers() {
        XCTAssertEqual(render("1. first\n2) second").string, "1.\tfirst\n2)\tsecond")
    }

    func testStarBulletIsNotBold() {
        XCTAssertEqual(render("* **Pricing** holds").string, "•\tPricing holds")
    }

    func testHeadingBecomesSemiboldLine() {
        let s = render("## Pricing\nBody")
        XCTAssertEqual(s.string, "Pricing\nBody")
        XCTAssertEqual(attribute(.font, of: "Pricing", in: s), NSFont.systemFont(ofSize: 13, weight: .semibold))
        XCTAssertEqual(render("#hashtag").string, "#hashtag")
    }

    func testSingleNewlineIsLineBreak() {
        XCTAssertEqual(render("a\nb").string, "a\u{2028}b")
    }

    func testStreamingHidesPartialCitation() {
        XCTAssertEqual(render("Price [", streaming: true).string, "Price")
        XCTAssertEqual(render("Price [1", streaming: true).string, "Price")
        XCTAssertEqual(render("Price [2,", streaming: true).string, "Price")
        XCTAssertEqual(render("Price [2]", streaming: true).string, "Price [2]")
    }

    func testStreamingStylesUnclosedMarkers() {
        let s = render("Price **forty", streaming: true)
        XCTAssertEqual(s.string, "Price forty")
        XCTAssertEqual(attribute(.font, of: "forty", in: s), NSFont.systemFont(ofSize: 13, weight: .semibold))
        XCTAssertEqual(render("Price **", streaming: true).string, "Price ")
        XCTAssertEqual(render("Price *", streaming: true).string, "Price")
        XCTAssertEqual(render("Price **forty*", streaming: true).string, "Price forty")
        XCTAssertEqual(render("Price *soft*", streaming: true).string, "Price soft")
        let code = render("cell `Q3!B", streaming: true)
        XCTAssertEqual(code.string, "cell Q3!B")
        XCTAssertEqual(attribute(.font, of: "Q3!B", in: code), NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    func testCitationInsideBoldKeepsWeight() {
        let s = render("**Pricing holds [3]** after")
        XCTAssertEqual(citations(s).map(\.number), [3])
        XCTAssertEqual(attribute(.font, of: "[3]", in: s), NSFont.systemFont(ofSize: 13, weight: .semibold))
    }
}
