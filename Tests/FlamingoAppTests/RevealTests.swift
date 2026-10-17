import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

@MainActor
final class RevealTests: XCTestCase {
    private func withState(_ body: (AppState, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-RevealTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["a.md", "b.md", "c.md"] { try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent(file)) }
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
            try? FileManager.default.removeItem(at: root)
        }
        try body(state, root)
    }

    private func line(_ n: Int) -> FileAnchor { FileAnchor(kind: .line, value: String(n)) }

    func testRevealFocusesTheOtherVisiblePaneThatShowsTheFile() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(3), source: .other)
            state.openBeside(b, anchor: line(9))
            XCTAssertEqual(state.activePaneID, .secondary)
            state.reveal(a, anchor: line(1))
            XCTAssertEqual(state.activePaneID, .primary)
            XCTAssertEqual(state.selected, a)
            XCTAssertEqual(state.secondaryPane.file, b, "the other pane is untouched")
        }
    }

    func testRevealOpensInTheActivePaneAtTheRememberedPlace() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md"), b = FileRef(relativePath: "b.md")
            state.select(a, anchor: line(5), source: .other)
            state.select(b, source: .other)
            state.reveal(a, anchor: line(1))
            XCTAssertEqual(state.selected, a)
            XCTAssertEqual(state.anchor, line(5), "the pane's own place wins over the trail's")
        }
    }

    func testRevealUsesTheTrailAnchorOnlyWhenNothingElseIsRemembered() throws {
        try withState { state, _ in
            let c = FileRef(relativePath: "c.md")
            state.reveal(c, anchor: line(2))
            XCTAssertEqual(state.selected, c)
            XCTAssertEqual(state.anchor, line(2))
        }
    }

    func testRevealDropsAFileThatNoLongerExists() throws {
        try withState { state, _ in
            let a = FileRef(relativePath: "a.md")
            state.select(a, source: .other)
            state.reveal(FileRef(relativePath: "gone.md"), anchor: nil)
            XCTAssertEqual(state.selected, a)
        }
    }
}
