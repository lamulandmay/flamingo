import AppKit
import PDFKit
import XCTest
import FlamingoCore
@testable import Flamingo

@MainActor
final class SplitWorkspaceTests: XCTestCase {
    func testInactiveLocationAndNavigatorCannotChangeActiveDocument() throws {
        try withWorkspace { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(3), source: .other)
            state.openBeside(b, anchor: line(9))
            let primaryNavigator = Navigator(), secondaryNavigator = Navigator()
            state.primaryPane.navigator = primaryNavigator; state.secondaryPane.navigator = secondaryNavigator
            let jump = state.jumpRequest?.id
            state.primaryPane.anchor = line(17)
            XCTAssertEqual(state.selected, b)
            XCTAssertEqual(state.anchor, line(9))
            XCTAssertEqual(state.history.current?.anchor, line(9))
            XCTAssertEqual(state.jumpRequest?.id, jump)
            state.stepAnchor(1)
            XCTAssertEqual(secondaryNavigator.steps, [1]); XCTAssertTrue(primaryNavigator.steps.isEmpty)
            state.activatePane(.primary)
            XCTAssertEqual(state.selected, a)
            XCTAssertEqual(state.anchor, line(17))
            XCTAssertEqual(state.primaryPane.jumpRequest?.anchor, line(3), "Focus must not reissue the initial text selection")
            state.stepAnchor(-1)
            XCTAssertEqual(primaryNavigator.steps, [-1])
        }
    }

    func testSameFileHasIndependentLocationsAndOneSharedTextBuffer() throws {
        try withWorkspace { state, _ in
            let file = FileRef(relativePath: "a.md")
            state.select(file, anchor: line(2), source: .other)
            let buffer = try XCTUnwrap(state.textBuffer(for: file))
            state.openBeside(file, anchor: line(8))
            XCTAssertTrue(buffer === state.textBuffer(for: file))
            state.primaryPane.anchor = line(4)
            state.secondaryPane.anchor = line(11)
            state.sourceHighlight = "right query"
            state.activatePane(.primary)
            XCTAssertEqual(state.anchor, line(4)); XCTAssertEqual(state.sourceHighlight, "")
            state.sourceHighlight = "left query"
            state.activatePane(.secondary)
            XCTAssertEqual(state.anchor, line(11)); XCTAssertEqual(state.sourceHighlight, "right query")
            state.select(FileRef(relativePath: "b.md"), source: .other)
            state.select(file, source: .other)
            XCTAssertEqual(state.anchor, line(11), "Each pane restores its own location when returning to a file")
        }
    }

    func testPaneLocationsAndFocusRestorePerVault() throws {
        try withWorkspace { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(4), source: .other)
            state.openBeside(a, anchor: line(13))
            state.primaryPane.anchor = line(6)
            state.open(roots[1]); state.session?.stop()
            XCTAssertFalse(state.splitVisible)
            XCTAssertNil(state.selected)
            state.select(b, anchor: line(2), source: .other)
            state.open(roots[0]); state.session?.stop()
            XCTAssertTrue(state.splitVisible)
            XCTAssertEqual(state.activePaneID, .secondary)
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.primaryPane.anchor, line(6))
            XCTAssertEqual(state.secondaryPane.file, a); XCTAssertEqual(state.secondaryPane.anchor, line(13))
            XCTAssertEqual(state.anchor, line(13))
            state.closeSplit()
            XCTAssertEqual(state.activePaneID, .primary)
            XCTAssertEqual(state.anchor, line(6))
            state.toggleSplit()
            XCTAssertEqual(state.secondaryPane.anchor, line(13))
        }
    }

    func testClosingAndTrashingRemoveBothReferencesWithoutLosingOtherPane() throws {
        try withWorkspace { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(4), source: .other)
            state.openBeside(b, anchor: line(6))
            state.closeTab(a)
            XCTAssertNil(state.primaryPane.file)
            XCTAssertEqual(state.secondaryPane.file, b)
            state.activatePane(.primary)
            state.select(a, anchor: line(7), source: .other)
            state.activatePane(.secondary)
            let vault = Vault(root: roots[0])
            let target = try FileTrash.inspect(a.relativePath, in: vault)
            XCTAssertTrue(state.trash(target, confirmed: true) { try FileManager.default.moveItem(at: $0, to: roots[0].appendingPathComponent("trashed.md")) })
            XCTAssertNil(state.primaryPane.file)
            XCTAssertEqual(state.selected, b)
            XCTAssertEqual(state.anchor, line(6))
        }
    }

    func testRenameReconcilesInactivePaneAndItsRememberedLocation() throws {
        try withWorkspace { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(4), source: .other)
            state.openBeside(b, anchor: line(6))
            XCTAssertTrue(state.rename(a.relativePath, to: "renamed.md"))
            let moved = FileRef(relativePath: "renamed.md")
            XCTAssertEqual(state.primaryPane.file, moved)
            XCTAssertEqual(state.primaryPane.anchor, line(4))
            XCTAssertEqual(state.primaryPane.jumpRequest?.file, moved)
            XCTAssertEqual(state.primaryPane.anchors[moved.relativePath], line(4))
            XCTAssertNil(state.primaryPane.anchors[a.relativePath])
            XCTAssertEqual(state.selected, b)
        }
    }

    func testOfflineRenameRestoresEachPaneAnchorAfterIdentityReconciliation() throws {
        try withWorkspace { state, roots in
            let old = FileRef(relativePath: "a.md"), moved = FileRef(relativePath: "renamed.md")
            let vault = Vault(root: roots[0])
            state.select(old, anchor: line(3), source: .other)
            state.openBeside(old, anchor: line(5))
            state.activatePane(.primary)
            state.secondaryPane.anchor = line(12)
            state.activatePane(.secondary)
            state.open(roots[1]); state.session?.stop()
            try FileManager.default.moveItem(at: vault.url(for: old), to: vault.url(for: moved))
            try PathAliases(vault: vault).reconcile(oldPath: old.relativePath, newPath: moved.relativePath)
            state.open(roots[0]); state.session?.stop()
            XCTAssertNil(state.selected)
            // The drained identity outbox has already placed the renamed endpoint in openFiles.
            state.openFiles.append(moved)
            let session = try XCTUnwrap(state.session)
            state.finishWorkspaceRestoration(in: session, indexOutcome: .completed, renamesDrained: true)
            XCTAssertEqual(state.primaryPane.file, moved)
            XCTAssertEqual(state.primaryPane.anchor, line(3))
            XCTAssertEqual(state.secondaryPane.file, moved)
            XCTAssertEqual(state.secondaryPane.anchor, line(12))
            XCTAssertEqual(state.selected, moved)
            XCTAssertEqual(state.anchor, line(12))
        }
    }

    func testLegacySnapshotDecodesWithoutSplitState() throws {
        let json = #"{"mode":0,"anchors":{},"openFiles":[],"history":{"places":[],"index":-1}}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.split)
    }

    func testFocusingSameFilePreservesLoadedCommentsAndSelection() async throws {
        try await withAsyncWorkspace { state, _ in
            let file = FileRef(relativePath: "a.md")
            state.select(file, source: .other)
            try state.session?.sidecar.append(Comment(text: "A thought being edited"), to: file)
            await state.refreshComments()
            let comments = state.comments
            XCTAssertEqual(comments.count, 1)
            state.selectedCommentID = comments.first?.id
            state.toggleSplit()
            state.activatePane(.secondary)
            XCTAssertEqual(state.comments, comments)
            XCTAssertEqual(state.selectedCommentID, comments.first?.id)
        }
    }

    func testRemountedPDFRestoresEachPaneWithoutAnExplicitJumpRequest() throws {
        try withWorkspace { state, roots in
            let file = FileRef(relativePath: "reference.pdf"), url = roots[0].appendingPathComponent("reference.pdf")
            let document = PDFDocument()
            for index in 0..<4 {
                let image = NSImage(size: NSSize(width: 100, height: 100))
                image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); image.unlockFocus()
                document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
            }
            XCTAssertTrue(document.write(to: url))
            state.select(file, source: .other)
            state.toggleSplit()
            state.primaryPane.anchor = .page(2)
            state.secondaryPane.anchor = .page(4)
            XCTAssertNil(state.primaryPane.jumpRequest)
            XCTAssertNil(state.secondaryPane.jumpRequest)
            let left = PDFView(), right = PDFView()
            let leftCoordinator = PDFPreviewCoordinator(), rightCoordinator = PDFPreviewCoordinator()
            leftCoordinator.attach(left, pane: state.primaryPane)
            rightCoordinator.attach(right, pane: state.secondaryPane)
            defer { leftCoordinator.detach(); rightCoordinator.detach() }
            let modified = PreviewKind.modificationDate(of: url)
            leftCoordinator.show(file, url: url, modified: modified, jump: nil)
            rightCoordinator.show(file, url: url, modified: modified, jump: nil)
            XCTAssertEqual(left.currentPage.map { left.document!.index(for: $0) + 1 }, 2)
            XCTAssertEqual(right.currentPage.map { right.document!.index(for: $0) + 1 }, 4)
            XCTAssertEqual(state.anchor, .page(2))
        }
    }

    func testLateMountCannotStealFocusAfterTheUserChoosesOtherPane() async throws {
        try await withAsyncWorkspace { state, _ in
            state.select(FileRef(relativePath: "a.md"), source: .other)
            state.openBeside(FileRef(relativePath: "b.md"))
            state.activatePane(.primary)
            var focusedRight = false
            state.secondaryPane.requestFocus = { focusedRight = true }
            await Task.yield()
            XCTAssertFalse(focusedRight)
            XCTAssertEqual(state.activePaneID, .primary)
        }
    }

    func testDeferredFocusWaitsForMountedNativeView() async throws {
        let pane = DocumentPane(id: .secondary)
        pane.focusWhenReady()
        var focused = false
        pane.requestFocus = { focused = true }
        await Task.yield()
        XCTAssertTrue(focused)
    }

    private func line(_ n: Int) -> FileAnchor { FileAnchor(kind: .line, value: String(n)) }
    private final class Navigator: AnchorNavigator {
        let anchorKind: FileAnchor.Kind = .line
        var steps: [Int] = []
        func step(_ delta: Int) { steps.append(delta) }
        func jump(to anchor: FileAnchor) {}
    }

    private func fixture() throws -> (AppState, [URL], [String: Any]) {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-SplitTests-" + UUID().uuidString)
        let roots = [base.appendingPathComponent("A"), base.appendingPathComponent("B")]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for file in ["a.md", "b.md"] { try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent(file)) }
        }
        let keys = ["lastVault", "recentVaults"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        let state = AppState(); state.open(roots[0]); state.session?.stop()
        return (state, roots, saved)
    }
    private func clean(_ state: AppState, _ roots: [URL], _ saved: [String: Any]) {
        state.selected = nil; state.session?.stop()
        for key in ["lastVault", "recentVaults"] {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for root in roots {
            for prefix in ["workspace.", "vault.selected.", "vault.expanded.", "vault.foldedBookmarks."] {
                UserDefaults.standard.removeObject(forKey: prefix + root.path)
            }
        }
        try? FileManager.default.removeItem(at: roots[0].deletingLastPathComponent())
    }
    private func withWorkspace(_ body: (AppState, [URL]) throws -> Void) throws {
        let (state, roots, saved) = try fixture(); defer { clean(state, roots, saved) }
        try body(state, roots)
    }
    private func withAsyncWorkspace(_ body: (AppState, [URL]) async throws -> Void) async throws {
        let (state, roots, saved) = try fixture(); defer { clean(state, roots, saved) }
        try await body(state, roots)
    }
}
