import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

final class FileTrashTests: XCTestCase {
    func testRootRestoreAndRedoRejectsReplacementFile() throws {
        try withVault { vault in
            let fm = FileManager.default
            let url = vault.root.appendingPathComponent("note.md")
            try Data("original".utf8).write(to: url)
            let target = try FileTrash.inspect("note.md", in: vault)
            let trash = vault.root.appendingPathComponent("test-trash.md")
            try fm.moveItem(at: url, to: trash)
            let receipt = try FileTrash.Receipt(target: target, trashURL: trash)
            try receipt.restore()
            XCTAssertEqual(try String(contentsOf: url), "original")
            XCTAssertEqual(try receipt.inspectRestored().inode, target.inode)
            try fm.moveItem(at: url, to: vault.root.appendingPathComponent("original.md"))
            try Data("replacement".utf8).write(to: url)
            XCTAssertThrowsError(try receipt.inspectRestored())
        }
    }

    func testOnlyActuallyEmptyFoldersBypassConfirmation() throws {
        try withVault { vault in
            let fm = FileManager.default
            for path in ["empty", "hidden", "nested/child", "Empty.app"] {
                try fm.createDirectory(at: vault.root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data().write(to: vault.root.appendingPathComponent("zero.txt"))
            try Data().write(to: vault.root.appendingPathComponent("hidden/.DS_Store"))
            for path in ["zero.txt", "hidden", "nested", "Empty.app"] {
                let target = try FileTrash.inspect(path, in: vault)
                XCTAssertFalse(target.isEmptyFolder, path)
                XCTAssertThrowsError(try FileTrash.move(target, confirmed: false) { _ in XCTFail("Unconfirmed move: " + path) })
                var moved = false
                try FileTrash.move(target, confirmed: true) { _ in moved = true }
                XCTAssertTrue(moved)
            }
            let empty = try FileTrash.inspect("empty", in: vault)
            XCTAssertTrue(empty.isEmptyFolder)
            var moved = false
            try FileTrash.move(empty, confirmed: false) { _ in moved = true }
            XCTAssertTrue(moved)
        }
    }

    func testNewContentsAndReplacementRequireFreshAuthorization() throws {
        try withVault { vault in
            let fm = FileManager.default
            let url = vault.root.appendingPathComponent("folder")
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            let empty = try FileTrash.inspect("folder", in: vault)
            try Data("new content".utf8).write(to: url.appendingPathComponent("note.md"))
            XCTAssertThrowsError(try FileTrash.move(empty, confirmed: false) { _ in XCTFail("Folder acquired contents") })
            try fm.moveItem(at: url, to: vault.root.appendingPathComponent("old-folder"))
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertThrowsError(try FileTrash.move(empty, confirmed: true) { _ in XCTFail("Replacement was never confirmed") })
        }
    }

    func testRootStateTraversalAndSymlinkAncestorsAreProtected() throws {
        try withVault { vault in
            let fm = FileManager.default
            try fm.createDirectory(at: vault.stateDir, withIntermediateDirectories: false)
            for path in ["", ".", "..", "../outside", "/tmp", ".flamingo", ".flamingo/notes", "folder/../other"] {
                XCTAssertThrowsError(try FileTrash.inspect(path, in: vault), path)
            }
            try fm.createSymbolicLink(at: vault.root.appendingPathComponent("outside"), withDestinationURL: vault.root.deletingLastPathComponent())
            XCTAssertThrowsError(try FileTrash.inspect("outside/other", in: vault))
            let link = try FileTrash.inspect("outside", in: vault)
            XCTAssertFalse(link.isEmptyFolder)
            XCTAssertThrowsError(try FileTrash.move(link, confirmed: false) { _ in XCTFail("Symlink must be confirmed") })
        }
    }

    @MainActor
    func testFailedTrashPreservesWorkspaceAndSuccessfulTrashRetiresOnlyAffectedPaths() throws {
        try withState { state, vault in
            let fm = FileManager.default
            let inside = FileRef(relativePath: "folder/note.md"), sibling = FileRef(relativePath: "folderish.md")
            try fm.createDirectory(at: vault.root.appendingPathComponent("folder"), withIntermediateDirectories: false)
            try Data("note".utf8).write(to: vault.url(for: inside))
            try Data("sibling".utf8).write(to: vault.url(for: sibling))
            state.open(vault.root); state.session?.stop()
            state.select(sibling, source: .other)
            state.select(inside, source: .other)
            state.savedAnchors[inside.relativePath] = FileAnchor(kind: .line, value: "1")
            state.trackedEditorFiles = [inside, sibling]
            let target = try FileTrash.inspect("folder", in: vault)
            XCTAssertFalse(state.trash(target, confirmed: true) { _ in throw CocoaError(.fileWriteNoPermission) })
            XCTAssertEqual(state.selected, inside)
            XCTAssertTrue(state.openFiles.contains(inside))
            XCTAssertTrue(vault.exists(inside))
            let quarantine = vault.root.appendingPathComponent("test-trash")
            XCTAssertTrue(state.trash(target, confirmed: true) { try fm.moveItem(at: $0, to: quarantine) })
            XCTAssertNil(state.selected)
            XCTAssertEqual(state.openFiles, [sibling])
            XCTAssertEqual(state.trackedEditorFiles, [sibling])
            XCTAssertNil(state.savedAnchors[inside.relativePath])
            XCTAssertFalse(state.history.entries.contains { $0.file == inside })
            XCTAssertTrue(fm.fileExists(atPath: quarantine.appendingPathComponent("note.md").path))
        }
    }

    @MainActor
    func testSavingBufferPreventsTrashAndDirtyDraftIsPreserved() throws {
        try withState { state, vault in
            let file = FileRef(relativePath: "note.md")
            try Data("saved".utf8).write(to: vault.url(for: file))
            state.open(vault.root); state.session?.stop()
            let buffer = TextBuffer(file: file, vault: vault, draftDirectory: vault.stateDir.appendingPathComponent("test-drafts"))
            buffer.loaded = true
            buffer.changed("unsaved edits")
            state.textBuffers[file.relativePath] = buffer
            let target = try FileTrash.inspect(file.relativePath, in: vault)
            buffer.saving = true
            XCTAssertFalse(state.trash(target, confirmed: true) { _ in XCTFail("Save still running") })
            buffer.saving = false
            XCTAssertTrue(state.trash(target, confirmed: true) {
                try FileManager.default.moveItem(at: $0, to: vault.root.appendingPathComponent("test-trash.md"))
            })
            let recovered = try JSONDecoder().decode(TextBuffer.Draft.self, from: Data(contentsOf: buffer.draftURL))
            XCTAssertEqual(recovered.text, "unsaved edits")
            XCTAssertNil(state.textBuffers[file.relativePath])
        }
    }

    private func withVault(_ body: (Vault) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-TrashTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(Vault(root: root))
    }

    @MainActor
    private func withState(_ body: (AppState, Vault) throws -> Void) throws {
        _ = NSApplication.shared
        try withVault { vault in
            let defaults = UserDefaults.standard
            let keys = ["lastVault", "recentVaults", "workspace." + vault.root.path, "vault.selected." + vault.root.path]
            let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
            let state = AppState()
            defer {
                state.selected = nil; state.session?.stop()
                for key in keys {
                    if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            try body(state, vault)
        }
    }
}
