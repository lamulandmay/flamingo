import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

final class TilePanelsPureTests: XCTestCase {
    private func space(window: CGFloat, sidebar: CGFloat = 241, inspector: CGFloat = 321) -> TilePanels.Space {
        TilePanels.Space(window: window, ribbon: 45, sidebar: sidebar, inspector: inspector)
    }

    func testNeededWidthIsColumnsPlusGaps() {
        XCTAssertEqual(TilePanels.needed(.halves), 521)
        XCTAssertEqual(TilePanels.needed(.thirds), 782)
        XCTAssertEqual(TilePanels.needed(.mainPlusStack), 521)
        XCTAssertEqual(TilePanels.needed(.grid), 521)
    }

    func testNothingFoldsWhenThereIsRoom() {
        XCTAssertTrue(TilePanels.hide(for: .halves, space(window: 1600)).isEmpty)
        XCTAssertTrue(TilePanels.hide(for: .single, space(window: 600)).isEmpty, "one column is never squeezed")
    }

    func testTheInspectorFoldsFirst() {
        // 1200 − 45 − 241 − 321 = 593: halves fit, thirds (782) don't, and the inspector's 321 is enough.
        XCTAssertTrue(TilePanels.hide(for: .halves, space(window: 1200)).isEmpty)
        XCTAssertEqual(TilePanels.hide(for: .thirds, space(window: 1200)), [.inspector])
    }

    func testTheSidebarFoldsOnlyIfTheInspectorIsNotEnough() {
        // 1000 − 45 − 241 − 321 = 393; without the inspector 714 < 782.
        XCTAssertEqual(TilePanels.hide(for: .thirds, space(window: 1000)), [.inspector, .sidebar])
        XCTAssertEqual(TilePanels.hide(for: .halves, space(window: 1000)), [.inspector])
    }

    func testOnlyShownPanelsAreFolded() {
        XCTAssertEqual(TilePanels.hide(for: .thirds, space(window: 1000, inspector: 0)), [.sidebar])
        XCTAssertEqual(TilePanels.hide(for: .thirds, space(window: 700, sidebar: 0, inspector: 0)), [])
    }

    func testRestoreBringsBackExactlyWhatWasFoldedWhenThereIsRoom() {
        let hidden: [TilePanel: CGFloat] = [.inspector: 321, .sidebar: 241]
        // Back to single in a 1000 window with both folded: content 955; both fit.
        XCTAssertEqual(TilePanels.restore(hidden, for: .single, space(window: 1000, sidebar: 0, inspector: 0)), [.sidebar, .inspector])
    }

    func testRestoreHoldsBackAPanelThatWouldSqueezeTheLayout() {
        let hidden: [TilePanel: CGFloat] = [.inspector: 321]
        // Thirds in 1200 with the inspector folded: content 914; restoring leaves 593 < 782.
        XCTAssertTrue(TilePanels.restore(hidden, for: .thirds, space(window: 1200, inspector: 0)).isEmpty)
        // Halves needs 521; 914 − 321 = 593 fits.
        XCTAssertEqual(TilePanels.restore(hidden, for: .halves, space(window: 1200, inspector: 0)), [.inspector])
    }

    func testRestoreNeverInventsPanels() {
        XCTAssertTrue(TilePanels.restore([:], for: .single, space(window: 1600, sidebar: 0, inspector: 0)).isEmpty)
    }

    func testPickerDimsOnlyWhatEvenBothPanelsFoldedCannotReach() {
        XCTAssertTrue(TilePanels.reachable(.thirds, window: 1000, ribbon: 45))   // 955 ≥ 782
        XCTAssertFalse(TilePanels.reachable(.thirds, window: 800, ribbon: 45))   // 755 < 782
        XCTAssertTrue(TilePanels.reachable(.halves, window: 800, ribbon: 45))
        XCTAssertTrue(TilePanels.reachable(.single, window: 300, ribbon: 45))
    }
}

@MainActor
final class TilePanelsWorkspaceTests: XCTestCase {
    private func withState(_ body: (AppState) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-PanelTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("a.md"))
        let keys = ["lastVault", "recentVaults", "railVisible", "sidebarCollapsed", "tileAutoHidden"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        UserDefaults.standard.removeObject(forKey: "tileAutoHidden")
        let state = AppState(); state.open(root); state.session?.stop()
        state.railVisible = true; state.sidebarCollapsed = false; state.windowWidth = 1200
        state.select(FileRef(relativePath: "a.md"), source: .other)
        defer {
            state.selected = nil
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for prefix in ["workspace.", "vault.selected.", "vault.expanded.", "vault.foldedBookmarks."] {
                UserDefaults.standard.removeObject(forKey: prefix + root.path)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(state)
    }

    func testThreeColumnsFoldTheInspectorAndSingleBringsItBack() throws {
        try withState { state in
            state.setLayout(.thirds)
            XCTAssertFalse(state.railShown)
            XCTAssertTrue(state.sidebarCollapsed == false)
            XCTAssertEqual(Set(state.tiling.autoHidden.keys), [.inspector])
            state.setLayout(.single)
            XCTAssertTrue(state.railShown)
            XCTAssertTrue(state.tiling.autoHidden.isEmpty)
        }
    }

    func testAPanelTheUserHidIsNeverRestored() throws {
        try withState { state in
            state.railVisible = false
            state.setLayout(.thirds)
            XCTAssertTrue(state.tiling.autoHidden.isEmpty, "nothing was auto-hidden")
            state.setLayout(.single)
            XCTAssertFalse(state.railVisible)
        }
    }

    func testReopeningAPanelByHandForgetsTheAutoHide() throws {
        try withState { state in
            state.setLayout(.thirds)
            XCTAssertFalse(state.railVisible)
            state.toggleRail()
            XCTAssertTrue(state.railVisible)
            XCTAssertNil(state.tiling.autoHidden[.inspector])
            state.setLayout(.single)
            XCTAssertTrue(state.railVisible)
            state.toggleRail()
            state.setLayout(.halves)
            state.setLayout(.single)
            XCTAssertFalse(state.railVisible, "the user hid it; it stays hidden")
        }
    }

    func testANarrowWindowFoldsBothAndWideningBringsThemBack() throws {
        try withState { state in
            state.windowWidth = 1000
            state.setLayout(.thirds)
            XCTAssertFalse(state.railShown); XCTAssertTrue(state.sidebarCollapsed)
            state.setLayout(.single)
            XCTAssertTrue(state.railShown); XCTAssertFalse(state.sidebarCollapsed)
        }
    }

    func testResizingNarrowerFoldsAndWiderRestores() throws {
        try withState { state in
            state.windowWidth = 1600
            state.setLayout(.thirds)
            XCTAssertTrue(state.railShown, "1600 has room")
            state.windowWidth = 1100
            XCTAssertFalse(state.railShown)
            state.windowWidth = 1600
            XCTAssertTrue(state.railShown)
        }
    }

    func testUndoBringsBackTheLayoutAndThePanels() throws {
        try withState { state in
            state.setLayout(.thirds)
            XCTAssertFalse(state.railVisible)
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.tiling.arrangement.kind, .single)
            XCTAssertTrue(state.railVisible)
            XCTAssertTrue(state.tiling.autoHidden.isEmpty)
            XCTAssertTrue(try state.actionHistory.redo())
            XCTAssertEqual(state.tiling.arrangement.kind, .thirds)
            XCTAssertFalse(state.railVisible)
            XCTAssertEqual(Set(state.tiling.autoHidden.keys), [.inspector])
        }
    }
}
