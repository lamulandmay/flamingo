import XCTest
@testable import FlamingoCapture
import FlamingoCore

final class ThoughtDraftCheckpointTests: XCTestCase {
    func fixture() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thought-checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }

    func testTypingQueuesWithoutWaitingAndQuitCheckpointPersistsLatestCaptureAndEdit() throws {
        let vault = try fixture(), file = FileRef(relativePath: "research.md")
        let gate = DispatchSemaphore(value: 0)
        ThoughtDraftCheckpoint.queue.async { _ = gate.wait(timeout: .now() + 1) }
        let start = Date()
        for i in 0..<20 { CaptureDraftStore.checkpoint(CaptureDraft(file: file, text: "capture \(i)"), in: vault) }
        let edit = Comment(text: "actively typed rail edit")
        CommentEditDraftStore.checkpoint(edit, for: file, in: vault)
        let elapsed = Date().timeIntervalSince(start)
        gate.signal()
        XCTAssertLessThan(elapsed, 0.25)
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertEqual(CaptureDraftStore.drafts(in: vault).first?.text, "capture 19")
        XCTAssertEqual(try CommentEditDraftStore.draft(for: file, in: vault), edit)
    }

    func testAcknowledgedOlderSaveCannotCancelNewerPendingEditRecovery() throws {
        let vault = try fixture(), file = FileRef(relativePath: "research.md")
        var edit = Comment(text: "being saved")
        let old = edit
        let revision = CommentEditDraftStore.checkpoint(edit, for: file, in: vault)
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        edit.text = "new typing after save began"
        CommentEditDraftStore.checkpoint(edit, for: file, in: vault)
        let removed = ThoughtDraftCheckpoint.enqueue(key: CommentEditDraftStore.recoveryKey(for: old, file: file, in: vault),
                                                    required: false, ifCurrent: revision, operation: {
            try CommentEditDraftStore.removeIfMatching(old, for: file, in: vault)
        })
        XCTAssertNil(removed, "A stale save completion cannot supersede a new snapshot")
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertEqual(try CommentEditDraftStore.draft(for: file, in: vault)?.text, edit.text)
    }

    func testDiscardRunsAfterQueuedCaptureWritesAndCannotResurrectDraft() throws {
        let vault = try fixture(), file = FileRef(relativePath: "research.md")
        let gate = DispatchSemaphore(value: 0)
        ThoughtDraftCheckpoint.queue.async { _ = gate.wait(timeout: .now() + 1) }
        CaptureDraftStore.checkpoint(CaptureDraft(file: file, text: "discarded thought"), in: vault)
        let key = CaptureDraftStore.recoveryKey(for: file, in: vault)
        ThoughtDraftCheckpoint.enqueue(key: key, operation: { try CaptureDraftStore.remove(file, in: vault) })
        gate.signal()
        XCTAssertNil(ThoughtDraftCheckpoint.flush(key: key))
        XCTAssertTrue(CaptureDraftStore.drafts(in: vault).isEmpty)
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertTrue(CaptureDraftStore.drafts(in: vault).isEmpty)
    }

    func testFailedBackupBlocksCheckpointWithoutOverwritingCorruptRecoveryThenRetryClearsFailure() throws {
        let vault = try fixture(), file = FileRef(relativePath: "research.md")
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let original = Data("unreadable existing recovery".utf8)
        try original.write(to: CaptureDraftStore.url(in: vault))
        let key = CaptureDraftStore.recoveryKey(for: file, in: vault)
        defer {
            ThoughtDraftCheckpoint.enqueue(key: key, required: false, operation: {})
            _ = ThoughtDraftCheckpoint.flush()
        }
        let draft = CaptureDraft(file: file, text: "new unsaved thought")
        CaptureDraftStore.checkpoint(draft, in: vault)
        XCTAssertNotNil(ThoughtDraftCheckpoint.flush(key: key))
        XCTAssertFalse(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertEqual(try Data(contentsOf: CaptureDraftStore.url(in: vault)), original)
        try FileManager.default.moveItem(at: CaptureDraftStore.url(in: vault),
                                        to: vault.stateDir.appendingPathComponent("preserved-original"))
        CaptureDraftStore.checkpoint(draft, in: vault)
        XCTAssertNil(ThoughtDraftCheckpoint.flush(key: key))
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertEqual(CaptureDraftStore.drafts(in: vault).first?.text, draft.text)
    }

    func testRecoveryPreservesTwoIndependentFailedEditsOnSameFile() throws {
        let vault = try fixture(), file = FileRef(relativePath: "research.md")
        let first = Comment(text: "first unsaved edit"), second = Comment(text: "second unsaved edit")
        CommentEditDraftStore.checkpoint(first, for: file, in: vault)
        CommentEditDraftStore.checkpoint(second, for: file, in: vault)
        XCTAssertTrue(ThoughtDraftCheckpoint.flush().isEmpty)
        XCTAssertEqual(try CommentEditDraftStore.draft(for: file, in: vault), second)
        try CommentEditDraftStore.removeIfMatching(second, for: file, in: vault)
        XCTAssertEqual(try CommentEditDraftStore.draft(for: file, in: vault), first)
    }

    @MainActor
    func testNativeTextMutationReportsDraftBeforeAnotherAppEventCanTerminate() {
        let model = ThoughtEditorModel()
        var captured = ""
        model.onTextChange = { captured = $0 }
        model.text = "last keystroke before command-Q"
        XCTAssertEqual(captured, model.text)
    }
}
