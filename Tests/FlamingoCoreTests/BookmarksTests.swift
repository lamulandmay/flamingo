import XCTest
@testable import FlamingoCore

final class BookmarksTests: XCTestCase {
    private var root: URL = URL(fileURLWithPath: "/dev/null")
    private var vault: Vault { Vault(root: root) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("BookmarksTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func folder(_ p: String, _ t: Int64) -> Bookmark { Bookmark(kind: .folder, ctime: t, path: p) }
    private func file(_ p: String, _ t: Int64) -> Bookmark { Bookmark(kind: .file, ctime: t, path: p) }
    private func group(_ name: String, _ t: Int64, _ items: [Bookmark] = []) -> Bookmark {
        Bookmark(kind: .group, ctime: t, title: name, items: items)
    }
    private func names(_ b: Bookmarks, _ parent: Bookmarks.Path = []) -> [String] { b.children(at: parent).map(\.displayName) }

    func testFirstRunBookmarksThePinnedFolders() throws {
        try Pins(["Documents", "code/flamingo"]).save(in: vault)
        let b = Bookmarks.loadOrCreate(in: vault)
        XCTAssertEqual(b.items.map(\.path), ["Documents", "code/flamingo"])
        XCTAssertEqual(b.items.map(\.kind), [.folder, .folder])
        XCTAssertEqual(Set(b.items.map(\.ctime)).count, 2, "ids are unique")
        XCTAssertEqual(Bookmarks.load(in: vault), b, "saved on first run")
    }

    func testFirstRunWithoutPinsUsesTheDefaultFolders() throws {
        try fm.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        XCTAssertEqual(Bookmarks.loadOrCreate(in: vault).items.map(\.path), ["Downloads"])
    }

    func testReadsObsidiansFileAndKeepsWhatItDoesntShow() throws {
        let json = """
        {"items":[
          {"type":"file","ctime":1690000000000,"path":"notes/a.md","subpath":"#Plan"},
          {"type":"graph","ctime":1690000000001,"title":"Whole vault"},
          {"type":"group","ctime":1690000000002,"title":"Launch","items":[
            {"type":"search","ctime":1690000000003,"query":"clamp"},
            {"type":"folder","ctime":1690000000004,"path":"decks"}]}]}
        """
        try fm.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try json.write(to: vault.bookmarksURL, atomically: true, encoding: .utf8)
        let b = try XCTUnwrap(Bookmarks.load(in: vault))
        XCTAssertEqual(names(b), ["a.md", "Whole vault", "Launch"])
        XCTAssertNil(b.items[1].kind)
        XCTAssertEqual(b.item(at: [2, 0])?.query, "clamp")
        XCTAssertEqual(b.path(of: .folder, at: "decks"), [2, 1])
        try b.save(in: vault)
        XCTAssertEqual(Bookmarks.load(in: vault), b, "round trip keeps the graph bookmark and the subpath")
        let text = try String(contentsOf: vault.bookmarksURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"subpath\" : \"#Plan\""))
        XCTAssertFalse(text.contains("null"), "absent fields stay absent")
    }

    func testMalformedBookmarksArePreservedAndReported() throws {
        try fm.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let bytes = Data("{unfinished bookmarks".utf8)
        try bytes.write(to: vault.bookmarksURL)
        XCTAssertThrowsError(try Bookmarks.loadOrCreateChecked(in: vault))
        _ = Bookmarks.loadOrCreate(in: vault)
        XCTAssertEqual(try Data(contentsOf: vault.bookmarksURL), bytes)
    }

    func testUnreadableBookmarkPathIsNotReplaced() throws {
        try fm.createDirectory(at: vault.bookmarksURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Bookmarks.loadOrCreateChecked(in: vault))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: vault.bookmarksURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRootPinSurvivesMigration() throws {
        try Pins(["", "Documents"]).save(in: vault)
        XCTAssertEqual(try Bookmarks.loadOrCreateChecked(in: vault).items.map(\.path), ["", "Documents"])
    }

    func testMoveWithinAGroupAndAcrossGroups() {
        var b = Bookmarks([file("a", 1), file("b", 2), group("G", 3, [file("c", 4)]), file("d", 5)])
        // Down past a sibling: index is in positions before the move.
        XCTAssertEqual(b.move(from: [0], toParent: [], index: 2), [1])
        XCTAssertEqual(names(b), ["b", "a", "G", "d"])
        // Into the group, at its end. The group shifts up when something above it leaves.
        XCTAssertEqual(b.move(from: [0], toParent: [2], index: 1), [1, 1])
        XCTAssertEqual(names(b), ["a", "G", "d"])
        XCTAssertEqual(names(b, [1]), ["c", "b"])
        // Out of the group to the top.
        XCTAssertEqual(b.move(from: [1, 0], toParent: [], index: 0), [0])
        XCTAssertEqual(names(b), ["c", "a", "G", "d"])
        XCTAssertEqual(names(b, [2]), ["b"])
    }

    func testAGroupCantMoveIntoItself() {
        var b = Bookmarks([group("G", 1, [group("H", 2)])])
        XCTAssertNil(b.move(from: [0], toParent: [0, 0], index: 0))
        XCTAssertNil(b.move(from: [0], toParent: [0], index: 0))
        XCTAssertEqual(names(b), ["G"])
    }

    func testOnlyGroupsTakeChildren() {
        var b = Bookmarks([file("a", 1), file("b", 2)])
        XCTAssertNil(b.move(from: [1], toParent: [0], index: 0))
        XCTAssertNil(b.insert(file("c", 3), at: [0, 0]))
        XCTAssertEqual(names(b), ["a", "b"])
    }

    func testRemoveAndRename() {
        var b = Bookmarks([folder("docs", 1), group("G", 2, [file("docs/q3.pptx", 3), file("docsx/y", 4)])])
        b.rename("docs", to: "work/docs")
        XCTAssertEqual(b.all.compactMap(\.bookmark.path), ["work/docs", "work/docs/q3.pptx", "docsx/y"])
        XCTAssertEqual(b.removeAll(.file, at: "work/docs/q3.pptx"), 1)
        XCTAssertEqual(names(b, [1]), ["y"])
        XCTAssertEqual(b.remove(at: [1])?.title, "G")
        XCTAssertEqual(names(b), ["docs"])
    }

    func testNextCTimeIsUnique() {
        let b = Bookmarks([file("a", Int64(Date().timeIntervalSince1970 * 1000) + 10_000)])
        XCTAssertEqual(b.nextCTime(), b.items[0].ctime + 1)
    }
}
