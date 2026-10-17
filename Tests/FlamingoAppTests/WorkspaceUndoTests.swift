import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

@MainActor
final class WorkspaceUndoTests: XCTestCase {
    private final class TestClock {
        var time: TimeInterval = 100
    }

    func testBookmarkAddRenameRemoveUndoPreservesOrderWithoutTimeout() async throws {
        try await withState { state, vault, clock in
            state.open(vault.root); state.session?.stop()
            let first = Bookmark(kind: .file, ctime: 1, path: "a.md")
            let second = Bookmark(kind: .file, ctime: 2, path: "b.md")
            let third = Bookmark(kind: .file, ctime: 3, path: "c.md")
            state.addBookmark(first); state.addBookmark(second); state.addBookmark(third)
            state.renameBookmark(ctime: second.ctime, to: "Second")
            state.removeBookmark(at: [0])
            clock.time += 86_400
            XCTAssertEqual(state.bookmarks.items.map(\.displayName), ["Second", "c.md"])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.bookmarks.items.map(\.displayName), ["a.md", "Second", "c.md"])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.bookmarks.items, [first, second, third])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.bookmarks.items, [first, second])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.bookmarks.items, [first])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertTrue(state.bookmarks.items.isEmpty)
            for _ in 0..<5 { XCTAssertTrue(try state.actionHistory.redo()) }
            XCTAssertEqual(state.bookmarks.items.map(\.displayName), ["Second", "c.md"])
            XCTAssertEqual(try Bookmarks.loadChecked(in: vault), state.bookmarks)
        }
    }

    func testDeletionRestoresBeforeDeadlineAndRedoKeepsOriginalDeadline() async throws {
        try await withState { state, vault, clock in
            let file = try self.write("note.md", text: "original", in: vault)
            state.open(vault.root); state.session?.stop()
            state.select(file, source: .other)
            state.actionHistory.clear()
            XCTAssertTrue(try self.trash(file, in: state, vault: vault))
            XCTAssertFalse(vault.exists(file))
            clock.time = 109.999
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "original")
            XCTAssertEqual(state.selected, file)
            XCTAssertTrue(state.openFiles.contains(file))
            XCTAssertTrue(try state.actionHistory.redo())
            XCTAssertFalse(vault.exists(file))
            clock.time = 110
            XCTAssertFalse(try state.actionHistory.undo())
            XCTAssertFalse(vault.exists(file))
        }
    }

    func testDeletionCannotBeRecoveredAtExactlyTenSeconds() async throws {
        try await withState { state, vault, clock in
            let file = try self.write("note.md", text: "original", in: vault)
            state.open(vault.root); state.session?.stop()
            XCTAssertTrue(try self.trash(file, in: state, vault: vault))
            clock.time = 110
            XCTAssertFalse(try state.actionHistory.undo())
            XCTAssertFalse(vault.exists(file))
        }
    }

    func testDeletionRedoExpiresAndLeavesRestoredFileIntact() async throws {
        try await withState { state, vault, clock in
            let file = try self.write("note.md", text: "original", in: vault)
            state.open(vault.root); state.session?.stop()
            XCTAssertTrue(try self.trash(file, in: state, vault: vault))
            clock.time = 101
            XCTAssertTrue(try state.actionHistory.undo())
            clock.time = 110
            XCTAssertFalse(try state.actionHistory.redo())
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "original")
        }
    }

    func testRestoreCollisionPreservesReplacementAndRemainsRetryable() async throws {
        try await withState { state, vault, clock in
            let file = try self.write("note.md", text: "original", in: vault)
            state.open(vault.root); state.session?.stop()
            XCTAssertTrue(try self.trash(file, in: state, vault: vault))
            _ = try self.write(file.relativePath, text: "replacement", in: vault)
            clock.time = 101
            XCTAssertThrowsError(try state.actionHistory.undo())
            XCTAssertTrue(state.actionHistory.canUndo)
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "replacement")
            try FileManager.default.removeItem(at: vault.url(for: file))
            clock.time = 102
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "original")
        }
    }

    func testDeletionRedoRefusesAReplacementAtTheRestoredPath() async throws {
        try await withState { state, vault, _ in
            let file = try self.write("note.md", text: "original", in: vault)
            state.open(vault.root); state.session?.stop()
            XCTAssertTrue(try self.trash(file, in: state, vault: vault))
            XCTAssertTrue(try state.actionHistory.undo())
            try FileManager.default.moveItem(at: vault.url(for: file), to: vault.root.appendingPathComponent("original-kept.md"))
            _ = try self.write(file.relativePath, text: "replacement", in: vault)
            XCTAssertThrowsError(try state.actionHistory.redo())
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "replacement")
            XCTAssertTrue(state.actionHistory.canRedo)
        }
    }

    func testThoughtAddEditDeleteUndoRestoresExactOrderAfterLongDelay() async throws {
        try await withState { state, vault, clock in
            let file = try self.write("note.md", text: "source", in: vault)
            state.open(vault.root); state.session?.stop()
            let store = try XCTUnwrap(state.session?.sidecar)
            for text in ["first", "second", "third"] { try store.append(Comment(text: text), to: file) }
            let original = try store.document(for: file)
            try await state.saveComment(Comment(text: "fourth"), to: file)
            var edited = try store.comments(for: file)[1]
            edited.text = "second edited"
            try await state.saveEditedComment(edited, in: file)
            try await state.saveDeletedComment(try store.comments(for: file)[2], from: file)
            let changed = try store.document(for: file)
            XCTAssertEqual(changed?.comments.map(\.text), ["first", "second edited", "fourth"])
            clock.time += 86_400
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try store.comments(for: file).map(\.text), ["first", "second edited", "third", "fourth"])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try store.comments(for: file).map(\.text), ["first", "second", "third", "fourth"])
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(try store.document(for: file), original)
            for _ in 0..<3 { XCTAssertTrue(try state.actionHistory.redo()) }
            XCTAssertEqual(try store.document(for: file), changed)
            XCTAssertEqual(try String(contentsOf: vault.url(for: file), encoding: .utf8), "source")
        }
    }

    func testRenameUndoRestoresFileAndSidecarThenCanRedo() async throws {
        try await withState { state, vault, clock in
            let original = try self.write("before.md", text: "file bytes", in: vault)
            let renamed = FileRef(relativePath: "after.md")
            state.open(vault.root); state.session?.stop()
            let store = try XCTUnwrap(state.session?.sidecar)
            try store.append(Comment(text: "thought"), to: original)
            let before = try store.document(for: original)
            XCTAssertTrue(state.rename(original.relativePath, to: renamed.name))
            XCTAssertFalse(vault.exists(original))
            XCTAssertEqual(try store.comments(for: renamed).map(\.text), ["thought"])
            clock.time += 86_400
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertTrue(vault.exists(original))
            XCTAssertFalse(vault.exists(renamed))
            XCTAssertEqual(try store.document(for: original), before)
            XCTAssertNil(try store.document(for: renamed))
            XCTAssertTrue(try state.actionHistory.redo())
            XCTAssertTrue(vault.exists(renamed))
            XCTAssertEqual(try String(contentsOf: vault.url(for: renamed), encoding: .utf8), "file bytes")
            XCTAssertEqual(try store.comments(for: renamed).map(\.text), ["thought"])
        }
    }

    func testRenameWithOrphanDestinationThoughtsNeverMergesOrLosesThem() async throws {
        try await withState { state, vault, _ in
            let original = try self.write("before.md", text: "file bytes", in: vault)
            let orphan = FileRef(relativePath: "after.md")
            state.open(vault.root); state.session?.stop()
            let store = try XCTUnwrap(state.session?.sidecar)
            try store.append(Comment(text: "source thought"), to: original)
            try store.append(Comment(text: "orphan thought"), to: orphan)
            let sourceNote = try store.document(for: original)
            let orphanNote = try store.document(for: orphan)
            if state.rename(original.relativePath, to: orphan.name) {
                XCTAssertTrue(try state.actionHistory.undo())
            }
            XCTAssertTrue(vault.exists(original))
            XCTAssertFalse(vault.exists(orphan))
            XCTAssertEqual(try store.document(for: original), sourceNote)
            XCTAssertEqual(try store.document(for: orphan), orphanNote)
        }
    }

    func testRapidRenameUndoLeavesNoStaleContinuityError() async throws {
        try await withState { state, vault, _ in
            let original = try self.write("before.md", text: "file bytes", in: vault)
            let renamed = FileRef(relativePath: "after.md")
            state.open(vault.root); state.session?.stop()
            state.select(original, source: .other)
            state.actionHistory.clear()
            XCTAssertTrue(state.rename(original.relativePath, to: renamed.name))
            XCTAssertTrue(try state.actionHistory.undo())
            // Let the asynchronous indexing follow-ups observe the final filesystem
            // state while the temporary vault still exists.
            for _ in 0..<8 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(state.continuityError)
            XCTAssertEqual(state.selected, original)
            XCTAssertTrue(vault.exists(original))
            XCTAssertFalse(vault.exists(renamed))
            XCTAssertEqual(try String(contentsOf: vault.url(for: original), encoding: .utf8), "file bytes")
        }
    }

    private func write(_ path: String, text: String, in vault: Vault) throws -> FileRef {
        let file = FileRef(relativePath: path)
        try Data(text.utf8).write(to: vault.url(for: file))
        return file
    }

    private func trash(_ file: FileRef, in state: AppState, vault: Vault) throws -> Bool {
        let target = try FileTrash.inspect(file.relativePath, in: vault)
        return state.trash(target, confirmed: true, trashItem: { source in
            let destination = vault.root.appendingPathComponent(".test-trash-" + UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
    }

    private func withState(_ body: (AppState, Vault, TestClock) async throws -> Void) async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Flamingo-WorkspaceUndoTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = Vault(root: root)
        try Bookmarks().save(in: vault)
        let defaults = UserDefaults.standard
        let keys = ["lastVault", "recentVaults", "workspace." + root.path, "vault.selected." + root.path, "automaticAnalysis"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defaults.set(false, forKey: "automaticAnalysis")
        let clock = TestClock()
        let state = AppState(actionHistory: ActionHistory(now: { clock.time }))
        defer {
            state.selected = nil
            state.actionHistory.clear()
            state.session?.stop()
            for key in keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? fm.removeItem(at: root)
        }
        try await body(state, vault, clock)
    }
}
