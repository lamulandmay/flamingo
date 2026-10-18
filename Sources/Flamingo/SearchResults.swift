import AppKit
import Combine
import CoreServices
import UniformTypeIdentifiers
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

// MARK: - Columns, order and kinds

/// The columns of Finder's list view, for search results.
enum ResultsColumn: String, CaseIterable, Identifiable, Sendable {
    case name, location, modified, added, lastOpened, created, size, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .location: "Where"
        case .modified: "Date Modified"
        case .added: "Date Added"
        case .lastOpened: "Date Last Opened"
        case .created: "Date Created"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// How a first click sorts, as in Finder: names, places and kinds A to Z, dates newest
    /// first, sizes largest first.
    var ascendingFirst: Bool { [.name, .location, .kind].contains(self) }

    /// Until the user picks otherwise from the header's menu: Finder's own list columns.
    /// Where, Date Last Opened and Date Created are a right-click on the header away.
    var visibleByDefault: Bool { ![.location, .lastOpened, .created].contains(self) }

    var isDate: Bool { [.modified, .added, .lastOpened, .created].contains(self) }
}

/// How the list is ordered: the search's own ranking (relevance), or a column either way.
struct ResultsSort: Equatable, Sendable {
    /// nil is relevance.
    var column: ResultsColumn?
    var ascending: Bool

    static let relevance = ResultsSort(column: nil, ascending: true)
    static func by(_ column: ResultsColumn) -> ResultsSort { ResultsSort(column: column, ascending: column.ascendingFirst) }

    /// A click on a column's header: the column it already sorts by turns around.
    func clicked(_ column: ResultsColumn) -> ResultsSort {
        self.column == column ? ResultsSort(column: column, ascending: !ascending) : .by(column)
    }

    /// A pick from the sort menu: the order in use turns around; relevance has one way.
    func picked(_ column: ResultsColumn?) -> ResultsSort {
        guard let column else { return .relevance }
        return clicked(column)
    }

    /// The sort menu, in Finder's order, relevance first.
    static let menu: [ResultsColumn?] = [nil, .name, .kind, .lastOpened, .added, .modified, .created, .size]
}

/// Finder's "Kind is …".
enum ResultsKind: String, CaseIterable, Identifiable, Sendable {
    case all, folders, documents, pdfs, presentations, spreadsheets, images, movies, music, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .folders: "Folders"
        case .documents: "Documents"
        case .pdfs: "PDFs"
        case .presentations: "Presentations"
        case .spreadsheets: "Spreadsheets"
        case .images: "Images"
        case .movies: "Movies"
        case .music: "Music"
        case .other: "Other"
        }
    }

    /// The kind a result is, from its extension: the family Flamingo already knows, then the
    /// system's type for anything else.
    static func of(ext: String, isDirectory: Bool) -> ResultsKind {
        if isDirectory { return .folders }
        let e = ext.lowercased()
        if let family = FileFamily(ext: e) {
            switch family {
            case .pdf: return .pdfs
            case .deck: return .presentations
            case .sheet: return .spreadsheets
            case .image: return .images
            case .media: return FileFamily.audio.contains(e) ? .music : .movies
            case .document, .note: return .documents
            case .code, .model: return .other
            }
        }
        guard !e.isEmpty, let type = UTType(filenameExtension: e) else { return .other }
        if type.conforms(to: .pdf) { return .pdfs }
        if type.conforms(to: .presentation) { return .presentations }
        if type.conforms(to: .spreadsheet) { return .spreadsheets }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movies }
        if type.conforms(to: .sourceCode) { return .other }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .documents }
        return .other
    }
}

/// What Finder shows about an item, read from disk off the main thread.
struct ResultMeta: Equatable, Sendable {
    var exists = true
    var modified: Date?
    var added: Date?
    var created: Date?
    var lastOpened: Date?
    /// nil for folders, as Finder's "--".
    var size: Int64?
    /// Finder's kind: "PDF document", "Folder".
    var kind: String?

    /// Up to this many entries are counted for a package's size (a Keynote file, an app).
    static let packageEntryLimit = 4_000

    static func load(_ items: [(id: String, url: URL)]) -> [String: ResultMeta] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .addedToDirectoryDateKey, .creationDateKey, .fileSizeKey,
                                         .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey]
        var out: [String: ResultMeta] = [:]
        for item in items {
            guard FileManager.default.fileExists(atPath: item.url.path), let values = try? item.url.resourceValues(forKeys: keys) else {
                out[item.id] = ResultMeta(exists: false)
                continue
            }
            var meta = ResultMeta()
            meta.modified = values.contentModificationDate
            meta.added = values.addedToDirectoryDate
            meta.created = values.creationDate
            meta.kind = values.localizedTypeDescription.map(ResultsFormat.kind)
            if values.isDirectory == true {
                meta.size = values.isPackage == true ? packageSize(item.url) : nil
            } else {
                meta.size = values.fileSize.map(Int64.init)
            }
            // Spotlight's "last opened", as Finder shows it; nil where Spotlight doesn't index.
            if let md = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL),
               let used = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date {
                meta.lastOpened = used
            }
            out[item.id] = meta
        }
        return out
    }

    private static func packageSize(_ url: URL) -> Int64? {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return nil }
        var total: Int64 = 0, seen = 0
        for case let file as URL in walker {
            seen += 1
            if seen > packageEntryLimit { break }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

/// One row: a result, where it ranked, and what the disk says about it once read.
struct ResultRow: Identifiable, Equatable, Sendable {
    let result: UnifiedSearchResult
    /// Its place in the search's own ranking.
    let rank: Int
    var meta: ResultMeta?

    var id: String { result.id }
    var name: String { result.file.name }
    /// The folder it is in, vault-relative; "" at the vault's root.
    var location: String { result.file.directory }
    var kind: ResultsKind { .of(ext: result.file.ext, isDirectory: result.isDirectory) }
}

enum ResultsOrder {
    /// The rows that pass `kind`, in `sort`'s order. Items gone from disk drop out. Missing
    /// values (a date Spotlight never saw, a folder's size) go last either way, as in Finder;
    /// ties keep the search's ranking. With `foldersFirst` (Finder's "Keep folders on top"),
    /// folders lead when sorting by name.
    static func arranged(_ rows: [ResultRow], sort: ResultsSort, kind: ResultsKind, foldersFirst: Bool = false) -> [ResultRow] {
        var list = rows.filter { $0.meta?.exists != false && (kind == .all || $0.kind == kind) }
        guard let column = sort.column else { return list.sorted { $0.rank < $1.rank } }
        let keys = Dictionary(uniqueKeysWithValues: list.map { ($0.id, key($0, column)) })
        list.sort { a, b in
            if foldersFirst, column == .name, a.result.isDirectory != b.result.isDirectory { return a.result.isDirectory }
            switch (keys[a.id] ?? nil, keys[b.id] ?? nil) {
            case (nil, nil): return a.rank < b.rank
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                let order = x.compare(y)
                if order == .orderedSame { return a.rank < b.rank }
                return (order == .orderedAscending) == sort.ascending
            }
        }
        return list
    }

    enum Key {
        case text(String), date(Date), number(Int64)

        func compare(_ other: Key) -> ComparisonResult {
            switch (self, other) {
            case let (.text(a), .text(b)):
                if a == b { return .orderedSame }
                return FinderOrder.precedes(a, b) ? .orderedAscending : FinderOrder.precedes(b, a) ? .orderedDescending : .orderedSame
            case let (.date(a), .date(b)): return a.compare(b)
            case let (.number(a), .number(b)): return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            default: return .orderedSame
            }
        }
    }

    static func key(_ row: ResultRow, _ column: ResultsColumn) -> Key? {
        switch column {
        case .name: return .text(row.name)
        case .location: return .text(row.location)
        case .kind: return row.meta?.kind.map(Key.text)
        case .size: return row.meta?.size.map(Key.number)
        case .modified: return (row.meta?.modified ?? row.result.modified).map(Key.date)
        case .added: return row.meta?.added.map(Key.date)
        case .lastOpened: return row.meta?.lastOpened.map(Key.date)
        case .created: return row.meta?.created.map(Key.date)
        }
    }

    /// What the palette showed, in the order it showed it, then the rest the bigger search
    /// found: the files that were at the top stay at the top, and none of them disappears.
    static func merging(_ results: [UnifiedSearchResult], seed: [UnifiedSearchResult]) -> [UnifiedSearchResult] {
        guard !seed.isEmpty else { return results }
        var seen = Set<String>()
        return (seed + results).filter { seen.insert($0.id).inserted }
    }
}

/// How the list's cells read, as Finder writes them.
@MainActor
enum ResultsFormat {
    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()
    /// Below this width a date drops its time, as Finder narrows a column.
    static let longDateWidth: CGFloat = 150

    static func date(_ date: Date?, width: CGFloat) -> String {
        guard let date else { return "" }
        return (width >= longDateWidth ? long : short).string(from: date)
    }

    /// Finder's kind without the maker or the extension, so it fits a column:
    /// "Microsoft PowerPoint presentation (.pptx)" reads "PowerPoint presentation".
    nonisolated static func kind(_ description: String) -> String {
        var k = description
        if let open = k.range(of: " (", options: .backwards), k.hasSuffix(")") { k = String(k[..<open.lowerBound]) }
        for maker in ["Microsoft ", "Apple ", "Adobe ", "Pixar ", "Google "] where k.hasPrefix(maker) && k.count > maker.count + 3 {
            k.removeFirst(maker.count)
            break
        }
        return k
    }

    static func size(_ row: ResultRow) -> String {
        guard let meta = row.meta else { return "" }
        guard let size = meta.size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - A place in history

/// One visit to a results list, held by its history entry. The list writes its query, order,
/// filter, selection and rows into it as they change, so coming back to the entry finds the
/// list as it was left. Plan 01 owns.
final class SearchResultsPlace: Equatable {
    var query: String
    var sort = ResultsSort.relevance
    var kind = ResultsKind.all
    /// The selected row's result id.
    var selection: String?
    /// What the search found for `searched`, best first; nil until a search has landed.
    var results: [UnifiedSearchResult]?
    var searched: String?
    var truncated = false
    /// The rows the palette showed when the list opened. They stay in the list even when the
    /// bigger search ranks them out, so nothing seen disappears.
    var seed: [UnifiedSearchResult]
    private let seedQuery: String

    init(query: String, seed: [UnifiedSearchResult] = []) {
        self.query = query
        self.seed = seed
        self.seedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The seed, when `query` is the one it was found for.
    func seed(for query: String) -> [UnifiedSearchResult] { query == seedQuery ? seed : [] }

    static func == (a: SearchResultsPlace, b: SearchResultsPlace) -> Bool { a === b }
}

// MARK: - Model

/// The results list on screen (SearchResultsView.swift): the place it shows, its rows in
/// order, and what the field holds. One per window, on `AppState`. Plan 01 owns.
@MainActor
final class SearchResultsModel: ObservableObject {
    /// Finder lists everything; the index caps a search here.
    static let limit = 500
    static let debounce: UInt64 = 150_000_000

    weak var state: AppState?
    private(set) var place: SearchResultsPlace?

    /// The field. Editing it searches again, a moment after the typing stops.
    @Published var query = "" {
        didSet {
            guard query != oldValue, !adopting, let place else { return }
            place.query = query
            search(after: Self.debounce)
        }
    }
    @Published private(set) var sort = ResultsSort.relevance
    @Published private(set) var kind = ResultsKind.all
    /// What the table shows, filtered and ordered.
    @Published private(set) var rows: [ResultRow] = []
    @Published private(set) var searching = false
    @Published private(set) var failure: String?
    /// The search stopped at `limit` with more to find.
    @Published private(set) var truncated = false
    /// Bumped whenever `rows` are replaced; the table reloads.
    @Published private(set) var revision = 0
    /// Bumped when the rows changed enough that the selection should be scrolled into view.
    @Published private(set) var revealRevision = 0
    /// Bumped to put the keyboard in the field.
    @Published private(set) var fieldFocusRequest = 0
    /// Bumped to put the keyboard in the table (↓ or ↩ in the field).
    @Published private(set) var listFocusRequest = 0
    /// Set to put the keyboard in the table once it is on screen.
    var focusPending = false
    /// Select the first row once there is one, as the list opens.
    var wantsFirstRow = false
    var foldersFirst = FinderSettings.foldersFirst

    var selection: String? { place?.selection }

    private var ranked: [ResultRow] = []
    private var meta: [String: ResultMeta] = [:]
    private var searchTask: Task<Void, Never>?
    private var metaTask: Task<Void, Never>?
    private var adopting = false

    /// Shows `place`, from where it was left. `focus` puts the keyboard in the table.
    func adopt(_ place: SearchResultsPlace, focus: Bool) {
        let fresh = self.place !== place
        self.place = place
        adopting = true
        query = place.query
        sort = place.sort
        kind = place.kind
        adopting = false
        if fresh {
            searchTask?.cancel()
            failure = nil
            truncated = place.truncated
            searching = false
            meta = [:]
            setResults(place.results ?? place.seed(for: place.query.trimmingCharacters(in: .whitespacesAndNewlines)))
            wantsFirstRow = focus && place.selection == nil
        }
        if place.searched != place.query { search(after: 0) }
        if focus { focusPending = true; revealRevision &+= 1 }
    }

    func setSort(_ new: ResultsSort) {
        guard new != sort else { return }
        sort = new
        place?.sort = new
        arrange(reveal: true)
    }

    /// A header click.
    func clickSort(_ column: ResultsColumn) { setSort(sort.clicked(column)) }
    /// The sort menu.
    func pickSort(_ column: ResultsColumn?) { setSort(sort.picked(column)) }

    func setKind(_ new: ResultsKind) {
        guard new != kind else { return }
        kind = new
        place?.kind = new
        arrange(reveal: true)
    }

    /// The table's selection moved.
    func select(_ id: String?) {
        place?.selection = id
        if id != nil { wantsFirstRow = false }
    }

    func focusField() { fieldFocusRequest &+= 1 }

    /// The keyboard to the table, on the selected row or else the first.
    func focusList() {
        focusPending = true
        wantsFirstRow = true
        listFocusRequest &+= 1
    }

    /// Opens a row: here (a folder becomes the place), or in its default app.
    func open(_ row: ResultRow, externally: Bool) {
        guard let state else { return }
        place?.selection = row.id
        state.openSearchResult(row.result, query: query, externally: externally)
    }

    /// `old` was renamed or moved to `new`: rows at or under it keep their place, renamed.
    func relocate(_ old: String, to new: String) {
        func moved(_ result: UnifiedSearchResult) -> UnifiedSearchResult {
            guard FileTree.contains(old, result.file.relativePath) else { return result }
            var result = result
            result.file = FileRef(relativePath: new + result.file.relativePath.dropFirst(old.count))
            return result
        }
        guard let place, ranked.contains(where: { FileTree.contains(old, $0.result.file.relativePath) }) else { return }
        let selected = place.selection.flatMap { id in ranked.first { $0.id == id } }
        ranked = ranked.map { ResultRow(result: moved($0.result), rank: $0.rank, meta: $0.meta) }
        place.results = place.results?.map(moved)
        place.seed = place.seed.map(moved)
        if let selected { place.selection = moved(selected.result).id }
        arrange(reveal: false)
    }

    /// The disk changed: read every row's metadata again; vanished items drop out.
    func refreshMeta() {
        guard !ranked.isEmpty else { return }
        loadMeta(all: true)
    }

    // MARK: Searching

    private func search(after delay: UInt64) {
        searchTask?.cancel()
        guard let state, let place else { return }
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            searching = false; failure = nil; truncated = false
            place.results = []; place.searched = place.query; place.truncated = false
            setResults([])
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                let response = try await state.unifiedSearch(raw, limit: Self.limit)
                guard !Task.isCancelled, let self, self.place === place,
                      place.query.trimmingCharacters(in: .whitespacesAndNewlines) == raw else { return }
                let results = ResultsOrder.merging(response.results, seed: place.seed(for: raw))
                place.results = results
                place.searched = place.query
                place.truncated = response.isTruncated && response.results.count >= Self.limit
                self.truncated = place.truncated
                self.failure = nil
                self.searching = false
                self.setResults(results)
                Log.debug("results: \(results.count) for \(raw)")
            } catch {
                guard !Task.isCancelled, let self, self.place === place else { return }
                self.searching = false
                self.failure = "Search unavailable: " + error.localizedDescription
            }
        }
    }

    private func setResults(_ results: [UnifiedSearchResult]) {
        ranked = results.enumerated().map { ResultRow(result: $0.element, rank: $0.offset, meta: meta[$0.element.id]) }
        arrange(reveal: true)
        loadMeta(all: false)
    }

    private func arrange(reveal: Bool) {
        rows = ResultsOrder.arranged(ranked, sort: sort, kind: kind, foldersFirst: foldersFirst)
        revision &+= 1
        if reveal { revealRevision &+= 1 }
    }

    /// Reads dates, sizes and kinds off the main thread, a hundred rows at a time, the first
    /// hundred (what is on screen) first.
    private func loadMeta(all: Bool) {
        metaTask?.cancel()
        guard let vault = state?.vault else { return }
        let wanted = ranked.filter { all || meta[$0.id] == nil }.map { (id: $0.id, url: vault.url(for: $0.result.file)) }
        guard !wanted.isEmpty else { return }
        let chunks = stride(from: 0, to: wanted.count, by: 100).map { Array(wanted[$0..<min($0 + 100, wanted.count)]) }
        metaTask = Task { [weak self] in
            for chunk in chunks {
                let loaded = await Task.detached(priority: .userInitiated) { ResultMeta.load(chunk) }.value
                guard !Task.isCancelled, let self else { return }
                self.meta.merge(loaded) { $1 }
                self.ranked = self.ranked.map { row in
                    guard let m = loaded[row.id] else { return row }
                    var row = row
                    row.meta = m
                    return row
                }
                // Only an order that reads the metadata moves; otherwise the rows stay put.
                self.arrange(reveal: false)
            }
        }
    }
}
