import XCTest
@testable import FlamingoCore

final class ThoughtStrengthTests: XCTestCase {
    func testQuickDumpsAreSparks() {
        XCTAssertEqual(ThoughtStrength(text: "too fast"), .spark)
        XCTAssertEqual(ThoughtStrength(text: "interesting"), .spark)
        XCTAssertEqual(ThoughtStrength(text: "check this again"), .spark)
    }

    func testALinkAloneIsSolid() {
        XCTAssertEqual(ThoughtStrength(text: "[[q3-model.xlsx]]"), .solid)
        XCTAssertEqual(ThoughtStrength(text: "see [[plasmids.pptx]]"), .solid)
    }

    func testASpecificReasonedThoughtWithoutALinkIsSolidNotWoven() {
        XCTAssertEqual(ThoughtStrength(text: "need to check the plasmid map again before friday"), .solid)
        let long = "The pH flip happens too fast because the frames were shot 2 s apart. Reshoot at 0.5 s and keep the lighting fixed."
        XCTAssertEqual(ThoughtStrength(text: long), .solid)
    }

    func testLinkedAndReasonedIsWoven() {
        XCTAssertEqual(ThoughtStrength(text: "Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229."), .woven)
        XCTAssertEqual(ThoughtStrength(text: "pH flip is too fast, retime to match [[plasmids.pptx]] slide 4"), .woven)
        XCTAssertEqual(ThoughtStrength(text: "[[a.pdf]] [[b.pdf]] should agree"), .woven)
    }

    func testDigitsInsideLinksAreNotSpecifics() {
        XCTAssertEqual(ThoughtStrength.points(text: "[[q3-model.xlsx]]", links: 1), 2)
    }

    func testTheSameLinkTwiceCountsOnce() {
        XCTAssertEqual(ThoughtStrength(text: "[[a.pdf]] and [[A.pdf]] and [[a.pdf#page 2]]"), .solid)
    }

    func testChineseCountsWordsAndReasons() {
        XCTAssertEqual(ThoughtStrength.wordCount("因为时间太短所以要重拍"), 5)
        XCTAssertTrue(ThoughtStrength.hasReason("因为时间太短所以要重拍"))
        XCTAssertEqual(ThoughtStrength(text: "因为时间太短所以要重拍，参考 [[plasmids.pptx]] 第4页"), .woven)
    }

    func testReasonsMatchWholeWordsOnly() {
        XCTAssertFalse(ThoughtStrength.hasReason("soap butter"))
        XCTAssertTrue(ThoughtStrength.hasReason("fine, but slow"))
        XCTAssertTrue(ThoughtStrength.hasReason("draft → final"))
    }
}
