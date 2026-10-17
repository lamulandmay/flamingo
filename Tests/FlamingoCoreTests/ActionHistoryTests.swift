import XCTest
@testable import FlamingoCore

@MainActor
final class ActionHistoryTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testDeletionWorksBeforeTenSecondsAndExpiresExactlyAtTen() throws {
        var time: TimeInterval = 100
        var deleted = true
        let history = ActionHistory(now: { time })
        history.register(name: "Delete File", expiresAfter: 10,
                         undo: { deleted = false }, redo: { deleted = true })
        time = 109.999
        XCTAssertTrue(try history.undo())
        XCTAssertFalse(deleted)
        XCTAssertTrue(try history.redo())
        XCTAssertTrue(deleted)
        time = 110
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(try history.undo())
        XCTAssertTrue(deleted)
    }

    func testExpiredBuriedDeletionDoesNotDiscardUnrelatedActions() throws {
        var time: TimeInterval = 0
        var applied: [String] = []
        let history = ActionHistory(now: { time })
        history.register(name: "First", undo: { applied.append("first") }, redo: {})
        history.register(name: "Delete", expiresAfter: 10,
                         undo: { applied.append("delete") }, redo: {})
        history.register(name: "Last", undo: { applied.append("last") }, redo: {})
        time = 100_000
        XCTAssertEqual(history.undoActionName, "Last")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(history.undoActionName, "First")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(applied, ["last", "first"])
        XCTAssertFalse(history.canUndo)
    }

    func testUndoAndRedoCheckDeadlinesEvenWithoutAStatusRead() throws {
        var time: TimeInterval = 0
        var deleted = true
        let history = ActionHistory(now: { time })
        history.register(name: "Delete", expiresAfter: 10,
                         undo: { deleted = false }, redo: { deleted = true })
        time = 10
        XCTAssertFalse(try history.undo())
        XCTAssertTrue(deleted)
        time = 20
        history.register(name: "Delete", expiresAfter: 10,
                         undo: { deleted = false }, redo: { deleted = true })
        XCTAssertTrue(try history.undo())
        time = 30
        XCTAssertFalse(try history.redo())
        XCTAssertFalse(deleted)
    }

    func testExpirationAlsoRemovesBuriedRedoEntriesWithoutRenewingDeadline() throws {
        var time: TimeInterval = 0
        var deleted = true
        let history = ActionHistory(now: { time })
        history.register(name: "Ordinary", undo: {}, redo: {})
        history.register(name: "Delete", expiresAfter: 10,
                         undo: { deleted = false }, redo: { deleted = true })
        time = 9
        XCTAssertTrue(try history.undo())
        XCTAssertTrue(try history.undo())
        time = 10
        XCTAssertEqual(history.redoActionName, "Ordinary")
        XCTAssertTrue(try history.redo())
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(deleted)
    }

    func testUndoAndRedoFailuresPreserveRetryableOriginalAction() throws {
        let history = ActionHistory()
        var failUndo = true, failRedo = true, value = 1
        history.register(name: "Change", undo: {
            if failUndo { throw Failure.unavailable }
            value = 0
        }, redo: {
            if failRedo { throw Failure.unavailable }
            value = 1
        })
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoActionName, "Change")
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isApplying)
        XCTAssertEqual(value, 1)
        failUndo = false
        XCTAssertTrue(try history.undo())
        XCTAssertThrowsError(try history.redo())
        XCTAssertEqual(history.redoActionName, "Change")
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.isApplying)
        XCTAssertEqual(value, 0)
        failRedo = false
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(value, 1)
    }

    func testTargetedUndoCannotSkipNewerActions() throws {
        let history = ActionHistory()
        let first = history.register(name: "First", undo: {}, redo: {})
        let last = history.register(name: "Last", undo: {}, redo: {})
        XCTAssertFalse(try history.undo(id: first))
        XCTAssertEqual(history.undoActionName, "Last")
        XCTAssertTrue(try history.undo(id: last))
        XCTAssertTrue(try history.undo(id: first))
    }

    func testDiscardRedoPreservesUnrelatedUndoHistory() throws {
        let history = ActionHistory()
        history.register(name: "First", undo: {}, redo: {})
        history.register(name: "Last", undo: {}, redo: {})
        XCTAssertTrue(try history.undo())
        history.discardRedo()
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoActionName, "First")
        XCTAssertTrue(try history.undo())
    }

    func testRegistrationRevisionChangesOnlyForFreshActions() throws {
        let history = ActionHistory()
        XCTAssertEqual(history.registrationRevision, 0)
        history.register(name: "First", undo: {
            history.register(name: "Nested", undo: {}, redo: {})
        }, redo: {})
        XCTAssertEqual(history.registrationRevision, 1)
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(history.registrationRevision, 1)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(history.registrationRevision, 1)
        history.register(name: "Second", undo: {}, redo: {})
        XCTAssertEqual(history.registrationRevision, 2)
    }

    func testOnlyClearStartsANewHistoryContext() throws {
        let history = ActionHistory()
        let originalContext = history.contextID
        history.register(name: "First", undo: {}, redo: {})
        XCTAssertTrue(try history.undo())
        XCTAssertTrue(try history.redo())
        history.discardRedo()
        XCTAssertEqual(history.contextID, originalContext)
        let registrations = history.registrationRevision
        history.clear()
        XCTAssertNotEqual(history.contextID, originalContext)
        XCTAssertEqual(history.registrationRevision, registrations)
        let secondContext = history.contextID
        history.clear()
        XCTAssertNotEqual(history.contextID, secondContext)
    }

    func testNewActionClearsRedoAndApplyingSuppressesNestedRegistration() throws {
        let history = ActionHistory()
        var wasApplying = false
        history.register(name: "Initial", undo: {
            wasApplying = history.isApplying
            history.register(name: "Nested", undo: {}, redo: {})
            XCTAssertFalse(try history.undo())
        }, redo: {})
        XCTAssertTrue(try history.undo())
        XCTAssertTrue(wasApplying)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        history.register(name: "New", undo: {}, redo: {})
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoActionName, "New")
    }

    func testRepeatedQuickUndoIsStrictlyOrderedAndTimestampsTrackTransitions() throws {
        var time: TimeInterval = 20
        var values: [Int] = []
        let history = ActionHistory(now: { time })
        for value in 0..<20 {
            history.register(name: "\(value)", undo: { values.append(value) }, redo: {})
        }
        XCTAssertEqual(history.latestUndoTime, 20)
        time = 21
        for _ in 0..<20 { XCTAssertTrue(try history.undo()) }
        XCTAssertEqual(values, Array((0..<20).reversed()))
        XCTAssertNil(history.latestUndoTime)
        XCTAssertEqual(history.latestRedoTime, 21)
        time = 22
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(history.latestUndoTime, 22)
        history.clear()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.latestUndoTime)
        XCTAssertNil(history.latestRedoTime)
    }
}
