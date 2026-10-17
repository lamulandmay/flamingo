import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

/// The file explorer and the columns share one context menu and one rename, and the
/// explorer follows the columns.
@MainActor
final class FileMenuTests: XCTestCase {
    private func withState(_ body: (AppState, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Flamingo-FileMenuTests-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("finance/2026"), withIntermediateDirectories: true)
        try Data("q3\n".utf8).write(to: root.appendingPathComponent("finance/2026/q3.md"))
        try Data("a\n".utf8).write(to: root.appendingPathComponent("a.md"))
        let keys = ["lastVault", "recentVaults"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        let state = AppState(); state.open(root); state.session?.stop()
        defer {
            state.selected = nil
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for prefix in ["workspace.", "vault.selected.", "vault.expanded.", "vault.foldedBookmarks."] {
                UserDefaults.standard.removeObject(forKey: prefix + root.path)
            }
            try? fm.removeItem(at: root)
        }
        try body(state, ColumnBrowserModel.normal(root))
    }

    private func titles(_ url: URL, folder: Bool, state: AppState, rename: Bool = true) -> [String] {
        let menu = NSMenu()
        FileMenu.build(menu, url: url, isFolder: folder, state: state,
                       host: FileMenu.Host(open: {}, rename: rename ? {} : nil, quickLook: {}, window: nil))
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    func testAVaultFileOffersEverythingEitherListCouldDo() throws {
        try withState { state, root in
            let items = titles(root.appendingPathComponent("a.md"), folder: false, state: state)
            for title in ["Open", "Open Beside", "Quick Look", "Leave a Thought", "Rename…", "Bookmark",
                          "Reveal in Finder", "Copy File", "Copy Path", "Move to Trash"] {
                XCTAssertTrue(items.contains(title), "missing \(title) in \(items)")
            }
            XCTAssertTrue(items.contains { $0.hasPrefix("Open in ") })
        }
    }

    func testAVaultFolderCanTakeNewFilesAndBePinned() throws {
        try withState { state, root in
            let items = titles(root.appendingPathComponent("finance"), folder: true, state: state)
            for title in ["Open", "New File…", "New Note", "New Folder", "Search in Folder", "Rename…", "Pin Folder",
                          "Reveal in Finder", "Copy Folder", "Copy Path", "Move to Trash"] {
                XCTAssertTrue(items.contains(title), "missing \(title) in \(items)")
            }
            XCTAssertFalse(items.contains("Open Beside"))
        }
    }

    func testOutsideTheVaultOnlyTheFinderItemsAndRename() throws {
        try withState { state, _ in
            let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.txt")
            let items = titles(elsewhere, folder: false, state: state)
            XCTAssertTrue(items.contains("Rename…"))
            XCTAssertTrue(items.contains("Reveal in Finder"))
            for title in ["Open Beside", "Leave a Thought", "Bookmark", "Move to Trash"] {
                XCTAssertFalse(items.contains(title), "\(title) needs the vault")
            }
        }
    }

    func testRenameInTheColumnsGoesThroughTheVaultInsideItAndRefusesTheVaultItself() throws {
        try withState { state, root in
            let fm = FileManager.default
            let renamed = state.renameItem(at: root.appendingPathComponent("a.md"), to: "b.md")
            XCTAssertEqual(renamed?.path, root.appendingPathComponent("b.md").path)
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("b.md").path))
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("a.md").path))

            XCTAssertFalse(state.canRename(root))
            XCTAssertFalse(state.canRename(root.deletingLastPathComponent()), "a folder holding the vault")
            XCTAssertFalse(state.canRename(URL(fileURLWithPath: "/")))
            XCTAssertNil(state.renameItem(at: root, to: "other"))
        }
    }

    func testRenameOutsideTheVaultIsAPlainRename() throws {
        try withState { state, _ in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("Flamingo-FileMenuTests-outside-" + UUID().uuidString)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let file = dir.appendingPathComponent("draft.txt")
            try Data().write(to: file)
            try Data().write(to: dir.appendingPathComponent("taken.txt"))
            XCTAssertNil(state.renameItem(at: file, to: "taken.txt"), "never replaces")
            XCTAssertNil(state.renameItem(at: file, to: "a/b"))
            XCTAssertEqual(state.renameItem(at: file, to: " final.txt ")?.lastPathComponent, "final.txt")
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("final.txt").path))
        }
    }

    func testARenameMovesTheColumnsTrailWithIt() {
        let model = ColumnBrowserModel()
        let url = { (path: String) in URL(fileURLWithPath: path) }
        model.follow(url("/v"))
        model.columnsChanged(trail: [url("/v/finance"), url("/v/finance/2026"), url("/v/finance/2026/q3.md")], folder: url("/v/finance/2026"))
        model.renamed(url("/v/finance"), to: url("/v/money"))
        XCTAssertEqual(model.trail.map(\.path), ["/v/money", "/v/money/2026", "/v/money/2026/q3.md"])
        XCTAssertEqual(model.folder?.path, "/v/money/2026")
        XCTAssertEqual(model.root?.path, "/v")
        model.renamed(url("/v/money/2026/q3.md"), to: url("/v/money/2026/q4.md"))
        XCTAssertEqual(model.trail.last?.path, "/v/money/2026/q4.md")
        XCTAssertEqual(model.trail.first?.path, "/v/money", "a sibling's prefix doesn't match")
    }

    func testTheSidebarFollowsTheColumnsWithoutAHistoryEntry() throws {
        try withState { state, root in
            state.mode = .files
            state.select(nil, source: .sidebar)
            let back = state.canGoBack, depth = state.history.entries.count
            state.columnsPicked(item: root.appendingPathComponent("finance/2026/q3.md"),
                                folder: root.appendingPathComponent("finance/2026"))
            XCTAssertEqual(state.selectedFolder, "finance/2026")
            XCTAssertEqual(state.columnsSelection, "finance/2026/q3.md")
            XCTAssertNil(state.selected, "highlighted, not opened")
            XCTAssertEqual(state.history.entries.count, depth)
            XCTAssertEqual(state.canGoBack, back)

            // A place outside the vault leaves the sidebar's folder where it was.
            state.columnsPicked(item: URL(fileURLWithPath: "/Applications/Safari.app"), folder: URL(fileURLWithPath: "/Applications"))
            XCTAssertEqual(state.selectedFolder, "finance/2026")
            XCTAssertNil(state.columnsSelection)

            // The vault's root is the sidebar's top level.
            state.columnsPicked(item: root.appendingPathComponent("a.md"), folder: root)
            XCTAssertNil(state.selectedFolder)
            XCTAssertEqual(state.columnsSelection, "a.md")

            // The sidebar picking for itself takes the highlight back.
            state.selectFromSidebar(folder: "finance", file: nil)
            XCTAssertNil(state.columnsSelection)
            XCTAssertEqual(state.selectedFolder, "finance")
        }
    }

    func testANewFolderMadeWhileTheColumnsShowIsRenamedThere() throws {
        try withState { state, root in
            state.mode = .files
            let style = state.browser.style
            defer { state.browser.style = style }
            state.browser.style = .columns
            state.browser.follow(root)
            state.newFolder(in: "finance")
            XCTAssertEqual(state.renameRequest?.target, "finance/Untitled")
            XCTAssertEqual(state.renameRequest?.inColumns, true)
            state.browser.style = .icons
            state.newFolder(in: "finance")
            XCTAssertEqual(state.renameRequest?.inColumns, false, "the icon view has no rename of its own")
            state.browser.style = .columns
            state.browser.browse(URL(fileURLWithPath: "/Applications"), following: nil)
            state.newFolder(in: "finance")
            XCTAssertEqual(state.renameRequest?.inColumns, false, "the columns won't show a folder outside where they start")
        }
    }
}
