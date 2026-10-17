import XCTest
@testable import FlamingoIndex
import FlamingoCore

/// What keeps the index small: budgets for machine-written text, pruning that rebuilds
/// instead of tombstoning, and free pages handed back to the disk.
final class StorageTests: IndexTestCase {
    private func storedText(_ path: String) throws -> Int {
        try store.writer.scalarInt("SELECT coalesce(sum(length(text)), 0) FROM sections WHERE path = ?", path)
    }

    private func assertSearchIndexMatchesRows(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try store.writer.run("INSERT INTO sections_fts(sections_fts, rank) VALUES('integrity-check', 1)"), file: file, line: line)
    }

    func testLogsAndDataKeepOnlyTheirStart() throws {
        let filler = String(repeating: "lorem ipsum dolor ", count: 20_000)   // 360k characters
        try store.update([try write("server.log", filler + "tailmarker"), try write("essay.md", filler + "tailmarker")])
        XCTAssertLessThanOrEqual(try storedText("server.log"), IndexStore.maxDataFileText)
        XCTAssertGreaterThan(try storedText("essay.md"), 360_000)
        XCTAssertEqual(try store.search("tailmarker", limit: 10).map(\.file.relativePath), ["essay.md"])
        XCTAssertEqual(try store.search("lorem", limit: 10).count, 2)
    }

    func testPruningMostOfTheIndexRebuildsSearch() throws {
        IndexStore.bulkPruneMinimum = 10
        defer { IndexStore.bulkPruneMinimum = 5_000 }
        var refs: [FileRef] = []
        for i in 0..<40 { refs.append(try write(i < 10 ? "keep/k\(i).md" : "env/e\(i).md", "quartz \(i < 10 ? "kept" : "gone") note \(i)")) }
        try store.update(refs)
        for ref in refs.dropFirst(10) { try FileManager.default.removeItem(at: vault.url(for: ref)) }

        XCTAssertEqual(try store.pruneUnseen(Array(refs.dropFirst(10))), 30)
        XCTAssertEqual(try store.search("quartz", limit: 100).count, 10)
        XCTAssertEqual(try store.search("gone", limit: 100).count, 0)
        assertSearchIndexMatchesRows()

        // The delete trigger is back: a small prune keeps search in step row by row.
        try FileManager.default.removeItem(at: vault.url(for: refs[0]))
        XCTAssertEqual(try store.pruneUnseen([refs[0]]), 1)
        XCTAssertEqual(try store.search("kept", limit: 100).count, 9)
        assertSearchIndexMatchesRows()
    }

    func testFreedPagesGoBackToTheDisk() throws {
        let body = (0..<400).map { "w\($0)" }.joined(separator: " ")
        var refs: [FileRef] = []
        for i in 0..<300 { refs.append(try write("n/\(i).md", "\(body) n\(i)")) }
        try store.update(refs)
        for ref in refs { try FileManager.default.removeItem(at: vault.url(for: ref)) }
        try store.pruneUnseen(refs)
        XCTAssertEqual(try store.writer.scalarInt("PRAGMA auto_vacuum"), 2, "a new index can shrink")
        let before = try store.writer.scalarInt("PRAGMA page_count")
        XCTAssertGreaterThan(try store.writer.scalarInt("PRAGMA freelist_count"), 0)

        XCTAssertTrue(try store.releaseFreeSpace(force: true))
        XCTAssertEqual(try store.writer.scalarInt("PRAGMA freelist_count"), 0)
        XCTAssertLessThan(try store.writer.scalarInt("PRAGMA page_count"), before)
        assertSearchIndexMatchesRows()
    }
}
