import XCTest
@testable import FlamingoExtract

final class ZipBudgetTests: XCTestCase {
    func testAggregateXMLBudgetRejectsManyIndividuallyValidMembers() throws {
        let file = try Fixtures.tempDir(self).appendingPathComponent("aggregate.zip")
        let member = Data(repeating: 65, count: 33 << 20)
        XCTAssertLessThan(member.count, ZipArchive.maxMemberSize)
        try Fixtures.zip(["one.xml": member, "two.xml": member], to: file)
        XCTAssertThrowsError(try ZipArchive(file)) { error in
            guard case ExtractError.malformed(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("budget"))
        }
    }
}
