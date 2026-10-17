import XCTest
import FlamingoCore
@testable import Flamingo

@MainActor
final class TextSaveUndoTests: XCTestCase {
    private func fixture() throws -> (URL, TextBuffer, ActionHistory) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextUndo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = FileRef(relativePath: "note.md"), vault = Vault(root: root)
        let url = vault.url(for: file)
        try Data("original".utf8).write(to: url)
        let buffer = TextBuffer(file: file, vault: vault, draftDirectory: root.appendingPathComponent("drafts"))
        let history = ActionHistory(); buffer.actionHistory = history
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (url, buffer, history)
    }

    func testSaveUndoRestoresDiskButPreservesDraftAndRedoCommitsAgain() async throws {
        let (url, buffer, history) = try fixture()
        await buffer.load(); buffer.changed("edited")
        await buffer.save()
        XCTAssertEqual(try String(contentsOf: url), "edited")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(try String(contentsOf: url), "original")
        XCTAssertEqual(buffer.text, "edited")
        XCTAssertTrue(buffer.dirty)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(try String(contentsOf: url), "edited")
        XCTAssertFalse(buffer.dirty)
    }

    func testSaveUndoNeverOverwritesExternalEdit() async throws {
        let (url, buffer, history) = try fixture()
        await buffer.load(); buffer.changed("edited"); await buffer.save()
        try Data("external".utf8).write(to: url)
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(try String(contentsOf: url), "external")
        XCTAssertTrue(history.canUndo)
    }

    func testSaveUndoRejectsAReplacementEvenWithIdenticalBytes() async throws {
        let (url, buffer, history) = try fixture()
        await buffer.load(); buffer.changed("edited"); await buffer.save()
        try FileManager.default.removeItem(at: url)
        try Data("edited".utf8).write(to: url)
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(try String(contentsOf: url), "edited")
        XCTAssertTrue(history.canUndo)
    }

    func testReloadUndoRestoresDraftWithoutChangingExternalSource() async throws {
        let (url, buffer, history) = try fixture()
        await buffer.load(); buffer.changed("draft")
        try Data("external".utf8).write(to: url)
        await buffer.reloadDisk()
        XCTAssertEqual(buffer.text, "external")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(buffer.text, "draft")
        XCTAssertTrue(buffer.dirty)
        XCTAssertEqual(try String(contentsOf: url), "external")
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(buffer.text, "external")
        XCTAssertFalse(buffer.dirty)
    }
}
