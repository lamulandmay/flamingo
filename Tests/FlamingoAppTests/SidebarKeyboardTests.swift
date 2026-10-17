import AppKit
import XCTest
@testable import Flamingo

final class SidebarKeyboardTests: XCTestCase {
    @MainActor
    func testOnlyCommandBackspaceRequestsFileDeletionInBothDispatchRoutes() throws {
        try withOutline { outline, _ in
            var deletions = 0
            outline.onCommandDelete = { deletions += 1; return true }
            outline.keyDown(with: try event(51, modifiers: .command))
            XCTAssertEqual(deletions, 1)
            XCTAssertTrue(outline.performKeyEquivalent(with: try event(51, modifiers: .command)))
            XCTAssertEqual(deletions, 2)

            for modifiers: NSEvent.ModifierFlags in [[], .shift, .option, .control,
                                                     [.command, .shift], [.command, .option], [.command, .control]] {
                outline.keyDown(with: try event(51, modifiers: modifiers))
                _ = outline.performKeyEquivalent(with: try event(51, modifiers: modifiers))
            }
            for modifiers: NSEvent.ModifierFlags in [[], .command] {
                outline.keyDown(with: try event(117, modifiers: modifiers))
                _ = outline.performKeyEquivalent(with: try event(117, modifiers: modifiers))
            }
            XCTAssertEqual(deletions, 2)
        }
    }

    @MainActor
    func testHoldingCommandBackspaceDoesNotDeleteSubsequentSelections() throws {
        try withOutline { outline, _ in
            var deletions = 0
            outline.onCommandDelete = { deletions += 1; return true }
            outline.keyDown(with: try event(51, modifiers: .command))
            outline.keyDown(with: try event(51, modifiers: .command, isARepeat: true))
            XCTAssertTrue(outline.performKeyEquivalent(with: try event(51, modifiers: .command, isARepeat: true)))
            XCTAssertEqual(deletions, 1)
            XCTAssertTrue(outline.performKeyEquivalent(with: try event(51, modifiers: .command)))
            XCTAssertEqual(deletions, 2, "A new press can delete the next explicitly selected item.")
        }
    }

    @MainActor
    func testPlainDeleteRetainsSeparateBookmarkCallback() throws {
        try withOutline { outline, _ in
            var bookmarks = 0, files = 0
            outline.onDelete = { bookmarks += 1; return true }
            outline.onCommandDelete = { files += 1; return true }
            outline.keyDown(with: try event(51))
            outline.keyDown(with: try event(117))
            XCTAssertEqual(bookmarks, 2)
            XCTAssertEqual(files, 0)
            outline.keyDown(with: try event(51, modifiers: .command))
            XCTAssertEqual(bookmarks, 2)
            XCTAssertEqual(files, 1)
        }
    }

    @MainActor
    func testEscapeAndSpaceClearSelectionBeforeNotifyingWithoutDeleting() throws {
        try withOutline { outline, _ in
            var clears = 0, deletions = 0
            outline.onClearSelection = {
                XCTAssertEqual(outline.selectedRow, -1)
                clears += 1
            }
            outline.onCommandDelete = { deletions += 1; return true }
            for key: UInt16 in [53, 49] {
                outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                outline.keyDown(with: try event(key))
                XCTAssertEqual(outline.selectedRow, -1)
                outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                XCTAssertTrue(outline.performKeyEquivalent(with: try event(key)))
                XCTAssertEqual(outline.selectedRow, -1)
            }
            XCTAssertEqual(clears, 4)
            XCTAssertEqual(deletions, 0)
            _ = outline.performKeyEquivalent(with: try event(49))
            XCTAssertEqual(clears, 4, "An already empty selection does not trigger another clear.")
        }
    }

    @MainActor
    func testModifiedClearKeysDoNotClearSelection() throws {
        try withOutline { outline, _ in
            var clears = 0
            outline.onClearSelection = { clears += 1 }
            for key: UInt16 in [53, 49] {
                for modifiers: NSEvent.ModifierFlags in [.command, .option, .shift, .control] {
                    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    _ = outline.performKeyEquivalent(with: try event(key, modifiers: modifiers))
                    XCTAssertEqual(outline.selectedRow, 0)
                }
            }
            XCTAssertEqual(clears, 0)
        }
    }

    @MainActor
    func testTextEditorFocusDoesNotTriggerSidebarActions() throws {
        try withOutline { outline, window in
            var calls = 0
            outline.onCommandDelete = { calls += 1; return true }
            outline.onClearSelection = { calls += 1 }
            let text = NSTextView(frame: NSRect(x: 0, y: 100, width: 250, height: 100))
            window.contentView?.addSubview(text)
            XCTAssertTrue(window.makeFirstResponder(text))
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            _ = outline.performKeyEquivalent(with: try event(51, modifiers: .command))
            _ = outline.performKeyEquivalent(with: try event(53))
            _ = outline.performKeyEquivalent(with: try event(49))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(outline.selectedRow, 0)
        }
    }

    @MainActor
    func testInPlaceRenameRetainsEditingKeys() throws {
        try withOutline { outline, window in
            var calls = 0
            outline.onCommandDelete = { calls += 1; return true }
            outline.onClearSelection = { calls += 1 }
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            outline.beginEditing(row: 0, text: "name.md", selecting: NSRange(location: 0, length: 4)) { _ in }
            XCTAssertFalse(window.firstResponder === outline)
            _ = outline.performKeyEquivalent(with: try event(51, modifiers: .command))
            _ = outline.performKeyEquivalent(with: try event(53))
            _ = outline.performKeyEquivalent(with: try event(49))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(outline.selectedRow, 0)
        }
    }

    @MainActor
    private func withOutline(_ body: (SidebarOutlineView, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let outline = SidebarOutlineView.make(label: "Keyboard test")
        outline.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let rows = KeyboardRows()
        outline.dataSource = rows
        window.contentView?.addSubview(outline)
        outline.reloadData()
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertTrue(window.makeFirstResponder(outline))
        try body(outline, window)
        withExtendedLifetime(rows) {}
    }

    private func event(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false) throws -> NSEvent {
        let characters: String
        switch keyCode {
        case 49: characters = " "
        case 53: characters = "\u{1b}"
        case 117: characters = "\u{f728}"
        default: characters = "\u{7f}"
        }
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                             timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: keyCode))
    }
}

@MainActor
private final class KeyboardRows: NSObject, NSOutlineViewDataSource {
    private let item = NSObject()
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 1 : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { self.item }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
}
