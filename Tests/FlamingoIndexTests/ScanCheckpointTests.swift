import XCTest
@testable import FlamingoIndex
import FlamingoCore

final class ScanCheckpointTests: IndexTestCase {
    func testCheckpointHoldsOnlyForTheSameHistoryAndRules() throws {
        XCTAssertNil(store.scanCheckpoint(history: "disk-a"), "no walk yet")
        // Whole seconds: a Date's 1970-based interval doesn't always survive a round trip to the last bit.
        let point = ScanCheckpoint(eventID: 500, history: "disk-a", walkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))
        try store.saveScanCheckpoint(point)
        XCTAssertEqual(store.scanCheckpoint(history: "disk-a"), point)
        XCTAssertNil(store.scanCheckpoint(history: "disk-b"), "ids from another event history mean nothing")
        XCTAssertNil(store.scanCheckpoint(history: nil))
        XCTAssertNil(store.scanCheckpoint(history: "disk-a", now: Date().addingTimeInterval(IndexStore.maxWalkAge + 1)),
                     "a replay never stands in for a walk forever")

        try store.saveScanCheckpoint(ScanCheckpoint(eventID: 400, history: "disk-a", walkedAt: Date()))
        XCTAssertEqual(store.scanCheckpoint(history: "disk-a")?.eventID, 500, "never moves backwards")

        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try "*.log\n".write(to: vault.ignoreURL, atomically: true, encoding: .utf8)
        XCTAssertNil(store.scanCheckpoint(history: "disk-a"), "rules edited while closed mean a walk")
        try store.saveScanCheckpoint(point)
        XCTAssertNotNil(store.scanCheckpoint(history: "disk-a"))
        try store.clearScanCheckpoint()
        XCTAssertNil(store.scanCheckpoint(history: "disk-a"))
    }

    func testStaleFilesAreThoseAnExtractorUpdateInvalidated() throws {
        try write("a.fltest", "alpha")
        try write("b.fltest", "beta")
        try store.reindex()
        XCTAssertEqual(try store.staleFiles(), [])
        try store.writer.run("UPDATE files SET size = -1 WHERE path = 'b.fltest'")
        XCTAssertEqual(try store.staleFiles(), [ref("b.fltest")])
        XCTAssertEqual(try store.update([ref("b.fltest")], force: false, shouldCancel: { false }), 1)
        XCTAssertEqual(try store.staleFiles(), [])
        XCTAssertEqual(try store.fileCount(), 2)
    }

    func testAWalkLeavesStaleRowsForTheRefreshButReadsEdits() throws {
        try write("a.fltest", "alpha")
        try store.reindex()
        try store.writer.run("UPDATE files SET size = -1")
        XCTAssertEqual(try store.update([ref("a.fltest")], force: false, shouldCancel: { false }, deferStale: true), 0)
        XCTAssertEqual(try store.staleFiles(), [ref("a.fltest")], "still waiting for the refresh pass")
        Thread.sleep(forTimeInterval: 0.01)
        try write("a.fltest", "alpha beta")
        XCTAssertEqual(try store.update([ref("a.fltest")], force: false, shouldCancel: { false }, deferStale: true), 1,
                       "a file edited since is read at once")
        XCTAssertEqual(try store.staleFiles(), [])
    }
}
