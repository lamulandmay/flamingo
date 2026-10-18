import AppKit
import XCTest
import FlamingoCore
@testable import Flamingo

/// Where the file explorer scrolls when it follows the open file or reveals it, and finding a
/// file its listings don't know about yet.
@MainActor
final class ExplorerFollowTests: XCTestCase {
    // A list 1000pt tall in a 400pt clip, 4pt top and 8pt bottom insets, 26pt rows.
    private let insets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
    private let content: CGFloat = 1000

    private func row(_ y: CGFloat) -> NSRect { NSRect(x: 0, y: y, width: 200, height: 26) }
    private func clip(at y: CGFloat) -> NSRect { NSRect(x: 0, y: y, width: 200, height: 400) }
    private func target(_ rowY: CGFloat, clipY: CGFloat, _ placement: SidebarOutlineView.RowPlacement) -> CGFloat? {
        SidebarOutlineView.scrollTarget(row: row(rowY), visible: clip(at: clipY), insets: insets, contentHeight: content, placement: placement)
    }

    func testFollowingLeavesAVisibleRowAlone() {
        XCTAssertNil(target(100, clipY: 0, .centredIfHidden))
        XCTAssertNil(target(360, clipY: 0, .centredIfHidden), "near the bottom but whole: it stays")
    }

    func testFollowingBringsAHiddenRowToAboutTheMiddle() throws {
        let y = try XCTUnwrap(target(600, clipY: 0, .centredIfHidden))
        let usable: CGFloat = 400 - 4 - 8
        let top = y + 4
        let fraction = (613 - top) / usable
        XCTAssertEqual(fraction, 0.45, accuracy: 0.01)
    }

    func testTheListNeverScrollsPastItsEnds() {
        XCTAssertEqual(target(980 - 26, clipY: 0, .centredIfHidden), 1000 + 8 - 400, "the last rows: as far down as it goes")
        XCTAssertEqual(target(0, clipY: 300, .centredIfHidden), -4, "the first rows: back to the top")
    }

    func testRevealMovesARowHuggingAnEdgeButNotOneSittingComfortably() {
        XCTAssertNil(target(150, clipY: 0, .centredIfCramped))
        XCTAssertNotNil(target(362, clipY: 0, .centredIfCramped), "whole, but against the bottom edge")
        XCTAssertNotNil(target(6, clipY: 0, .centredIfCramped), "whole, but against the top edge")
    }

    func testNearestEdgeMovesOnlyAsFarAsNeeded() {
        XCTAssertEqual(target(500, clipY: 0, .nearestEdge), 500 + 26 + 8 - 400)
        XCTAssertEqual(target(100, clipY: 300, .nearestEdge), 100 - 4)
        XCTAssertNil(target(100, clipY: 0, .nearestEdge))
    }

    // MARK: Following the columns into a folder

    private func opened(_ rowY: CGFloat, contents: CGFloat, clipY: CGFloat) -> CGFloat? {
        SidebarOutlineView.scrollTarget(row: row(rowY), visible: clip(at: clipY), insets: insets, contentHeight: content,
                                        placement: .opened, contents: contents)
    }

    func testAnOpenedFolderThatShowsWholeStaysPut() {
        XCTAssertNil(opened(100, contents: 5 * 26, clipY: 0))
    }

    func testAnOpenedFolderRunningOffTheBottomMovesOnlyEnoughToShowItsRows() throws {
        // The folder at 250, its 6 rows to 432, past the bottom at 392: the last row's bottom
        // comes to just above the bottom inset.
        let y = try XCTUnwrap(opened(250, contents: 6 * 26, clipY: 0))
        XCTAssertEqual(y, 250 + 26 + 6 * 26 + 8 - 400)
    }

    func testABigOpenedFolderStopsWithTheFolderNearTheTop() throws {
        let y = try XCTUnwrap(opened(250, contents: 40 * 26, clipY: 0))
        XCTAssertEqual(y, 250 - 4 - 26 * 1.5, "a row and a half of context above the folder")
        XCTAssertNil(opened(250, contents: 40 * 26, clipY: y), "and stays there")
    }

    func testAnOpenedFolderOutOfSightComesToAboutTheMiddle() throws {
        let y = try XCTUnwrap(opened(700, contents: 2 * 26, clipY: 0))
        XCTAssertGreaterThan(700, y + 4 + 26 * 1.5, "the folder well inside")
        XCTAssertLessThan(700 + 3 * 26, y + 400 - 8, "and its rows")
        let usable: CGFloat = 400 - 4 - 8
        XCTAssertEqual((700 + 39 - (y + 4)) / usable, 0.45, accuracy: 0.01, "the block's middle a little above the list's")
    }

    // MARK: Listings that predate a file

    private func vault() throws -> (Vault, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-ExplorerFollow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a/b/old.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (Vault(root: root), root)
    }

    func testAFileNewerThanItsFoldersListingIsStillFound() throws {
        let (v, root) = try vault()
        let tree = FileTree(vault: v, sort: .nameAscending)
        XCTAssertNotNil(tree.node(for: "a/b/old.md"), "lists a and a/b")
        try Data("y".utf8).write(to: root.appendingPathComponent("a/b/new.md"))
        XCTAssertNil(tree.node(for: "a/b/new.md"), "the listing is from before")
        let (node, relisted) = tree.nodeRelisting(for: "a/b/new.md")
        XCTAssertEqual(node?.id, "a/b/new.md")
        XCTAssertTrue(relisted)
        XCTAssertEqual(tree.nodeRelisting(for: "a/b/new.md").relisted, false, "found now without listing again")
    }

    func testANewFolderOnTheWayIsListedToo() throws {
        let (v, root) = try vault()
        let tree = FileTree(vault: v, sort: .nameAscending)
        _ = tree.node(for: "a/b/old.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/c"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: root.appendingPathComponent("a/c/deep.md"))
        XCTAssertEqual(tree.nodeRelisting(for: "a/c/deep.md").node?.id, "a/c/deep.md")
    }

    func testAPathThatIsNotOnDiskListsNothing() throws {
        let (v, _) = try vault()
        let tree = FileTree(vault: v, sort: .nameAscending)
        _ = tree.node(for: "a/b/old.md")
        let (node, relisted) = tree.nodeRelisting(for: "a/b/gone.md")
        XCTAssertNil(node)
        XCTAssertFalse(relisted)
    }
}
