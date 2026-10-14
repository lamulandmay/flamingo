import XCTest
@testable import FlamingoCore

final class WikilinkTests: XCTestCase {
    func testParsesTargetsAliasesAnchors() {
        XCTAssertEqual(Wikilink.parse("see [[a.pptx]] and [[b|B]] and [[c#slide 3]] and [[a.pptx]]"), ["a.pptx", "b", "c"])
    }
}
