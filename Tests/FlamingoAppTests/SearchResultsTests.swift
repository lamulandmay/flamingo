import AppKit
import XCTest
@testable import Flamingo
import FlamingoCore
import FlamingoIndex

@MainActor
final class SearchResultsTests: XCTestCase {
    // MARK: Order

    func testHeaderClicksFollowFinderDirectionsAndTurnAround() {
        let name = ResultsSort.relevance.clicked(.name)
        XCTAssertEqual(name, ResultsSort(column: .name, ascending: true))
        XCTAssertEqual(name.clicked(.name), ResultsSort(column: .name, ascending: false))
        XCTAssertEqual(name.clicked(.name).clicked(.name), name)
        XCTAssertEqual(name.clicked(.modified), ResultsSort(column: .modified, ascending: false), "Dates start newest first")
        XCTAssertEqual(name.clicked(.size), ResultsSort(column: .size, ascending: false), "Sizes start largest first")
        XCTAssertEqual(name.clicked(.kind), ResultsSort(column: .kind, ascending: true))
        XCTAssertEqual(name.picked(nil), .relevance)
        XCTAssertEqual(ResultsSort.relevance.picked(nil), .relevance)
        XCTAssertEqual(name.picked(.name), ResultsSort(column: .name, ascending: false), "Picking the order in use turns it around")
        XCTAssertEqual(ResultsSort.menu, [nil, .name, .kind, .lastOpened, .added, .modified, .created, .size])
    }

    func testKindsSortFilesAsFinderDoes() {
        let cases: [(String, Bool, ResultsKind)] = [
            ("", true, .folders), ("pdf", false, .pdfs), ("pptx", false, .presentations), ("key", false, .presentations),
            ("xlsx", false, .spreadsheets), ("numbers", false, .spreadsheets), ("csv", false, .spreadsheets),
            ("png", false, .images), ("HEIC", false, .images), ("mp4", false, .movies), ("mov", false, .movies),
            ("mp3", false, .music), ("m4a", false, .music), ("docx", false, .documents), ("pages", false, .documents),
            ("md", false, .documents), ("txt", false, .documents), ("rtf", false, .documents),
            ("swift", false, .other), ("usdz", false, .other), ("zip", false, .other), ("", false, .other),
        ]
        for (ext, folder, kind) in cases {
            XCTAssertEqual(ResultsKind.of(ext: ext, isDirectory: folder), kind, "\(ext) folder=\(folder)")
        }
    }

    func testRelevanceKeepsTheSearchRankingAndKindFilters() {
        let rows = [row("b/homework.pdf", rank: 1), row("a/homework.docx", rank: 0), row("homework", rank: 2, folder: true)]
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: .relevance, kind: .all).map(\.result.file.relativePath),
                       ["a/homework.docx", "b/homework.pdf", "homework"])
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: .relevance, kind: .pdfs).map(\.name), ["homework.pdf"])
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: .relevance, kind: .folders).map(\.name), ["homework"])
        XCTAssertTrue(ResultsOrder.arranged(rows, sort: .relevance, kind: .music).isEmpty)
    }

    func testNamesSortInFinderOrderWithFoldersOnTopWhenAsked() {
        let rows = [row("homework 10.md", rank: 0), row("Homework 2.md", rank: 1), row("algebra.md", rank: 2), row("zeta", rank: 3, folder: true)]
        let ascending = ResultsOrder.arranged(rows, sort: .by(.name), kind: .all)
        XCTAssertEqual(ascending.map(\.name), ["algebra.md", "Homework 2.md", "homework 10.md", "zeta"])
        let descending = ResultsOrder.arranged(rows, sort: ResultsSort(column: .name, ascending: false), kind: .all)
        XCTAssertEqual(descending.map(\.name), ["zeta", "homework 10.md", "Homework 2.md", "algebra.md"])
        let folders = ResultsOrder.arranged(rows, sort: .by(.name), kind: .all, foldersFirst: true)
        XCTAssertEqual(folders.first?.name, "zeta")
    }

    func testMissingValuesGoLastEitherWayAndTiesKeepTheRanking() {
        let day: TimeInterval = 86_400
        var old = row("old.pdf", rank: 0); old.meta = ResultMeta(added: Date(timeIntervalSince1970: day), size: 10)
        var new = row("new.pdf", rank: 1); new.meta = ResultMeta(added: Date(timeIntervalSince1970: 3 * day), size: 300)
        var unknown = row("unknown.pdf", rank: 2); unknown.meta = ResultMeta(added: nil, size: nil)
        var twin = row("twin.pdf", rank: 3); twin.meta = ResultMeta(added: Date(timeIntervalSince1970: 3 * day), size: 300)
        let rows = [unknown, twin, old, new]
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: .by(.added), kind: .all).map(\.name), ["new.pdf", "twin.pdf", "old.pdf", "unknown.pdf"])
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: ResultsSort(column: .added, ascending: true), kind: .all).map(\.name),
                       ["old.pdf", "new.pdf", "twin.pdf", "unknown.pdf"])
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: .by(.size), kind: .all).map(\.name), ["new.pdf", "twin.pdf", "old.pdf", "unknown.pdf"])
        XCTAssertEqual(ResultsOrder.arranged(rows, sort: ResultsSort(column: .size, ascending: true), kind: .all).last?.name, "unknown.pdf")
    }

    func testModifiedFallsBackToTheIndexDateAndVanishedItemsDropOut() {
        var gone = row("gone.pdf", rank: 0); gone.meta = ResultMeta(exists: false)
        let early = row("early.pdf", rank: 1, modified: Date(timeIntervalSince1970: 10))
        let late = row("late.pdf", rank: 2, modified: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(ResultsOrder.arranged([gone, early, late], sort: .by(.modified), kind: .all).map(\.name), ["late.pdf", "early.pdf"])
    }

    func testNameTakesTheWidthAndTheOthersGiveWayTogether() {
        let others: [(natural: CGFloat, min: CGFloat)] = [(150, 72), (150, 72), (76, 64), (120, 80)]
        // Room to spare: the others keep their widths, Name takes the rest.
        let wide = SearchResultsView.fit(width: 1200, nameMin: 160, others: others)
        XCTAssertEqual(wide.others, [150, 150, 76, 120])
        XCTAssertEqual(wide.name, 704)
        // Narrow: Name keeps its share, the others shrink together, none below its minimum.
        let narrow = SearchResultsView.fit(width: 585, nameMin: 160, others: others)
        XCTAssertEqual(narrow.name + narrow.others.reduce(0, +), 585)
        XCTAssertGreaterThanOrEqual(narrow.name, 234)
        for (w, column) in zip(narrow.others, others) { XCTAssertGreaterThanOrEqual(w, column.min) }
        XCTAssertLessThan(narrow.others[0], 150)
        // Too narrow even for the minimums: everything at its minimum, the list scrolls.
        let tiny = SearchResultsView.fit(width: 300, nameMin: 160, others: others)
        XCTAssertEqual(tiny.others, [72, 72, 64, 80])
        XCTAssertEqual(tiny.name, 160)
    }

    func testPaletteSeedJoinsTheBiggerSearchWithoutDuplicates() {
        let a = UnifiedSearchResult(file: FileRef(relativePath: "a.md"), score: 90)
        let b = UnifiedSearchResult(file: FileRef(relativePath: "b.md"), score: 70)
        let meaning = UnifiedSearchResult(file: FileRef(relativePath: "meaning.md"), score: 80)
        let merged = ResultsOrder.merging([a, b], seed: [a, meaning])
        XCTAssertEqual(merged.map(\.file.relativePath), ["a.md", "meaning.md", "b.md"], "What the palette showed leads, in its order")
        XCTAssertEqual(ResultsOrder.merging([a, b], seed: [b]), [b, a])
        XCTAssertEqual(ResultsOrder.merging([a, b], seed: []), [a, b])
        let place = SearchResultsPlace(query: " homework ", seed: [meaning])
        XCTAssertEqual(place.seed(for: "homework"), [meaning])
        XCTAssertTrue(place.seed(for: "homework 2").isEmpty, "An edited query gets no seed")
    }

    // MARK: History

    func testAResultsListIsItsOwnHistoryEntry() {
        var history = History()
        history.push(.init(file: nil, anchor: nil, folder: "school"))
        let place = SearchResultsPlace(query: "homework")
        history.push(.init(file: nil, anchor: nil, folder: "school", results: place))
        XCTAssertEqual(history.entries.count, 2, "A list over the same folder is a new place")
        history.push(.init(file: nil, anchor: nil, folder: "school", results: place))
        XCTAssertEqual(history.entries.count, 2, "The same list again collapses")
        history.push(.init(file: nil, anchor: nil, folder: "school", results: SearchResultsPlace(query: "homework")))
        XCTAssertEqual(history.entries.count, 3, "Another search is another place")
        history.push(.init(file: FileRef(relativePath: "school/homework.pdf"), anchor: nil, folder: "school"))
        XCTAssertTrue(history.goBack()?.results != nil)
    }

    // MARK: Palette

    func testReturnShowsTheListOnlyForSeveralUnpickedFiles() {
        let model = PaletteModel()
        model.vault = Vault(root: FileManager.default.temporaryDirectory)
        var listed = 0
        var opened: [String] = []
        model.onList = { listed += 1 }
        model.onRun = { item, _ in opened.append(item.id) }
        model.query = "homework"
        model.setItems([.result(result("a/homework.pdf")), .result(result("b/homework.docx"))])
        model.submit()
        XCTAssertEqual(listed, 1)
        XCTAssertTrue(opened.isEmpty)

        model.moveHighlight(1)
        model.submit()
        XCTAssertEqual(listed, 1, "A row picked with the arrows opens")
        XCTAssertEqual(opened, ["result:file:b/homework.docx"])

        model.setItems([.result(result("a/homework.pdf"))])
        model.submit()
        XCTAssertEqual(opened.last, "result:file:a/homework.pdf", "One file opens directly")

        model.setItems([.result(result("a/homework.pdf")), .result(result("b/homework.docx"))])
        model.select(0)
        model.submit()
        XCTAssertEqual(listed, 1, "A clicked row opens")

        model.setItems([.result(result("a/homework.pdf")), .result(result("b/homework.docx"))])
        model.searching = true
        model.submit()
        XCTAssertTrue(model.submitPending, "Return waits for a search in flight")
        XCTAssertEqual(listed, 1)

        model.submitPending = false
        model.searching = false
        model.query = ">graph"
        model.submit()
        XCTAssertEqual(listed, 1, "Commands run as before")
    }

    // MARK: The list in the app

    func testOpeningAFileFromTheListAndComingBackFindsItAsLeft() throws {
        try withVault(["school/homework.pdf", "work/homework.docx", "notes.md"]) { state in
            state.select(FileRef(relativePath: "notes.md"), source: .other)
            let seed = [result("school/homework.pdf"), result("work/homework.docx")]
            state.showSearchResults("homework", seed: seed)
            XCTAssertNil(state.selected)
            let place = try XCTUnwrap(state.shownResults)
            XCTAssertEqual(place.query, "homework")
            XCTAssertEqual(state.searchResults.rows.map(\.name), ["homework.pdf", "homework.docx"])
            XCTAssertTrue(state.searchResults.focusPending)

            state.searchResults.clickSort(.name)
            state.searchResults.setKind(.documents)
            state.searchResults.select("file:work/homework.docx")
            let row = try XCTUnwrap(state.searchResults.rows.first)
            state.searchResults.open(row, externally: false)
            XCTAssertEqual(state.selected?.relativePath, "work/homework.docx")
            XCTAssertNil(state.shownResults)

            state.goBack()
            XCTAssertNil(state.selected)
            XCTAssertTrue(state.shownResults === place)
            XCTAssertEqual(state.searchResults.sort, ResultsSort(column: .name, ascending: true))
            XCTAssertEqual(state.searchResults.kind, .documents)
            XCTAssertEqual(state.searchResults.selection, "file:work/homework.docx")
            XCTAssertEqual(state.searchResults.rows.map(\.name), ["homework.docx"])

            state.goForward()
            XCTAssertEqual(state.selected?.relativePath, "work/homework.docx")
            state.goBack()
            state.goBack()
            XCTAssertEqual(state.selected?.relativePath, "notes.md", "Before the list: where the search started")
        }
    }

    func testAFolderStyleLeavesTheListAsItsOwnEntry() throws {
        try withVault(["a/homework.pdf", "b/homework.pdf"]) { state in
            state.showSearchResults("homework", seed: [result("a/homework.pdf"), result("b/homework.pdf")])
            let place = try XCTUnwrap(state.shownResults)
            state.leaveResults()
            XCTAssertNil(state.shownResults)
            state.goBack()
            XCTAssertTrue(state.shownResults === place)
        }
    }

    func testARenamedRowKeepsItsPlaceAndSelection() throws {
        try withVault(["school/homework.pdf", "work/homework.docx"]) { state in
            state.showSearchResults("homework", seed: [result("school/homework.pdf"), result("work/homework.docx")])
            let place = try XCTUnwrap(state.shownResults)
            state.searchResults.select("file:school/homework.pdf")

            XCTAssertTrue(state.rename("school/homework.pdf", to: "essay.pdf"))
            XCTAssertEqual(state.searchResults.rows.map(\.result.file.relativePath), ["school/essay.pdf", "work/homework.docx"])
            XCTAssertEqual(state.searchResults.selection, "file:school/essay.pdf")

            XCTAssertTrue(state.rename("school", to: "college"), "A folder above a row")
            XCTAssertEqual(state.searchResults.rows.first?.result.file.relativePath, "college/essay.pdf")
            XCTAssertEqual(state.searchResults.selection, "file:college/essay.pdf")
            XCTAssertEqual(place.seed(for: "homework").map(\.file.relativePath), ["college/essay.pdf", "work/homework.docx"],
                           "Coming back to the list shows the new names")
        }
    }

    func testSidebarReturnShowsTheListOrTheOnlyFile() throws {
        try withVault(["a/homework.pdf"]) { state in
            state.sidebarSearch.query = ""
            state.submitSidebarSearch()
            XCTAssertNil(state.shownResults)
            state.showSearchResults("  ")
            XCTAssertNil(state.shownResults, "Nothing to list for an empty query")
        }
    }

    // MARK: Helpers

    private func result(_ path: String, folder: Bool = false, modified: Date? = nil) -> UnifiedSearchResult {
        UnifiedSearchResult(file: FileRef(relativePath: path), isDirectory: folder, score: 1, modified: modified)
    }

    private func row(_ path: String, rank: Int, folder: Bool = false, modified: Date? = nil) -> ResultRow {
        ResultRow(result: result(path, folder: folder, modified: modified), rank: rank)
    }

    private func withVault(_ paths: [String], _ body: (AppState) throws -> Void) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Flamingo-SearchResultsTests-" + UUID().uuidString)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("homework\n".utf8).write(to: url)
        }
        let defaults = UserDefaults.standard
        let keys = ["lastVault", "recentVaults", "workspace." + root.path, "vault.selected." + root.path,
                    "vault.expanded." + root.path, "vault.foldedBookmarks." + root.path]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let state = AppState()
        defer {
            state.selected = nil
            state.session?.stop()
            for key in keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            try? fm.removeItem(at: root)
        }
        state.open(root)
        state.session?.stop()
        try body(state)
    }
}
