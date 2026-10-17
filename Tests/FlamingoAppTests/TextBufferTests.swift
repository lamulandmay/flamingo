import XCTest
@testable import Flamingo
import FlamingoCore

@MainActor
final class TextBufferTests: XCTestCase {
    struct Fixture {
        var root: URL
        var vault: Vault
        var file = FileRef(relativePath: "working.md")
        var drafts: URL { root.appendingPathComponent("recovery", isDirectory: true) }
        var url: URL { vault.url(for: file) }
        @MainActor func buffer() -> TextBuffer { TextBuffer(file: file, vault: vault, draftDirectory: drafts) }
    }

    func fixture(_ text: String = "baseline") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-buffer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root, vault: Vault(root: root))
        try Data(text.utf8).write(to: fixture.url)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return fixture
    }

    func testTypingDoesNotWaitForDraftIOAndReopeningFlushesLatestSnapshot() async throws {
        let large = String(repeating: "research line\n", count: 160_000)
        let fixture = try fixture(large), buffer = fixture.buffer()
        await buffer.load()
        let gate = DispatchSemaphore(value: 0)
        buffer.draftWriter.queue.async { _ = gate.wait(timeout: .now() + 0.6) }
        let start = Date()
        buffer.changed(large + "first")
        buffer.changed(large + "latest")
        let elapsed = Date().timeIntervalSince(start)
        gate.signal()
        XCTAssertLessThan(elapsed, 0.25, "Editing must not wait for the serial disk writer")

        // No explicit close needed: a new buffer must read after its predecessor's pending writes.
        let reopened = fixture.buffer()
        await reopened.load()
        XCTAssertEqual(reopened.text, large + "latest")
        XCTAssertTrue(reopened.recovered)
        XCTAssertTrue(reopened.draftBackedUp)
    }

    func testUndoToBaselineRemovesOldDraftBeforeRestart() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        await buffer.load()
        buffer.changed("discarded edit")
        let flushed = await buffer.flushDraft()
        XCTAssertTrue(flushed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.draftURL.path))
        buffer.changed("baseline")
        XCTAssertTrue(buffer.persistDraft(), "The synchronous close/switch hook must flush removal too")
        XCTAssertFalse(buffer.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.draftURL.path))
        let reopened = fixture.buffer()
        await reopened.load()
        XCTAssertEqual(reopened.text, "baseline")
        XCTAssertFalse(reopened.recovered)
    }

    func testSuccessfulSaveCannotResurrectEarlierQueuedDrafts() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        await buffer.load()
        let prefix = String(repeating: "long content ", count: 80_000)
        for i in 0..<30 { buffer.changed(prefix + String(i)) }
        await buffer.save()
        XCTAssertEqual(try String(contentsOf: fixture.url), prefix + "29")
        XCTAssertFalse(buffer.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.draftURL.path))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.draftURL.path))
        XCTAssertFalse(buffer.dirty, "An obsolete completion must not mark a successful save dirty")
    }

    func testNewEditDuringSaveKeepsDraftWithNewDiskBaseline() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        await buffer.load()
        buffer.changed("version being saved")
        let gate = DispatchSemaphore(value: 0)
        buffer.draftWriter.queue.async { _ = gate.wait(timeout: .now() + 2) }
        let save = Task { await buffer.save() }
        let deadline = Date().addingTimeInterval(1)
        while !buffer.saving, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(buffer.saving)
        buffer.changed("newer unsaved edit")
        gate.signal()
        await save.value
        XCTAssertEqual(try String(contentsOf: fixture.url), "version being saved")
        XCTAssertTrue(buffer.dirty)
        let draft = try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: buffer.draftURL))
        XCTAssertEqual(draft.text, "newer unsaved edit")
        XCTAssertEqual(draft.baseline, Data("version being saved".utf8))
        let reopened = fixture.buffer()
        await reopened.load()
        XCTAssertEqual(reopened.text, "newer unsaved edit")
        XCTAssertNil(reopened.error, "A newer edit must be based on the version actually committed")
    }

    func testReloadPreservesRecoveryCopyAndRemovesActiveDraft() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        await buffer.load()
        buffer.changed("thought before reload")
        try Data("external version".utf8).write(to: fixture.url, options: .atomic)
        await buffer.reloadDisk()
        XCTAssertEqual(buffer.text, "external version")
        XCTAssertFalse(buffer.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.draftURL.path))
        let archived = try FileManager.default.contentsOfDirectory(at: fixture.drafts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("recovery-") }
        XCTAssertEqual(archived.count, 1)
        let saved = try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: XCTUnwrap(archived.first)))
        XCTAssertEqual(saved.text, "thought before reload")
    }

    func testMissingSourceStillAllowsRecoveryOfThought() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        await buffer.load()
        buffer.changed("offline draft")
        let flushed = await buffer.flushDraft()
        XCTAssertTrue(flushed)
        try FileManager.default.removeItem(at: fixture.url)
        let reopened = fixture.buffer()
        await reopened.load()
        XCTAssertTrue(reopened.loaded)
        XCTAssertEqual(reopened.text, "offline draft")
        XCTAssertTrue(reopened.recovered)
        XCTAssertNotNil(reopened.error)
    }

    func testUnreadableRecoveryIsPreservedBeforeNewEdits() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        try FileManager.default.createDirectory(at: fixture.drafts, withIntermediateDirectories: true)
        let original = Data("damaged but recoverable original".utf8)
        try original.write(to: buffer.draftURL)
        await buffer.load()
        XCTAssertNotNil(buffer.error)
        buffer.changed("new draft")
        let flushed = await buffer.flushDraft()
        XCTAssertTrue(flushed)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.drafts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: buffer.draftURL)).text, "new draft")
    }

    func testRenameTransfersDraftAndLateEditorCallbacksWithoutSavingSource() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("thought before native rename")
        original.recovered = true
        original.focusRequested = true
        original.error = "An earlier warning"
        var savedCalls = 0
        original.onSaved = { savedCalls += 1 }
        let renamed = FileRef(relativePath: "renamed.md")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.vault.url(for: renamed))

        let moved = try await original.relocated(to: renamed, vault: fixture.vault)
        XCTAssertEqual(moved.file, renamed)
        XCTAssertEqual(moved.text, "thought before native rename")
        XCTAssertTrue(moved.dirty)
        XCTAssertTrue(moved.recovered)
        XCTAssertTrue(moved.focusRequested)
        XCTAssertTrue(moved.draftBackedUp)
        XCTAssertEqual(moved.error, "An earlier warning")
        XCTAssertEqual(savedCalls, 0, "Relocation must not trigger old-path analysis")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.draftURL.path))
        XCTAssertEqual(try String(contentsOf: moved.url), "baseline")
        let draft = try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: moved.draftURL))
        XCTAssertEqual(draft.path, moved.url.path)
        XCTAssertEqual(draft.baseline, Data("baseline".utf8))

        // SwiftUI can still deliver a callback from the retired view during its replacement.
        original.changed("late editor callback")
        XCTAssertTrue(original.persistDraft())
        XCTAssertEqual(moved.text, "late editor callback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.draftURL.path))
        let reopened = TextBuffer(file: renamed, vault: fixture.vault, draftDirectory: fixture.drafts)
        await reopened.load()
        XCTAssertEqual(reopened.text, "late editor callback")
        XCTAssertNil(reopened.error)
    }

    func testRenameKeepsOldRecoveryUntilNewRecoveryAcknowledgedAndIncludesContinuedTyping() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("first draft")
        let backedUp = await original.flushDraft()
        XCTAssertTrue(backedUp)
        let renamed = FileRef(relativePath: "renamed.md")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.vault.url(for: renamed))
        let target = TextBuffer(file: renamed, vault: fixture.vault, draftDirectory: fixture.drafts)
        let gate = DispatchSemaphore(value: 0)
        target.draftWriter.queue.async { _ = gate.wait(timeout: .now() + 2) }
        var finished = false
        let migration = Task { () throws -> TextBuffer in
            let result = try await original.relocated(to: renamed, vault: fixture.vault)
            finished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.draftURL.path))
        original.changed("typed while rename was waiting")
        gate.signal()
        let moved = try await migration.value
        XCTAssertEqual(moved.text, "typed while rename was waiting")
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: moved.draftURL)).text,
                       "typed while rename was waiting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.draftURL.path))
    }

    func testFailedRenameRecoveryRetainsOriginalDraftAndEditor() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("irreplaceable unsaved thought")
        let backedUp = await original.flushDraft()
        XCTAssertTrue(backedUp)
        let renamed = FileRef(relativePath: "renamed.md")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.vault.url(for: renamed))
        let target = TextBuffer(file: renamed, vault: fixture.vault, draftDirectory: fixture.drafts)
        // An incompatible object at the recovery destination makes atomic replacement fail.
        try FileManager.default.createDirectory(at: target.draftURL, withIntermediateDirectories: true)
        do {
            _ = try await original.relocated(to: renamed, vault: fixture.vault)
            XCTFail("A failed recovery write cannot be acknowledged as a completed rename")
        } catch { }
        XCTAssertEqual(original.text, "irreplaceable unsaved thought")
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: original.draftURL)).text,
                       "irreplaceable unsaved thought")
        original.changed("typing after failed relocation")
        XCTAssertTrue(original.persistDraft())
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: original.draftURL)).text,
                       "typing after failed relocation")
    }

    func testRenameWaitsForInFlightSaveAndKeepsItsUnsavedDraft() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("save interrupted by native rename")
        let gate = DispatchSemaphore(value: 0)
        original.draftWriter.queue.async { _ = gate.wait(timeout: .now() + 2) }
        let save = Task { await original.save() }
        let deadline = Date().addingTimeInterval(1)
        while !original.saving, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(original.saving)
        let renamed = FileRef(relativePath: "renamed.md")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.vault.url(for: renamed))
        var finished = false
        let migration = Task { () throws -> TextBuffer in
            let result = try await original.relocated(to: renamed, vault: fixture.vault)
            finished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        gate.signal()
        await save.value
        let moved = try await migration.value
        XCTAssertEqual(moved.text, "save interrupted by native rename")
        XCTAssertTrue(moved.dirty)
        XCTAssertNotNil(moved.error)
        await moved.save()
        XCTAssertEqual(try String(contentsOf: moved.url), "save interrupted by native rename")
        XCTAssertFalse(moved.dirty)
        XCTAssertNil(moved.error)
    }

    func testRenamePreservesExistingRecoveryAtDestinationBeforeReplacingIt() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("current unsaved thought")
        let renamed = FileRef(relativePath: "reused-name.md")
        try FileManager.default.moveItem(at: fixture.url, to: fixture.vault.url(for: renamed))
        let target = TextBuffer(file: renamed, vault: fixture.vault, draftDirectory: fixture.drafts)
        let previous = TextBuffer.Draft(path: target.url.path, text: "older draft at reused filename", baseline: Data())
        try FileManager.default.createDirectory(at: fixture.drafts, withIntermediateDirectories: true)
        let previousData = try JSONEncoder().encode(previous)
        try previousData.write(to: target.draftURL)
        let moved = try await original.relocated(to: renamed, vault: fixture.vault)
        XCTAssertEqual(moved.text, "current unsaved thought")
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.drafts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), previousData)
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: moved.draftURL)).text,
                       "current unsaved thought")
    }

    func testLateCallbacksFollowMultipleRenamesAfterIntermediateBufferIsReleased() async throws {
        let fixture = try fixture(), original = fixture.buffer()
        await original.load()
        original.changed("draft")
        let middleRef = FileRef(relativePath: "middle.md"), finalRef = FileRef(relativePath: "final.md")
        try FileManager.default.moveItem(at: original.url, to: fixture.vault.url(for: middleRef))
        var middle: TextBuffer? = try await original.relocated(to: middleRef, vault: fixture.vault)
        let middleDraftURL = try XCTUnwrap(middle).draftURL
        try FileManager.default.moveItem(at: fixture.vault.url(for: middleRef), to: fixture.vault.url(for: finalRef))
        let final = try await XCTUnwrap(middle).relocated(to: finalRef, vault: fixture.vault)
        middle = nil
        original.changed("last callback from first editor")
        XCTAssertTrue(original.persistDraft())
        XCTAssertEqual(final.text, "last callback from first editor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.draftURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: middleDraftURL.path))
        XCTAssertEqual(try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: final.draftURL)).text,
                       "last callback from first editor")
    }

    func testUnavailableCorruptRecoveryAllowsClosingCleanBufferButProtectsUnsavedEdits() async throws {
        let fixture = try fixture(), buffer = fixture.buffer()
        try FileManager.default.createDirectory(at: fixture.drafts, withIntermediateDirectories: true)
        let corrupt = Data("original unreadable recovery".utf8)
        try corrupt.write(to: buffer.draftURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.drafts.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.drafts.path) }
        await buffer.load()
        XCTAssertNotNil(buffer.error)
        XCTAssertFalse(buffer.dirty)
        XCTAssertTrue(buffer.persistDraft(), "A clean source cannot trap app termination because of unrelated corrupt recovery")
        buffer.changed("new unsaved thought")
        XCTAssertFalse(buffer.persistDraft(), "Unsaved edits must still prevent an unsafe close")
        XCTAssertEqual(try Data(contentsOf: buffer.draftURL), corrupt)
    }
}
