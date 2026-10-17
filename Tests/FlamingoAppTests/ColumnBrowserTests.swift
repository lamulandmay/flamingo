import XCTest
@testable import Flamingo

final class ColumnBrowserTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testChainIsEveryFolderFromJustInsideRootDownToTarget() {
        let chain = ColumnBrowserModel.chain(from: url("/Users/a"), to: url("/Users/a/Documents/Works/x"))
        XCTAssertEqual(chain?.map(\.path), ["/Users/a/Documents", "/Users/a/Documents/Works", "/Users/a/Documents/Works/x"])
        XCTAssertNil(ColumnBrowserModel.chain(from: url("/Users/a"), to: url("/Users/ab/Documents")))
        XCTAssertNil(ColumnBrowserModel.chain(from: url("/Users/a"), to: url("/Users/a")))
        XCTAssertEqual(ColumnBrowserModel.chain(from: url("/"), to: url("/Applications"))?.map(\.path), ["/Applications"])
    }

    @MainActor
    func testFollowingTheSidebarKeepsColumnsWhenTheFolderIsInsideThem() {
        let model = ColumnBrowserModel()
        model.follow(url("/v"))
        XCTAssertEqual(model.root?.path, "/v")
        let rooted = model.revision

        // A folder inside the columns selects down to it instead of starting over.
        model.follow(url("/v/finance/2026"))
        XCTAssertEqual(model.root?.path, "/v")
        XCTAssertEqual(model.trail.map(\.path), ["/v/finance", "/v/finance/2026"])
        XCTAssertEqual(model.folder?.path, "/v/finance/2026")
        XCTAssertGreaterThan(model.revision, rooted)

        // A deeper selection that already passes through it is left alone: coming back from a
        // file opened in the columns finds them as they were.
        model.columnsChanged(trail: [url("/v/finance"), url("/v/finance/2026"), url("/v/finance/2026/q3.xlsx")], folder: url("/v/finance/2026"))
        let before = model.revision
        model.follow(url("/v/finance"))
        XCTAssertEqual(model.trail.count, 3)
        XCTAssertEqual(model.revision, before)

        // Anywhere else, the columns start there.
        model.follow(url("/elsewhere"))
        XCTAssertEqual(model.root?.path, "/elsewhere")
        XCTAssertEqual(model.trail, [])
    }

    @MainActor
    func testAFavoriteOutsideTheVaultIsNotUndoneByTheSurfaceReappearing() {
        let model = ColumnBrowserModel()
        model.follow(url("/v/finance"))
        model.browse(url("/Applications"), focus: true, following: url("/v/finance"))
        XCTAssertTrue(model.focusPending)
        // The surface mounts again (a file closed) and follows the unchanged sidebar folder.
        model.follow(url("/v/finance"))
        XCTAssertEqual(model.root?.path, "/Applications")
        // Back in history forces it.
        model.follow(url("/v/finance"), force: true)
        XCTAssertEqual(model.root?.path, "/v/finance")
    }

    func testListingIsFinderOrderWithoutHiddenFilesAndKnowsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["file10.txt", "file2.txt", ".hidden"] { try Data().write(to: dir.appendingPathComponent(name)) }
        try fm.createDirectory(at: dir.appendingPathComponent("Zeta"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Deck.key"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("alpha link"), withDestinationURL: dir.appendingPathComponent("Zeta"))

        let entries = ColumnBrowserView.list(dir, showHidden: false, foldersFirst: false)
        XCTAssertEqual(entries.map(\.name), ["alpha link", "Deck.key", "file2.txt", "file10.txt", "Zeta"])
        XCTAssertEqual(entries.filter(\.isFolder).map(\.name), ["alpha link", "Zeta"])

        let first = ColumnBrowserView.list(dir, showHidden: true, foldersFirst: true)
        XCTAssertEqual(first.prefix(2).map(\.name), ["alpha link", "Zeta"])
        XCTAssertTrue(first.contains { $0.name == ".hidden" && $0.isHidden })
    }
}
