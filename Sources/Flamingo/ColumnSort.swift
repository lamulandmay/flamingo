import AppKit
import CoreServices
import FlamingoCore

/// What Finder's Sort By offers, for the columns.
enum ColumnSortKey: String, CaseIterable, Identifiable, Sendable {
    case name, kind, application, lastOpened, added, modified, created, size, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .application: "Application"
        case .lastOpened: "Date Last Opened"
        case .added: "Date Added"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .size: "Size"
        case .tags: "Tags"
        }
    }

    /// Finder's way: names, kinds, apps and tags A to Z, dates newest first, sizes largest first.
    var ascendingFirst: Bool { [.name, .kind, .application, .tags].contains(self) }

    /// The two ways, as the menu words them: ascending, then descending.
    var directions: (ascending: String, descending: String) {
        switch self {
        case .lastOpened, .added, .modified, .created: ("Oldest First", "Newest First")
        case .size: ("Smallest First", "Largest First")
        default: ("A to Z", "Z to A")
        }
    }
}

/// How every column orders its folder: one order for all of them, as a Finder window has,
/// kept across launches. Plan 01 owns.
struct ColumnSort: Equatable, Sendable {
    var key: ColumnSortKey
    var ascending: Bool

    static let finder = ColumnSort(key: .name, ascending: true)

    static func by(_ key: ColumnSortKey) -> ColumnSort { ColumnSort(key: key, ascending: key.ascendingFirst) }

    /// A pick from the menu: a new key starts its own way; the key in use keeps its way.
    func picked(_ key: ColumnSortKey) -> ColumnSort { self.key == key ? self : .by(key) }
}

enum ColumnOrder {
    /// `entries` in `sort`'s order. `keys` holds each entry's value for the sort, by index;
    /// a missing value (a folder's size, a date Spotlight never saw) goes last either way,
    /// as in Finder, and ties stay in name order. With `foldersFirst` (Finder's "Keep folders
    /// on top"), folders lead when sorting by name.
    static func sorted(_ entries: [ColumnEntry], by sort: ColumnSort, foldersFirst: Bool,
                       keys: [ResultsOrder.Key?] = []) -> [ColumnEntry] {
        // Name order first: the whole order for a name sort, the tie-break for the rest.
        var named = FinderOrder.sorted(Array(entries.indices), by: { entries[$0].name })
        if sort.key == .name {
            if !sort.ascending { named.reverse() }
            let list = named.map { entries[$0] }
            return foldersFirst ? list.filter(\.isFolder) + list.filter { !$0.isFolder } : list
        }
        func key(_ i: Int) -> ResultsOrder.Key? { i < keys.count ? keys[i] : nil }
        let rank = Dictionary(uniqueKeysWithValues: named.enumerated().map { ($1, $0) })
        let known = named.filter { key($0) != nil }.sorted { a, b in
            let order = key(a)!.compare(key(b)!)
            if order == .orderedSame { return rank[a]! < rank[b]! }
            return (order == .orderedAscending) == sort.ascending
        }
        return (known + named.filter { key($0) == nil }).map { entries[$0] }
    }

    /// The resource values `key` reads, beyond what every listing reads.
    static func resourceKeys(for key: ColumnSortKey) -> Set<URLResourceKey> {
        switch key {
        case .name, .application, .lastOpened: []
        case .kind: [.localizedTypeDescriptionKey]
        case .added: [.addedToDirectoryDateKey]
        case .modified: [.contentModificationDateKey]
        case .created: [.creationDateKey]
        case .size: [.fileSizeKey]
        case .tags: [.tagNamesKey]
        }
    }

    /// One entry's value for `key`, read off the main thread. `values` were read with
    /// `resourceKeys(for:)`; `isPackage` is an app or a Keynote file, which has a size.
    static func value(_ entry: ColumnEntry, _ key: ColumnSortKey, values: URLResourceValues?, isPackage: Bool) -> ResultsOrder.Key? {
        switch key {
        case .name: return .text(entry.name)
        case .kind: return values?.localizedTypeDescription.map(ResultsOrder.Key.text)
        case .application:
            guard !entry.isFolder, let app = NSWorkspace.shared.urlForApplication(toOpen: entry.url) else { return nil }
            let name = (try? app.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            return .text(name ?? app.deletingPathExtension().lastPathComponent)
        case .lastOpened: return spotlight(entry.url, kMDItemLastUsedDate).flatMap { ($0 as? Date).map(ResultsOrder.Key.date) }
        case .added: return values?.addedToDirectoryDate.map(ResultsOrder.Key.date)
        case .modified: return values?.contentModificationDate.map(ResultsOrder.Key.date)
        case .created: return values?.creationDate.map(ResultsOrder.Key.date)
        case .size:
            // A folder has none, as Finder's "--"; a package's is Spotlight's, too slow to count here.
            if isPackage { return spotlight(entry.url, kMDItemFSSize).flatMap { ($0 as? NSNumber).map { .number($0.int64Value) } } }
            guard !entry.isFolder else { return nil }
            return values?.fileSize.map { .number(Int64($0)) }
        case .tags:
            guard let tags = values?.tagNames, !tags.isEmpty else { return nil }
            return .text(tags.joined(separator: ", "))
        }
    }

    private static func spotlight(_ url: URL, _ attribute: CFString) -> Any? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, attribute)
    }
}
