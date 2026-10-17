import XCTest
@testable import FlamingoIndex
import FlamingoCore

final class CompactionTests: IndexTestCase {
    private func layout(_ table: String = "sections_fts") throws -> IndexStore.FTSLayout {
        try store.read { try store.ftsLayout(table, in: $0) }
    }

    /// One transaction per file, as the shell's batches and the watcher produce them.
    private func indexSeparately(_ count: Int) throws {
        for i in 0..<count {
            let ref = try write("notes/n\(i).md", "budget forecast note \(i) margin pricing runway \(i % 7)")
            try store.update([ref])
        }
    }

    func testCompactionMergesSegmentsAndKeepsResults() throws {
        try indexSeparately(24)
        XCTAssertGreaterThan(try layout().segments, 1, "each transaction writes its own segment")
        let before = try store.search("budget", limit: 100).map(\.file.relativePath)
        let sectionsBefore = try store.searchSections("pricing runway", limit: 100).map(\.file.relativePath)
        XCTAssertEqual(before.count, 24)

        XCTAssertTrue(try store.compactSearchIndex(force: true))
        XCTAssertEqual(try layout().segments, 1)
        XCTAssertEqual(try store.search("budget", limit: 100).map(\.file.relativePath), before)
        XCTAssertEqual(try store.searchSections("pricing runway", limit: 100).map(\.file.relativePath), sectionsBefore)
        XCTAssertFalse(try store.searchIndexNeedsCompaction())
    }

    func testCancelledCompactionStopsAndLeavesAWorkingIndex() throws {
        try indexSeparately(12)
        XCTAssertFalse(try store.compactSearchIndex(force: true, shouldCancel: { true }))
        XCTAssertEqual(try store.search("forecast", limit: 100).count, 12)
    }

    func testReindexLeavesOneSegment() throws {
        try indexSeparately(16)
        try store.reindex()
        XCTAssertEqual(try layout().segments, 1)
        XCTAssertEqual(try store.search("margin", limit: 100).count, 16)
    }

    /// The structure record lists the same segments the `_idx` table points into.
    func testLayoutReadsTheStructureRecord() throws {
        try indexSeparately(24)
        let segids = try store.writer.query("SELECT DISTINCT segid FROM sections_fts_idx") { $0.int(0) }
        let layout = try layout()
        XCTAssertEqual(layout.segments, segids.count)
        XCTAssertEqual(layout.merging, 0)
        XCTAssertGreaterThan(layout.largest, 0)
        XCTAssertNil(IndexStore.FTSLayout(structure: Data([0, 0, 0, 1, 0x81])))
    }

    /// One bounded step per quiet spell, with a write burst between spells, as on a large
    /// index that is always changing. Each spell used to re-plan the merge from scratch, so
    /// segments piled up until FTS5's limit of 2,000 and every write failed with SQLITE_FULL.
    func testWritesBetweenStepsContinueTheMerge() throws {
        IndexStore.compactionStepPages = 2
        defer { IndexStore.compactionStepPages = 500 }
        let words = { (i: Int) in (0..<120).map { "t\(i)x\($0)" }.joined(separator: " ") }
        for i in 0..<30 { try store.update([try write("notes/n\(i).md", "ledger " + words(i))]) }
        XCTAssertTrue(try store.compactSearchIndex(force: true))
        for i in 30..<36 { try store.update([try write("notes/n\(i).md", "ledger " + words(i))]) }

        var peak = 0
        var merged = false
        for i in 0..<150 {
            var steps = 0
            _ = try store.compactSearchIndex(force: true, shouldCancel: { defer { steps += 1 }; return steps > 0 })
            if try layout().merging > 0 { merged = true }
            try store.update([try write("later/l\(i).md", "ledger later \(i)")])
            peak = max(peak, try layout().segments)
        }
        XCTAssertTrue(merged, "the test should exercise a merge that spans quiet spells")
        XCTAssertLessThan(peak, 40, "segments must not pile up across interrupted merges")
        XCTAssertTrue(try store.compactSearchIndex(force: true))
        XCTAssertEqual(try layout().segments, 1)
        XCTAssertEqual(try store.search("ledger", limit: 500).count, 186)
    }

    func testPolicyRewritesOnlyWhenWorthIt() {
        typealias L = IndexStore.FTSLayout
        XCTAssertFalse(L(segments: 1, largest: 900, rest: 0).wantsCompaction)
        XCTAssertFalse(L(segments: 3, largest: 900, rest: 20).wantsCompaction, "a few small segments beside a big one")
        XCTAssertTrue(L(segments: 3, largest: 900, rest: 200).wantsCompaction, "enough new data to amortise a rewrite")
        XCTAssertTrue(L(segments: 8, largest: 900, rest: 8).wantsCompaction, "many segments cost a seek each per term")
    }

    func testReadOnlyStoreNeverCompacts() throws {
        try indexSeparately(6)
        let reader = try IndexStore(vault: vault, readOnly: true)
        XCTAssertTrue(try reader.compactSearchIndex(force: true))
        XCTAssertGreaterThan(try layout().segments, 1)
    }

    /// A pass that finds a note unchanged must not rewrite its rows (FTS churn on every launch).
    func testUnchangedCommentsAreNotRewritten() throws {
        let ref = try write("a.md", "alpha")
        try SidecarStore(vault: vault).append(Comment(text: "keep [[a.md]] steady"), to: ref)
        try store.update([ref])
        let rows = { try self.store.writer.query("SELECT rowid, text FROM comments WHERE path = 'a.md' ORDER BY rowid") { "\($0.int(0)):\($0.string(1))" } }
        let first = try rows()
        XCTAssertEqual(first.count, 1)
        try store.update([ref], force: true)
        XCTAssertEqual(try rows(), first)
        try SidecarStore(vault: vault).append(Comment(text: "a second thought"), to: ref)
        try store.update([ref])
        XCTAssertEqual(try rows().count, 2)
        XCTAssertEqual(try store.searchComments("second").first?.file, ref)
    }
}
