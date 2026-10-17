import AppKit
import XCTest
@testable import FlamingoTrail
import FlamingoCore

final class TrailRichTextTests: XCTestCase {
    @MainActor
    func testNativeLinkDelegateOpensAliasedExactLocationFromOriginalSource() throws {
        let source = FileRef(relativePath: "Notes/working.md")
        let target = "Research/预算 & plan.xlsx#cell Q3!B12"
        var opened: (String, FileRef)?
        let bridge = TrailRichText(note: .init(id: UUID(), text: "See [[\(target)|the budget]]"), source: source,
                                   onOpenLink: { opened = ($0, $1) })
        let text = bridge.attributed
        XCTAssertEqual(text.string, "See the budget")
        let link = try XCTUnwrap(text.attribute(.link, at: 5, effectiveRange: nil) as? URL)
        let coordinator = bridge.makeCoordinator()
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: link, at: 5))
        XCTAssertEqual(opened?.0, target)
        XCTAssertEqual(opened?.1, source)
    }

    @MainActor
    func testSourceAndCallbackFollowReusedNativeView() throws {
        let note = TrailNote(id: UUID(), text: "[[../deck.pptx#slide 7|pricing]]")
        var firstCalls = 0
        var latestSource: FileRef?
        let first = TrailRichText(note: note, source: .init(relativePath: "A/note.md"), onOpenLink: { _, _ in firstCalls += 1 })
        let coordinator = first.makeCoordinator()
        coordinator.parent = TrailRichText(note: note, source: .init(relativePath: "B/note.md"), onOpenLink: { _, source in latestSource = source })
        let link = try XCTUnwrap(first.attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: link.absoluteString, at: 0))
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(latestSource?.relativePath, "B/note.md")
    }

    func testLinkEncodingPreservesSpacesUnicodeFragmentsAndLiteralPercentSigns() throws {
        for target in ["研究/预算 100%.xlsx#cell Q3!B12", "../A & B.md#heading Scope + risks?", "slides.pptx#slide=7"] {
            let url = try XCTUnwrap(TrailRichText.linkURL(for: target))
            XCTAssertEqual(TrailRichText.linkTarget(from: url), target)
        }
        XCTAssertNil(TrailRichText.linkURL(for: ""))
        for raw in ["https://open?target=note.md", "flamingo-trail-link://other?target=note.md", "flamingo-trail-link://open?target=", "flamingo-trail-link://open"] {
            XCTAssertNil(TrailRichText.linkTarget(from: try XCTUnwrap(URL(string: raw))))
        }
    }

    @MainActor
    func testNotesWithoutNavigationDoNotAdvertiseDeadLinks() {
        let note = TrailNote(id: UUID(), anchor: .init(kind: .slide, value: "7"), text: "[[deck.pptx|pricing]]")
        let standalone = TrailRichText(note: note, source: nil, onOpenLink: nil).attributed
        XCTAssertEqual(standalone.string, "slide 7  pricing")
        XCTAssertNil(standalone.attribute(.link, at: standalone.length - 1, effectiveRange: nil))
        let noAction = TrailRichText(note: note, source: .init(relativePath: "note.md"), onOpenLink: nil).attributed
        XCTAssertEqual(noAction.string, "pricing")
        XCTAssertNil(noAction.attribute(.link, at: 0, effectiveRange: nil))
    }
}
