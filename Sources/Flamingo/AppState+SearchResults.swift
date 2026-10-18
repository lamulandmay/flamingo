import AppKit
import FlamingoCore
import FlamingoIndex

/// The search results list (SearchResults.swift, SearchResultsView.swift): opening it,
/// coming back to it through history, leaving it. Plan 01 owns.
extension AppState {
    /// The list on screen, if any: Files, no file open, and the current history entry is one.
    var shownResults: SearchResultsPlace? {
        guard vault != nil, mode == .files, selected == nil else { return nil }
        return history.current?.results
    }

    /// Every file `query` finds, as Finder's list view in the content area, with the keyboard
    /// in it. `seed` is what the asking surface already showed, so nothing seen disappears.
    /// From another app (⌃⌥F) the window comes forward, as opening a result does.
    func showSearchResults(_ query: String, seed: [UnifiedSearchResult] = []) {
        guard vault != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow?.makeKeyAndOrderFront(nil)
        recordSearch(query)
        if mode != .files { mode = .files }
        if selected != nil { select(nil, source: .other) }
        let place = SearchResultsPlace(query: query, seed: seed)
        searchResults.state = self
        searchResults.adopt(place, focus: true)
        recordResults(place)
        Log.debug("results: show \(query) seed=\(seed.count)")
    }

    /// Back or forward onto a results entry: the list as it was left.
    func restoreResults(_ place: SearchResultsPlace) {
        searchResults.state = self
        searchResults.adopt(place, focus: true)
    }

    /// The folder in place of the list, as its own history entry: Icons or Columns picked
    /// from the toolbar or the View menu while the list shows.
    func leaveResults() {
        guard shownResults != nil else { return }
        selectFromSidebar(folder: selectedFolder, file: nil)
        browser.requestFocus()
    }

    /// ↩ in the search tab: several files, the list of them; one, that file.
    func submitSidebarSearch() {
        let search = sidebarSearch
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let results = search.unifiedResults ?? []
        if !search.searching, results.count == 1 {
            openSearchResult(results[0], query: search.query)
        } else if search.searching || !results.isEmpty {
            showSearchResults(search.query, seed: results)
        } else {
            recordSearch(query)
        }
    }

    // MARK: QA

    /// `results status`, `results sort date` (a header click), `results menu kind`, `results
    /// kind pdfs`, `results query arc`, `results field`. Logged as `results: …`.
    func runResultsQA(_ rest: String) {
        let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let model = searchResults
        func column(_ name: String) -> ResultsColumn? {
            ResultsColumn(rawValue: name) ?? ResultsColumn.allCases.first { $0.title.lowercased().replacingOccurrences(of: " ", with: "") == name.lowercased() }
                ?? ["date": .modified, "where": .location][name]
        }
        switch args.first ?? "" {
        case "sort":
            if let c = args.count > 1 ? column(args[1]) : nil { model.clickSort(c) } else { Log.debug("results: no column \(rest)") }
        case "menu":
            let name = args.count > 1 ? args[1] : "relevance"
            model.pickSort(name == "relevance" ? nil : column(name))
        case "kind":
            if let kind = args.count > 1 ? ResultsKind(rawValue: args[1]) : nil { model.setKind(kind) }
        case "query":
            model.query = args.count > 1 ? args[1] : ""
        case "field":
            model.focusField()
        default:
            break
        }
        let sort = model.sort.column.map { $0.rawValue + (model.sort.ascending ? " asc" : " desc") } ?? "relevance"
        let names = model.rows.prefix(8).map(\.name).joined(separator: ", ")
        let selection = model.selection.flatMap { id in model.rows.first { $0.id == id }?.name } ?? "-"
        let responder = hostWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        Log.debug("results: shown=\(shownResults != nil) query=\(model.query) sort=\(sort) kind=\(model.kind.rawValue) rows=\(model.rows.count) searching=\(model.searching) selection=\(selection) selected=\(selected?.relativePath ?? "-") back=\(canGoBack) forward=\(canGoForward) responder=\(responder) first=[\(names)]")
    }
}
