import XCTest
@testable import FlamingoTrail

final class SmokeTests: XCTestCase {
    func testBuilds() { XCTAssertEqual(TrailTuning().sessionGap, 25 * 60) }
}
