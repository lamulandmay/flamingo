import XCTest
@testable import Flamingo

@MainActor
final class ColumnListingsTests: XCTestCase {
    private func key(_ path: String, hidden: Bool = false, sort: String = "name") -> ColumnListings.Key {
        ColumnListings.Key(url: URL(fileURLWithPath: path), hidden: hidden, foldersFirst: false, sort: sort, ascending: true)
    }

    private func entries(_ names: String...) -> [ColumnEntry] {
        names.map { ColumnEntry(url: URL(fileURLWithPath: "/l/" + $0), name: $0, isFolder: false, isHidden: false, isAlias: false) }
    }

    /// Going back finds the folder as it was last read, under the same settings only.
    func testAListingComesBackForTheSameFolderAndSettings() {
        let folder = "/listings-\(UUID().uuidString)"
        ColumnListings.put(entries("a", "b"), for: key(folder))
        XCTAssertEqual(ColumnListings.get(key(folder))?.map(\.name), ["a", "b"])
        XCTAssertNil(ColumnListings.get(key(folder, hidden: true)), "hidden files shown is another listing")
        XCTAssertNil(ColumnListings.get(key(folder, sort: "size")), "so is another order")

        ColumnListings.put(entries("a", "b", "c"), for: key(folder))
        XCTAssertEqual(ColumnListings.get(key(folder))?.map(\.name), ["a", "b", "c"], "a new read replaces it")
    }

    func testTheLeastRecentlyReadGoPastTheLimit() {
        let run = UUID().uuidString
        for i in 0..<ColumnListings.limit { ColumnListings.put(entries("x"), for: key("/\(run)/\(i)")) }
        // Read again, the first is the newest now; the second is the oldest.
        ColumnListings.put(entries("x"), for: key("/\(run)/0"))
        ColumnListings.put(entries("x"), for: key("/\(run)/new"))
        XCTAssertNotNil(ColumnListings.get(key("/\(run)/0")))
        XCTAssertNil(ColumnListings.get(key("/\(run)/1")))
        XCTAssertNotNil(ColumnListings.get(key("/\(run)/2")))
        XCTAssertNotNil(ColumnListings.get(key("/\(run)/new")))
    }

    /// A few huge folders can't hold on to hundreds of megabytes.
    func testTheItemsStayWithinTheBudget() {
        let run = UUID().uuidString
        let big = (0..<(ColumnListings.budget / 2)).map { ColumnEntry(url: URL(fileURLWithPath: "/b/\($0)"), name: "\($0)", isFolder: false, isHidden: false, isAlias: false) }
        ColumnListings.put(big, for: key("/\(run)/a"))
        ColumnListings.put(big, for: key("/\(run)/b"))
        ColumnListings.put(entries("x"), for: key("/\(run)/c"))
        XCTAssertNil(ColumnListings.get(key("/\(run)/a")), "the oldest went to make room")
        XCTAssertNotNil(ColumnListings.get(key("/\(run)/b")))
        XCTAssertNotNil(ColumnListings.get(key("/\(run)/c")))
        let tooBig = big + big + entries("x")
        ColumnListings.put(tooBig, for: key("/\(run)/huge"))
        XCTAssertNil(ColumnListings.get(key("/\(run)/huge")), "a folder bigger than the budget is never kept")
    }
}
