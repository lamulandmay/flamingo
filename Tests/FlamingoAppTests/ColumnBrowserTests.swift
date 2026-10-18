import AppKit
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

    private func entry(_ name: String, folder: Bool = false) -> ColumnEntry {
        ColumnEntry(url: url("/v/" + name), name: name, isFolder: folder, isHidden: false, isAlias: false)
    }

    func testSortingBySomethingElseKeepsMissingValuesLastAndTiesInNameOrder() {
        let entries = [entry("b"), entry("Folder", folder: true), entry("a"), entry("c")]
        let day = { (n: Double) in ResultsOrder.Key.date(Date(timeIntervalSince1970: n * 86_400)) }
        let keys: [ResultsOrder.Key?] = [day(1), nil, day(1), day(3)]

        let newest = ColumnOrder.sorted(entries, by: .by(.modified), foldersFirst: true, keys: keys)
        XCTAssertEqual(newest.map(\.name), ["c", "a", "b", "Folder"])
        let oldest = ColumnOrder.sorted(entries, by: ColumnSort(key: .modified, ascending: true), foldersFirst: true, keys: keys)
        XCTAssertEqual(oldest.map(\.name), ["a", "b", "c", "Folder"])
    }

    func testFoldersLeadOnlyWhenSortingByName() {
        let entries = [entry("b"), entry("Zeta", folder: true), entry("a")]
        XCTAssertEqual(ColumnOrder.sorted(entries, by: .finder, foldersFirst: true).map(\.name), ["Zeta", "a", "b"])
        XCTAssertEqual(ColumnOrder.sorted(entries, by: ColumnSort(key: .name, ascending: false), foldersFirst: false).map(\.name),
                       ["Zeta", "b", "a"])
        let sizes: [ResultsOrder.Key?] = [.number(10), nil, .number(20)]
        XCTAssertEqual(ColumnOrder.sorted(entries, by: .by(.size), foldersFirst: true, keys: sizes).map(\.name), ["a", "b", "Zeta"])
    }

    func testAPickStartsANewKeyItsOwnWayAndKeepsTheWayOfTheKeyInUse() {
        XCTAssertEqual(ColumnSort.finder.picked(.added), ColumnSort(key: .added, ascending: false))
        XCTAssertEqual(ColumnSort.finder.picked(.kind), ColumnSort(key: .kind, ascending: true))
        let oldest = ColumnSort(key: .added, ascending: true)
        XCTAssertEqual(oldest.picked(.added), oldest)
    }

    func testListingSortsBySizeFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (name, size) in [("small.txt", 1), ("big.txt", 300), ("mid.txt", 20)] {
            try Data(count: size).write(to: dir.appendingPathComponent(name))
        }
        try fm.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let entries = ColumnBrowserView.list(dir, showHidden: false, foldersFirst: true, sort: .by(.size))
        XCTAssertEqual(entries.map(\.name), ["big.txt", "mid.txt", "small.txt", "Folder"])
    }

    /// The whole way through: Sort By in a column's menu reorders every column, and the
    /// selection stays on the same file.
    @MainActor
    func testSortByInAColumnsMenuReordersEveryColumnAndKeepsTheSelection() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = ColumnBrowserModel.normal(fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let sub = dir.appendingPathComponent("Sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 300), ("b.txt", 1), ("c.txt", 20)] { try Data(count: size).write(to: dir.appendingPathComponent(name)) }
        for (name, size) in [("x.txt", 5), ("y.txt", 50)] { try Data(count: size).write(to: sub.appendingPathComponent(name)) }
        let saved = Defaults.columnSort
        defer { Defaults.columnSort = saved; try? fm.removeItem(at: dir) }

        let model = ColumnBrowserModel()
        model.sort = .finder
        model.browse(dir, following: nil)
        model.reveal(sub.appendingPathComponent("x.txt"), following: nil)
        let view = ColumnBrowserView(state: AppState(), model: model)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        view.apply(counts: [:])

        func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
        func names(_ t: NSTableView) -> [String] { (0..<t.numberOfRows).compactMap { view.tableView(t, typeSelectStringFor: nil, row: $0) } }
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<300 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(done())
        }
        try await settle { tables(view).count == 2 && tables(view).allSatisfy { $0.numberOfRows > 0 } }
        // Finder's "Keep folders on top" is the user's; it counts only when sorting by name.
        XCTAssertEqual(names(tables(view)[0]), FinderSettings.foldersFirst ? ["Sub", "a.txt", "b.txt", "c.txt"] : ["a.txt", "b.txt", "c.txt", "Sub"])
        XCTAssertEqual(names(tables(view)[1]), ["x.txt", "y.txt"])

        func pick(_ title: String) throws {
            let menu = try XCTUnwrap(tables(view)[0].menu)
            view.menuNeedsUpdate(menu)
            let sortBy = try XCTUnwrap(menu.items.first { $0.title == "Sort By" }?.submenu)
            sortBy.performActionForItem(at: try XCTUnwrap(sortBy.items.firstIndex { $0.title == title }))
            view.apply(counts: [:])   // as SwiftUI's update would
        }
        try pick("Size")
        XCTAssertEqual(model.sort, ColumnSort(key: .size, ascending: false))
        XCTAssertEqual(Defaults.columnSort, model.sort)
        try await settle { names(tables(view)[1]) == ["y.txt", "x.txt"] }
        XCTAssertEqual(names(tables(view)[0]), ["a.txt", "c.txt", "b.txt", "Sub"])
        XCTAssertEqual(tables(view)[1].selectedRow, 1, "x.txt stays selected")

        try pick("Smallest First")
        try await settle { names(tables(view)[0]) == ["b.txt", "c.txt", "a.txt", "Sub"] }
        let menu = try XCTUnwrap(tables(view)[1].menu)
        view.menuNeedsUpdate(menu)
        let checked = menu.items.first { $0.title == "Sort By" }?.submenu?.items.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checked, ["Size", "Smallest First"])
    }
}
