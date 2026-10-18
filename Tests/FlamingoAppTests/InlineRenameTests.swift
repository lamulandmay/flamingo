import XCTest
@testable import Flamingo

final class InlineRenameTests: XCTestCase {
    func testARenameStartsWithTheNameWithoutItsExtensionSelected() {
        func selected(_ name: String, folder: Bool = false) -> String {
            (name as NSString).substring(with: RenameField.stem(of: name, isFolder: folder))
        }
        XCTAssertEqual(selected("market-sizing.pdf"), "market-sizing")
        XCTAssertEqual(selected("q3 model.v2.xlsx"), "q3 model.v2", "Only the last extension stays out")
        XCTAssertEqual(selected("README"), "README")
        XCTAssertEqual(selected(".gitignore"), ".gitignore", "A dot file is all name")
        XCTAssertEqual(selected("2026.archive", folder: true), "2026.archive", "A folder's whole name")
        XCTAssertEqual(selected("café ☕️.md"), "café ☕️", "Measured in the field's UTF-16 units")
    }
}
