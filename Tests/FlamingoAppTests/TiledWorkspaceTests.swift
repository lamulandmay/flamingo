import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

@MainActor
final class TiledWorkspaceTests: XCTestCase {
    private func line(_ n: Int) -> FileAnchor { FileAnchor(kind: .line, value: String(n)) }
    private let names = ["a.md", "b.md", "c.md", "d.md", "e.md"]

    private func withState(_ body: (AppState, [URL]) throws -> Void) throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-TileTests-" + UUID().uuidString)
        let roots = [base.appendingPathComponent("A"), base.appendingPathComponent("B")]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for file in names { try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent(file)) }
        }
        let keys = ["lastVault", "recentVaults"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        let state = AppState(); state.open(roots[0]); state.session?.stop()
        defer {
            state.selected = nil; state.session?.stop()
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for root in roots {
                for prefix in ["workspace.", "vault.selected.", "vault.expanded.", "vault.foldedBookmarks."] {
                    UserDefaults.standard.removeObject(forKey: prefix + root.path)
                }
            }
            try? FileManager.default.removeItem(at: base)
        }
        try body(state, roots)
    }

    func testLegacySnapshotDecodesWithoutSplitState() throws {
        let json = #"{"mode":0,"anchors":{},"openFiles":[],"history":{"places":[],"index":-1}}"#
        XCTAssertNil(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8)).split)
    }

    func testALegacySplitWithoutTilesRestoresToHalves() throws {
        try withState { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            let legacy = #"{"visible":true,"activePane":"secondary","primary":{"file":{"relativePath":"a.md"},"anchors":{},"readSource":false},"secondary":{"file":{"relativePath":"b.md"},"anchors":{},"readSource":false}}"#
            let split = try JSONDecoder().decode(SavedSplitWorkspace.self, from: Data(legacy.utf8))
            XCTAssertNil(split.tiles)
            state.restoreSplit(split, in: Vault(root: roots[0]))
            XCTAssertEqual(state.tiling.arrangement.kind, .halves)
            XCTAssertEqual(state.tiling.arrangement.visible, [.primary, .secondary])
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.secondaryPane.file, b)
            XCTAssertEqual(state.activePaneID, .secondary)
            let hidden = try JSONDecoder().decode(SavedSplitWorkspace.self, from: Data(legacy.replacingOccurrences(of: "\"visible\":true", with: "\"visible\":false").utf8))
            state.restoreSplit(hidden, in: Vault(root: roots[0]))
            XCTAssertEqual(state.tiling.arrangement.kind, .single); XCTAssertEqual(state.activePaneID, .primary)
        }
    }

    func testSnapshotsWriteLegacyFieldsAnOlderBuildCanRead() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md")
            state.select(a, anchor: line(3), source: .other)
            state.setLayout(.thirds)
            state.open(b, inPane: .secondary, anchor: line(5))
            state.open(c, inPane: .third, anchor: line(7))
            XCTAssertEqual(state.activePaneID, .third)
            let split = state.savedSplit()
            XCTAssertEqual(split.activePane, .primary, "slots 2 and up have no legacy name")
            XCTAssertTrue(split.visible)
            XCTAssertEqual(split.primary.file, a); XCTAssertEqual(split.secondary.file, b)
            // The two-pane struct an older build used.
            struct OldSplit: Codable { var visible: Bool; var activePane: OldID; var primary: SavedDocumentPane; var secondary: SavedDocumentPane }
            enum OldID: String, Codable { case primary, secondary }
            let data = try JSONEncoder().encode(split)
            let old = try JSONDecoder().decode(OldSplit.self, from: data)
            XCTAssertEqual(old.primary.file, a); XCTAssertEqual(old.secondary.file, b); XCTAssertTrue(old.visible)
            let back = try JSONDecoder().decode(SavedSplitWorkspace.self, from: data)
            XCTAssertEqual(back.tiles?.layout, .thirds); XCTAssertEqual(back.tiles?.active, .third)
        }
    }

    func testAnUnknownLayoutFallsBackToTheLegacyFields() throws {
        let json = #"{"visible":true,"activePane":"primary","primary":{"anchors":{},"readSource":false},"secondary":{"anchors":{},"readSource":false},"tiles":{"layout":"hexagons","order":[],"active":"primary","panes":[]}}"#
        let split = try JSONDecoder().decode(SavedSplitWorkspace.self, from: Data(json.utf8))
        XCTAssertNil(split.tiles)
        XCTAssertTrue(split.visible)
    }

    func testPanesAndLayoutComeBackWhenTheVaultReopens() throws {
        try withState { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md")
            state.select(a, anchor: line(2), source: .other)
            state.setLayout(.mainPlusStack)
            state.open(b, inPane: .secondary, anchor: line(4))
            state.open(c, inPane: .third, anchor: line(6))
            state.open(roots[1]); state.session?.stop()
            XCTAssertFalse(state.splitVisible)
            state.open(roots[0]); state.session?.stop()
            XCTAssertEqual(state.tiling.arrangement.kind, .mainPlusStack)
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.secondaryPane.file, b); XCTAssertEqual(state.pane(.third).file, c)
            XCTAssertEqual(state.activePaneID, .third)
            XCTAssertEqual(state.selected, c); XCTAssertEqual(state.anchor, line(6))
        }
    }

    func testSettingAThreePaneLayoutRevealsTwoLaunchersAndFocusesTheFirst() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md")
            state.select(a, source: .other)
            state.setLayout(.thirds)
            XCTAssertEqual(state.tiling.arrangement.visible, [.primary, .secondary, .third])
            XCTAssertEqual(state.primaryPane.file, a)
            XCTAssertNil(state.secondaryPane.file); XCTAssertNil(state.pane(.third).file)
            XCTAssertEqual(state.activePaneID, .secondary)
            XCTAssertNil(state.selected, "an empty pane selects nothing")
            XCTAssertTrue(state.splitVisible)
        }
    }

    func testARevealedPaneStartsEmptyEvenIfItHeldSomethingBefore() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, source: .other)
            state.openBeside(b)
            state.setLayout(.single, from: .primary)
            XCTAssertEqual(state.secondaryPane.file, b, "hidden panes keep their document")
            state.setLayout(.thirds)
            XCTAssertNil(state.secondaryPane.file, "a larger layout opens its new tiles as launchers")
            state.undoAction()
            XCTAssertEqual(state.tiling.arrangement.kind, .single)
            XCTAssertEqual(state.secondaryPane.file, b, "undo brings back what was hidden")
        }
    }

    func testLayoutChangeUndoesAndRedoesWithFileAndAnchor() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(3), source: .other)
            state.openBeside(b, anchor: line(9))
            state.setLayout(.thirds)
            XCTAssertEqual(state.tiling.arrangement.kind, .thirds)
            XCTAssertEqual(state.activePaneID, .third)
            XCTAssertTrue(try state.actionHistory.undo())
            XCTAssertEqual(state.tiling.arrangement.kind, .halves)
            XCTAssertEqual(state.activePaneID, .secondary)
            XCTAssertEqual(state.selected, b); XCTAssertEqual(state.anchor, line(9))
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.primaryPane.anchor, line(3))
            XCTAssertTrue(try state.actionHistory.redo())
            XCTAssertEqual(state.tiling.arrangement.kind, .thirds)
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.secondaryPane.file, b)
        }
    }

    func testClosingTheMiddleOfThreeGivesHalvesWithFocusOnThePreviousSlot() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md")
            state.select(a, source: .other)
            state.setLayout(.thirds)
            state.open(b, inPane: .secondary)
            state.open(c, inPane: .third)
            state.activatePane(.secondary)
            state.closePane(.secondary)
            XCTAssertEqual(state.tiling.arrangement.kind, .halves)
            XCTAssertEqual(state.tiling.arrangement.visible, [.primary, .third])
            XCTAssertEqual(state.activePaneID, .primary)
            XCTAssertEqual(state.selected, a)
            XCTAssertNil(state.secondaryPane.file)
            XCTAssertEqual(state.pane(.third).file, c, "the others keep their documents")
            XCTAssertFalse(state.openFiles.contains(b), "the closed pane's tab closes with it")
            XCTAssertTrue(state.openFiles.contains(c))
        }
    }

    func testClosingAnEmptyLauncherKeepsTabsAndCollapses() throws {
        try withState { state, _ in
            state.select(FileRef(relativePath: "a.md"), source: .other)
            state.setLayout(.thirds)
            let tabs = state.openFiles
            XCTAssertEqual(state.activePaneID, .secondary)
            state.closeCurrentDocument()
            XCTAssertEqual(state.tiling.arrangement.kind, .halves)
            XCTAssertEqual(state.openFiles, tabs)
            XCTAssertEqual(state.activePaneID, .primary)
        }
    }

    func testClosingTheFirstPaneFocusesTheNewFirstSlot() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, source: .other)
            state.openBeside(b)
            state.closePane(.primary)
            XCTAssertEqual(state.tiling.arrangement.kind, .single)
            XCTAssertEqual(state.tiling.arrangement.visible, [.secondary])
            XCTAssertEqual(state.activePaneID, .secondary)
            XCTAssertEqual(state.selected, b)
        }
    }

    func testOpenInPaneLeavesTheOtherPanesAlone() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md")
            state.select(a, anchor: line(4), source: .other)
            state.setLayout(.grid)
            state.open(b, inPane: .third, anchor: line(8))
            XCTAssertEqual(state.activePaneID, .third)
            XCTAssertEqual(state.pane(.third).file, b); XCTAssertEqual(state.anchor, line(8))
            XCTAssertEqual(state.primaryPane.file, a); XCTAssertEqual(state.primaryPane.anchor, line(4))
            XCTAssertNil(state.secondaryPane.file); XCTAssertNil(state.pane(.fourth).file)
            state.open(c, inPane: .fourth)
            XCTAssertEqual(state.pane(.third).file, b)
            XCTAssertEqual(state.pane(.fourth).file, c)
        }
    }

    func testOpenBesideFillsTheFirstEmptyPaneThenTheNextOne() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md")
            state.select(a, source: .other)
            state.setLayout(.thirds)
            state.activatePane(.primary)
            state.openBeside(b)
            XCTAssertEqual(state.secondaryPane.file, b, "the first empty pane")
            state.activatePane(.primary)
            state.openBeside(c)
            XCTAssertEqual(state.pane(.third).file, c)
            state.activatePane(.primary)
            state.openBeside(FileRef(relativePath: "d.md"))
            XCTAssertEqual(state.secondaryPane.file?.relativePath, "d.md", "no empty pane: the next one")
        }
    }

    func testRenameAndTrashReachThePanesBeyondTheSecond() throws {
        try withState { state, roots in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md"), c = FileRef(relativePath: "c.md"), d = FileRef(relativePath: "d.md")
            state.select(a, source: .other)
            state.setLayout(.grid)
            state.open(b, inPane: .secondary)
            state.open(c, inPane: .third, anchor: line(5))
            state.open(d, inPane: .fourth)
            state.activatePane(.primary)
            XCTAssertTrue(state.rename(c.relativePath, to: "renamed.md"))
            let moved = FileRef(relativePath: "renamed.md")
            XCTAssertEqual(state.pane(.third).file, moved)
            XCTAssertEqual(state.pane(.third).anchor, line(5))
            // Hidden panes follow too.
            state.setLayout(.single)
            XCTAssertTrue(state.rename(d.relativePath, to: "renamed-d.md"))
            XCTAssertEqual(state.pane(.fourth).file, FileRef(relativePath: "renamed-d.md"))
            let target = try FileTrash.inspect(b.relativePath, in: Vault(root: roots[0]))
            XCTAssertTrue(state.trash(target, confirmed: true) { try FileManager.default.moveItem(at: $0, to: roots[0].appendingPathComponent("trashed.md")) })
            XCTAssertNil(state.secondaryPane.file)
        }
    }

    func testRevealFocusesTheThirdPaneThatAlreadyShowsTheFile() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, source: .other)
            state.setLayout(.thirds)
            state.open(b, inPane: .third)
            state.activatePane(.primary)
            state.reveal(b)
            XCTAssertEqual(state.activePaneID, .third)
            XCTAssertEqual(state.selected, b)
            XCTAssertEqual(state.primaryPane.file, a)
        }
    }

    func testFocusStepsAroundTheVisiblePanes() throws {
        try withState { state, _ in
            state.select(FileRef(relativePath: "a.md"), source: .other)
            state.focusPane(step: 1)
            XCTAssertEqual(state.activePaneID, .primary, "one pane: nothing to step to")
            state.setLayout(.thirds)
            state.activatePane(.primary)
            state.focusPane(step: 1); XCTAssertEqual(state.activePaneID, .secondary)
            state.focusPane(step: 1); XCTAssertEqual(state.activePaneID, .third)
            state.focusPane(step: 1); XCTAssertEqual(state.activePaneID, .primary)
            state.focusPane(step: -1); XCTAssertEqual(state.activePaneID, .third)
        }
    }

    func testToggleSplitStillRoundTripsThroughTheFirstSlot() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md")
            state.select(a, anchor: line(2), source: .other)
            state.toggleSplit()
            XCTAssertEqual(state.tiling.arrangement.kind, .halves)
            XCTAssertEqual(state.secondaryPane.file, a); XCTAssertEqual(state.secondaryPane.anchor, line(2))
            state.setLayout(.grid)
            state.toggleSplit()
            XCTAssertEqual(state.tiling.arrangement.kind, .single, "⌘\\ from any tiled layout goes back to one pane")
            XCTAssertEqual(state.activePaneID, .primary)
        }
    }

    func testShrinkingFromAHiddenSlotKeepsThatPaneActive() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, source: .other)
            state.setLayout(.thirds)
            state.open(b, inPane: .third)
            state.setLayout(.halves, from: .third)
            XCTAssertEqual(state.tiling.arrangement.visible, [.primary, .third])
            XCTAssertEqual(state.activePaneID, .third)
            XCTAssertEqual(state.selected, b)
        }
    }
}
