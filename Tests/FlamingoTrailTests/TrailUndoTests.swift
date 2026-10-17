import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailUndoTests: TrailStoreTestCase {
    func testCorrectionSnapshotsRestoreMergeSplitExclusionAndAutomaticGrouping() throws {
        let store = makeStore()
        let events = opens(["a.md", "b.md"]) + opens(["c.md", "d.md"], from: 3600)
        events.forEach(store.record); store.flush()
        let originalLog = try Data(contentsOf: store.fileURL)
        let originalSessions = try store.sessions()
        let exclusion = try store.applyCorrection(.excluded(true), to: originalSessions[1])
        let merge = try store.applyCorrection(.mergePrevious, to: originalSessions[1])
        let merged = try XCTUnwrap(store.sessions().first)
        XCTAssertTrue(merged.excludesInferredConnections)
        let split = try store.applyCorrection(.splitBefore(events[1].id), to: merged)
        let splitPart = try XCTUnwrap(store.sessions().last)
        let automatic = try store.applyCorrection(.automaticGrouping, to: splitPart)
        for change in [automatic, split, merge, exclusion] {
            try store.restoreCorrections(change.before, expecting: change.after)
        }
        XCTAssertEqual(try store.sessions(), originalSessions)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalLog)
        for change in [exclusion, merge, split, automatic] {
            try store.restoreCorrections(change.after, expecting: change.before)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalLog)
    }

    func testUndoPreservesNewEventsAndRejectsConflictingCorrection() throws {
        let store = makeStore()
        opens(["a.md", "b.md"]).forEach(store.record)
        let session = try XCTUnwrap(store.sessions().first)
        let change = try store.applyCorrection(.excluded(true), to: session)
        let appended = ev(.saved, 40, file: "b.md")
        store.record(appended)
        try store.restoreCorrections(change.before, expecting: change.after)
        XCTAssertTrue(try store.events().contains(appended))
        try store.restoreCorrections(change.after, expecting: change.before)
        try store.splitSession(session, before: session.events[1].id)
        let external = try Data(contentsOf: store.correctionsURL)
        XCTAssertThrowsError(try store.restoreCorrections(change.before, expecting: change.after))
        XCTAssertEqual(try Data(contentsOf: store.correctionsURL), external)
    }

    func testTitleUndoPreservesOtherNamesAndChecksOriginalTitle() throws {
        let store = makeStore()
        (opens(["a.md"]) + opens(["b.md"], from: 3600)).forEach(store.record)
        let sessions = try store.sessions()
        let change = try store.renameSession(sessions[0], to: "First name")
        try store.setTitle("Other session", for: sessions[1])
        try store.restoreTitle(change.before, for: change.sessionID, expecting: change.after)
        XCTAssertNil(store.title(for: sessions[0]))
        XCTAssertEqual(store.title(for: sessions[1]), "Other session")
        try store.restoreTitle(change.after, for: change.sessionID, expecting: change.before)
        try store.setTitle("External title", for: sessions[0])
        XCTAssertThrowsError(try store.restoreTitle(change.before, for: change.sessionID, expecting: change.after))
        XCTAssertEqual(store.title(for: sessions[0]), "External title")
    }
}
