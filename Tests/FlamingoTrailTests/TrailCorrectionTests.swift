import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailCorrectionTests: TrailStoreTestCase {
    private func record(_ events: [TrailEvent], in store: TrailStore) throws {
        for file in Set(events.compactMap(\.file)) {
            try Data().write(to: vault.url(for: file))
        }
        events.forEach(store.record)
        store.flush()
    }

    func testExclusionPersistsAndStopsInferenceWithoutRemovingHistory() throws {
        let store = makeStore()
        try record(opens(["a.md", "b.md"]), in: store)
        let original = try Data(contentsOf: store.fileURL)
        let session = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(try store.edges().count, 1)
        try store.setExcludedFromGraph(true, for: session)
        let reopened = TrailStore(vault: vault)
        XCTAssertTrue(try XCTUnwrap(reopened.sessions().first).excludesInferredConnections)
        XCTAssertEqual(try reopened.edges(), [])
        XCTAssertEqual(try reopened.events(), try store.events())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try reopened.setExcludedFromGraph(false, for: session)
        XCTAssertEqual(try reopened.edges().count, 1)
    }

    func testSplitChangesEdgesPreservesEventsNamesAndStableIDs() throws {
        let store = makeStore(), events = opens(["a.md", "b.md", "c.md"])
        try record(events, in: store)
        let original = try Data(contentsOf: store.fileURL)
        let session = try XCTUnwrap(store.sessions().first)
        try store.setTitle("Research", for: session)
        try store.splitSession(session, before: events[1].id)
        let split = try TrailStore(vault: vault).sessions()
        XCTAssertEqual(split.map(\.id), [events[0].id, events[1].id])
        XCTAssertEqual(split.map(\.files), [[ref("a.md")], [ref("b.md"), ref("c.md")]])
        XCTAssertEqual(split[0].title, "Research")
        XCTAssertEqual(split.flatMap(\.events), events)
        XCTAssertEqual(try store.edges().map { [$0.source, $0.target] }, [["b.md", "c.md"]])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try store.restoreAutomaticGrouping(for: split[1])
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertEqual(try store.edges().count, 3)
    }

    func testSplitExcludedSessionKeepsBothPartsExcludedIncludingLaterEvents() throws {
        let store = makeStore(), events = opens(["a.md", "b.md", "c.md"])
        try record(events, in: store)
        let session = try XCTUnwrap(store.sessions().first)
        try store.setExcludedFromGraph(true, for: session)
        try store.splitSession(session, before: events[1].id)
        store.record(ev(.saved, 40, file: "b.md"))
        XCTAssertTrue(try store.sessions().allSatisfy(\.excludesInferredConnections))
        XCTAssertEqual(try store.edges(), [])
        XCTAssertEqual(try store.events().count, 4)
    }

    func testMergeAcrossIdleGapAndRestoreGroupingKeepsBothNames() throws {
        let store = makeStore()
        try record(opens(["a.md", "b.md"]) + opens(["c.md", "d.md"], from: 3600), in: store)
        let original = try Data(contentsOf: store.fileURL)
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.count, 2)
        try store.setTitle("Morning", for: sessions[0]); try store.setTitle("Afternoon", for: sessions[1])
        try store.mergeSessionWithPrevious(sessions[1])
        let merged = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertEqual(merged.id, sessions[0].id)
        XCTAssertEqual(merged.title, "Morning")
        XCTAssertEqual(try store.edges().count, 6)
        try store.restoreAutomaticGrouping(for: merged)
        XCTAssertEqual(try store.sessions().map(\.title), ["Morning", "Afternoon"])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testMergedExclusionCanBeReincludedExplicitly() throws {
        let store = makeStore()
        try record(opens(["a.md"]) + opens(["b.md"], from: 3600), in: store)
        let sessions = try store.sessions()
        try store.setExcludedFromGraph(true, for: sessions[1])
        try store.mergeSessionWithPrevious(sessions[1])
        let merged = try XCTUnwrap(store.sessions().first)
        XCTAssertTrue(merged.excludesInferredConnections)
        try store.setExcludedFromGraph(false, for: merged)
        XCTAssertEqual(try store.edges().count, 1)
    }

    func testInvalidCorrectionsDoNotCreateMetadataAndCorruptMetadataIsPreserved() throws {
        let store = makeStore(), events = opens(["a.md", "b.md"])
        try record(events, in: store)
        let session = try XCTUnwrap(store.sessions().first)
        XCTAssertThrowsError(try store.splitSession(session, before: events[0].id))
        XCTAssertThrowsError(try store.splitSession(session, before: UUID()))
        XCTAssertThrowsError(try store.mergeSessionWithPrevious(session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.correctionsURL.path))
        let corrupt = Data("broken corrections".utf8); try corrupt.write(to: store.correctionsURL)
        XCTAssertThrowsError(try store.setExcludedFromGraph(true, for: session))
        XCTAssertThrowsError(try store.edges(), "Never silently infer edges when exclusion metadata is unreadable")
        XCTAssertEqual(try store.sessions(ignoringCorrections: true).first?.events, events)
        XCTAssertEqual(try Data(contentsOf: store.correctionsURL), corrupt)
    }

    func testCorrectionsFollowFileRenameByEventID() throws {
        let store = makeStore(), events = opens(["a.md", "b.md"])
        try record(events, in: store)
        let session = try XCTUnwrap(store.sessions().first)
        try store.setExcludedFromGraph(true, for: session)
        try store.splitSession(session, before: events[1].id)
        try store.reconcile(oldPath: "b.md", newPath: "renamed.md")
        let sessions = try store.sessions()
        XCTAssertEqual(sessions[1].id, events[1].id)
        XCTAssertEqual(sessions[1].files, [ref("renamed.md")])
        XCTAssertTrue(sessions.allSatisfy(\.excludesInferredConnections))
    }
}

@MainActor
final class TrailCorrectionViewTests: XCTestCase {
    func testUnreadableCorrectionsKeepHistoryVisibleWithError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trail-correction-view-\(UUID())")
        let vault = Vault(root: root), store = TrailStore(vault: Vault(root: root))
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(ev(.opened, 0, file: "a.md")).write(to: store.fileURL)
        try Data("broken corrections".utf8).write(to: store.correctionsURL)
        let live = TrailLiveSessions()
        live.attach(store)
        for _ in 0..<100 where live.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(live.sessions.count, 1)
        XCTAssertTrue(live.error?.contains("Session corrections could not be loaded") == true)
        live.attach(nil)
    }
}
