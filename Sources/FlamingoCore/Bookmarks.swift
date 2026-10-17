import Foundation

/// One bookmark: a file, a folder, a saved search, or a group of bookmarks. The fields are
/// Obsidian's (`.obsidian/bookmarks.json`), so a vault's bookmarks file reads the same in
/// both apps. Types Flamingo doesn't show (`graph`, `heading`, `url`) are kept as they are.
public struct Bookmark: Codable, Equatable, Sendable {
    public enum Kind: String, Sendable { case file, folder, search, group }

    public var type: String
    /// Milliseconds since 1970 when it was made. Unique within a `Bookmarks`; it is the id.
    public var ctime: Int64
    /// Vault-relative, for files and folders.
    public var path: String?
    /// For searches.
    public var query: String?
    /// A group's name, or a name the user gave any other bookmark.
    public var title: String?
    /// A group's bookmarks.
    public var items: [Bookmark]?
    /// Obsidian's `#heading` or `#^block` on a file bookmark. Kept, not used.
    public var subpath: String?

    public var kind: Kind? { Kind(rawValue: type) }

    public init(kind: Kind, ctime: Int64, path: String? = nil, query: String? = nil, title: String? = nil, items: [Bookmark]? = nil) {
        self.type = kind.rawValue
        self.ctime = ctime
        self.path = path.map(IgnoreRules.normalize)
        self.query = query
        self.title = title
        self.items = kind == .group ? (items ?? []) : items
    }

    /// What the sidebar shows: the title, else the file or folder name, else the query.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let path { return path.isEmpty ? "/" : (path as NSString).lastPathComponent }
        return query ?? type
    }
}

/// The sidebar's bookmarks, in order: `<vault>/.flamingo/bookmarks.json`, the same
/// `{"items": [...]}` document Obsidian writes. Positions are index paths: `[2]` is the third
/// top-level bookmark, `[2, 0]` the first inside it when it is a group.
public struct Bookmarks: Equatable, Sendable {
    public static let fileName = "bookmarks.json"
    public typealias Path = [Int]

    public private(set) var items: [Bookmark]

    public init(_ items: [Bookmark] = []) { self.items = items }

    private struct Document: Codable { var items: [Bookmark] }

    // MARK: Disk

    /// Compatibility read. Use `loadChecked` when the caller can display a recovery error.
    public static func load(in vault: Vault) -> Bookmarks? { try? loadChecked(in: vault) }

    /// Nil only when absent; unreadable or malformed files throw and are never overwritten.
    public static func loadChecked(in vault: Vault) throws -> Bookmarks? {
        let data: Data
        do { data = try Data(contentsOf: vault.bookmarksURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        return Bookmarks(try JSONDecoder().decode(Document.self, from: data).items)
    }

    /// Loads existing bookmarks or saves first-run defaults. A recovery error leaves the
    /// original bytes intact; the shell can display the error and offer opening the JSON file.
    public static func loadOrCreateChecked(in vault: Vault) throws -> Bookmarks {
        if let b = try loadChecked(in: vault) { return b }
        let pins = Pins.load(in: vault) ?? Pins.defaults(in: vault)
        var b = Bookmarks()
        for p in pins.paths { b.add(Bookmark(kind: .folder, ctime: b.nextCTime(), path: p)) }
        try b.save(in: vault)
        return b
    }

    /// Compatibility API: an unreadable document remains untouched. New callers should use
    /// `loadOrCreateChecked` so the user sees the recovery error instead of an empty sidebar.
    public static func loadOrCreate(in vault: Vault) -> Bookmarks {
        (try? loadOrCreateChecked(in: vault)) ?? Bookmarks()
    }

    /// Writes the file atomically, pretty-printed so `cat` reads it.
    public func save(in vault: Vault) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(Document(items: items)) + Data("\n".utf8), to: vault.bookmarksURL)
    }

    // MARK: Reading

    public func item(at path: Path) -> Bookmark? {
        guard let first = path.first, items.indices.contains(first) else { return nil }
        var b = items[first]
        for i in path.dropFirst() {
            guard let kids = b.items, kids.indices.contains(i) else { return nil }
            b = kids[i]
        }
        return b
    }

    /// The children at `path`: the top level for `[]`, a group's items otherwise.
    public func children(at path: Path) -> [Bookmark] {
        path.isEmpty ? items : item(at: path)?.items ?? []
    }

    /// Every bookmark, depth first, with its position.
    public var all: [(path: Path, bookmark: Bookmark)] {
        var out: [(Path, Bookmark)] = []
        func walk(_ list: [Bookmark], _ prefix: Path) {
            for (i, b) in list.enumerated() {
                out.append((prefix + [i], b))
                if let kids = b.items { walk(kids, prefix + [i]) }
            }
        }
        walk(items, [])
        return out
    }

    /// The first bookmark of `kind` for a file or folder path, anywhere in the tree.
    public func path(of kind: Bookmark.Kind, at target: String) -> Path? {
        let t = IgnoreRules.normalize(target)
        return all.first { $0.bookmark.kind == kind && $0.bookmark.path == t }?.path
    }

    public func path(ctime: Int64) -> Path? { all.first { $0.bookmark.ctime == ctime }?.path }

    /// A `ctime` no bookmark has yet: now, or one past the newest.
    public func nextCTime(now: Date = Date()) -> Int64 {
        let t = Int64(now.timeIntervalSince1970 * 1000)
        let newest = all.map(\.bookmark.ctime).max() ?? 0
        return max(t, newest + 1)
    }

    // MARK: Changing

    public mutating func add(_ b: Bookmark) { items.append(b) }

    /// Inserts at `path`: its last index within the group the rest names, clamped.
    /// Returns the position it landed at, or `nil` when the parent isn't a group.
    @discardableResult
    public mutating func insert(_ b: Bookmark, at path: Path) -> Path? {
        guard let index = path.last else { return nil }
        let parent = Array(path.dropLast())
        var landed: Path?
        update(parent) { list in
            let i = min(max(index, 0), list.count)
            list.insert(b, at: i)
            landed = parent + [i]
        }
        return landed
    }

    /// Removes and returns the bookmark at `path` (a group goes with its contents).
    @discardableResult
    public mutating func remove(at path: Path) -> Bookmark? {
        guard let index = path.last else { return nil }
        var removed: Bookmark?
        update(Array(path.dropLast())) { list in
            if list.indices.contains(index) { removed = list.remove(at: index) }
        }
        return removed
    }

    /// Moves the bookmark at `from` into the group at `parent`, before what is now at
    /// `index` there (positions as they are before the move, as `NSOutlineView` gives them).
    /// A group can't move into itself. Returns the new position.
    @discardableResult
    public mutating func move(from: Path, toParent parent: Path, index: Int) -> Path? {
        guard !from.isEmpty, !parent.starts(with: from), let b = item(at: from) else { return nil }
        guard parent.isEmpty || item(at: parent)?.kind == .group else { return nil }
        var parent = parent
        var index = index
        let fromParent = Array(from.dropLast()), fromIndex = from.last!
        // Removing `from` shifts later siblings, and any path that runs through one of them.
        if fromParent == parent, fromIndex < index { index -= 1 }
        if parent.count > fromParent.count, parent.starts(with: fromParent), parent[fromParent.count] > fromIndex {
            parent[fromParent.count] -= 1
        }
        remove(at: from)
        return insert(b, at: parent + [index])
    }

    /// Changes the bookmark at `path` in place.
    public mutating func modify(at path: Path, _ change: (inout Bookmark) -> Void) {
        guard let index = path.last else { return }
        update(Array(path.dropLast())) { list in
            if list.indices.contains(index) { change(&list[index]) }
        }
    }

    /// Removes every file or folder bookmark for `target`. Returns how many went.
    @discardableResult
    public mutating func removeAll(_ kind: Bookmark.Kind, at target: String) -> Int {
        var n = 0
        while let p = path(of: kind, at: target) { remove(at: p); n += 1 }
        return n
    }

    /// Re-targets file and folder bookmarks after a rename or move: `old` and anything
    /// under it now live under `new`.
    public mutating func rename(_ old: String, to new: String) {
        let o = IgnoreRules.normalize(old), n = IgnoreRules.normalize(new)
        guard !o.isEmpty else { return }
        func fix(_ list: inout [Bookmark]) {
            for i in list.indices {
                if let p = list[i].path, list[i].kind == .file || list[i].kind == .folder {
                    if p == o { list[i].path = n } else if p.hasPrefix(o + "/") { list[i].path = n + p.dropFirst(o.count) }
                }
                if list[i].items != nil { fix(&list[i].items!) }
            }
        }
        fix(&items)
    }

    private mutating func update(_ parent: Path, _ change: (inout [Bookmark]) -> Void) {
        func go(_ list: inout [Bookmark], _ rest: ArraySlice<Int>) {
            guard let i = rest.first else { change(&list); return }
            guard list.indices.contains(i), list[i].items != nil else { return }
            go(&list[i].items!, rest.dropFirst())
        }
        go(&items, parent[...])
    }
}
