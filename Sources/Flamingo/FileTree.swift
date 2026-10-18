import Foundation
import FlamingoCore

/// One row of the file explorer. Nodes are classes so `NSOutlineView` can use them as items.
/// Plan 01 owns.
final class FileNode: Hashable, Identifiable {
    let id: String              // relative path; "" for the tree's root, the vault itself
    let name: String
    let ref: FileRef?           // nil for folders
    private(set) weak var parent: FileNode?
    let depth: Int              // the tree's root is -1, the vault's top level 0
    /// A distinct top-level shortcut, never the canonical node for the same path.
    let isPin: Bool
    var isWithinPin: Bool { isPin || parent?.isWithinPin == true }
    /// `nil` until the folder is first expanded (or revealed into).
    fileprivate(set) var loaded: [FileNode]?

    var isFolder: Bool { ref == nil }
    var ext: String { ref?.ext ?? "" }
    var children: [FileNode] { loaded ?? [] }

    init(id: String, name: String, ref: FileRef?, parent: FileNode?, depth: Int, isPin: Bool = false) {
        self.id = id; self.name = name; self.ref = ref; self.parent = parent; self.depth = depth; self.isPin = isPin
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// Obsidian's six file-explorer orders. Folders always come first, by name.
enum FileSort: String, CaseIterable {
    case nameAscending, nameDescending, modifiedNewest, modifiedOldest, createdNewest, createdOldest

    var title: String {
        switch self {
        case .nameAscending: "File name (A to Z)"
        case .nameDescending: "File name (Z to A)"
        case .modifiedNewest: "Modified time (new to old)"
        case .modifiedOldest: "Modified time (old to new)"
        case .createdNewest: "Created time (new to old)"
        case .createdOldest: "Created time (old to new)"
        }
    }

    /// Menu grouping: name, modified, created.
    var group: Int { rawValue.hasPrefix("name") ? 0 : rawValue.hasPrefix("modified") ? 1 : 2 }
}

/// The file explorer's tree: the whole vault, each folder listed from disk the first time it
/// is opened (`VaultScanner.children(of:)`), never the whole vault at once.
@MainActor
final class FileTree {
    let vault: Vault?
    let sort: FileSort
    let root = FileNode(id: "", name: "", ref: nil, parent: nil, depth: -1)
    private var rules: IgnoreRules
    private(set) var pinnedRoots: [FileNode] = []

    static let empty = FileTree(vault: nil, sort: .nameAscending)

    init(vault: Vault?, sort: FileSort) {
        self.vault = vault
        self.sort = sort
        rules = vault.map(VaultScanner.ignoreRules(in:)) ?? .empty
    }

    /// The vault's top level, listed on first use.
    var top: [FileNode] { load(root) }

    /// Projects saved folder bookmarks into independent root items. A parent pin and a
    /// nested pin must never share an outline item: both remain visible and expandable.
    @discardableResult
    func configurePins(_ paths: [String]) -> Bool {
        guard let vault else { return false }
        var seen = Set<String>()
        // The vault root bookmarked is the whole tree, which the explorer already is.
        let valid = paths.map { $0.split(separator: "/").joined(separator: "/") }.filter { path in
            guard !path.isEmpty, seen.insert(path).inserted, !path.split(separator: "/").contains("..") else { return false }
            let url = vault.root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard valid != pinnedRoots.map(\.id) else { return false }
        let old = Dictionary(uniqueKeysWithValues: pinnedRoots.map { ($0.id, $0) })
        listingGeneration &+= 1
        pinnedRoots = valid.map { path in
            old[path] ?? FileNode(id: path, name: path.isEmpty ? vault.name : (path as NSString).lastPathComponent,
                                  ref: nil, parent: root, depth: 0, isPin: true)
        }
        return true
    }

    /// Canonical top-level folders with direct pins removed; loose files stay available
    /// independently of the three-folder preview.
    var unpinnedRoots: [FileNode] {
        let pinned = Set(pinnedRoots.map(\.id))
        let folders = top.filter { $0.isFolder && !pinned.contains($0.id) }
        // Everyday folders lead the compact preview; hidden configuration folders remain
        // available under Show More, with the chosen sort preserved within each group.
        return folders.filter { !$0.name.hasPrefix(".") } + folders.filter { $0.name.hasPrefix(".") }
    }

    /// Keeps the current place visible when the user folds a long list down to three.
    func visibleUnpinnedRoots(showAll: Bool, keepingVisible path: String?) -> [FileNode] {
        let folders = unpinnedRoots
        guard !showAll, folders.count > 3 else { return folders }
        var shown = Array(folders.prefix(3))
        if let path, !pinnedRoots.contains(where: { Self.contains($0.id, path) }),
           let active = folders.first(where: { Self.contains($0.id, path) }), !shown.contains(active) {
            shown[2] = active
        }
        return shown
    }

    /// Lists the folder from disk if it hasn't been yet. Returns its children.
    @discardableResult
    func load(_ node: FileNode) -> [FileNode] {
        if let loaded = node.loaded { return loaded }
        node.loaded = list(node, keeping: [])
        listingGeneration &+= 1
        return node.loaded!
    }

    /// Re-lists a loaded folder, keeping the node objects of entries that are still there so
    /// the outline keeps their expansion and selection. Returns `false` if nothing changed.
    @discardableResult
    func refresh(_ node: FileNode) -> Bool {
        guard let old = node.loaded else { return false }
        let new = list(node, keeping: old)
        guard new.map(ObjectIdentifier.init) != old.map(ObjectIdentifier.init) else { return false }
        node.loaded = new
        listingGeneration &+= 1
        return true
    }

    /// Re-reads the ignore file (the user may have edited it).
    func reloadRules() {
        if let vault { rules = VaultScanner.ignoreRules(in: vault) }
    }

    /// The loaded folder node for a relative folder path, if there is one.
    func loadedNodes(at folder: String) -> [FileNode] {
        ([root] + pinnedRoots).compactMap { start in
            guard let node = find(folder, from: start, loading: false), node.isFolder, node.loaded != nil else { return nil }
            return node
        }
    }

    /// Bumped whenever a folder is listed, re-listed or the pins change.
    private(set) var listingGeneration = 0
    private var folderPathCache: (generation: Int, paths: [String])?

    /// Every folder path the tree knows (loaded folders and the folders they list), for
    /// search to match folder names. Memoized per listing, not walked per keystroke.
    var knownFolderPaths: [String] {
        if let cache = folderPathCache, cache.generation == listingGeneration { return cache.paths }
        var folders = Set<String>()
        func collect(_ node: FileNode) {
            if node.isFolder, !node.id.isEmpty { folders.insert(node.id) }
            for child in node.children { collect(child) }
        }
        collect(root)
        for pin in pinnedRoots { collect(pin) }
        let paths = Array(folders)
        folderPathCache = (listingGeneration, paths)
        return paths
    }

    /// Every loaded folder node, the root included.
    var loadedFolders: [FileNode] {
        var out: [FileNode] = []
        func walk(_ n: FileNode) {
            guard n.isFolder, let kids = n.loaded else { return }
            out.append(n)
            kids.forEach(walk)
        }
        ([root] + pinnedRoots).forEach(walk)
        return out
    }

    /// The node for `path`, listing folders on the way down as needed. `nil` when it isn't
    /// on disk (or is ignored).
    func node(for path: String) -> FileNode? {
        let pins = pinnedRoots.filter { Self.contains($0.id, path) }.sorted { $0.id.count > $1.id.count }
        for pin in pins { if let node = find(path, from: pin, loading: true) { return node } }
        return find(path, from: root, loading: true)
    }

    func node(for ref: FileRef) -> FileNode? { node(for: ref.relativePath) }

    /// `node(for:)`, but a loaded folder whose listing lacks the next step on the way is listed
    /// again first: a file made a moment ago, before the watcher said so, is still found.
    /// `relisted` says a listing changed (the outline must reload). A path that isn't there
    /// even so (ignored, or gone) is remembered until the next listing, so it isn't re-listed
    /// for on every visit.
    func nodeRelisting(for path: String) -> (node: FileNode?, relisted: Bool) {
        if let found = node(for: path) { return (found, false) }
        guard let vault, !path.isEmpty, relistMisses[path] != listingGeneration,
              FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(path).path) else { return (nil, false) }
        var relisted = false
        let starts = pinnedRoots.filter { Self.contains($0.id, path) }.sorted { $0.id.count > $1.id.count } + [root]
        for start in starts {
            var node = start, current = start.id
            let suffix = start.id.isEmpty ? path : String(path.dropFirst(start.id.count + 1))
            var found = true
            for comp in suffix.split(separator: "/") {
                current = current.isEmpty ? String(comp) : current + "/" + comp
                if let next = load(node).first(where: { $0.id == current }) { node = next; continue }
                if refresh(node) { relisted = true }
                guard let next = node.children.first(where: { $0.id == current }) else { found = false; break }
                node = next
            }
            if found { return (node, relisted) }
        }
        relistMisses[path] = listingGeneration
        return (nil, relisted)
    }

    /// Paths `nodeRelisting` couldn't find, with the listing generation they were missed in.
    private var relistMisses: [String: Int] = [:]

    /// `true` when `path` is `folder` or inside it. `""` contains everything.
    static func contains(_ folder: String, _ path: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    // MARK: Private

    private func find(_ path: String, from start: FileNode, loading: Bool) -> FileNode? {
        guard Self.contains(start.id, path) else { return nil }
        if path == start.id { return start }
        var node = start
        var current = start.id
        let suffix = start.id.isEmpty ? path : String(path.dropFirst(start.id.count + 1))
        for comp in suffix.split(separator: "/") {
            current = current.isEmpty ? String(comp) : current + "/" + comp
            let kids = loading ? load(node) : (node.loaded ?? [])
            guard let next = kids.first(where: { $0.id == current }) else { return nil }
            node = next
        }
        return node
    }

    private func list(_ node: FileNode, keeping old: [FileNode]) -> [FileNode] {
        guard let vault, node.isFolder else { return [] }
        var reuse: [String: FileNode] = [:]
        for n in old { reuse[n.id] = n }
        let entries = VaultScanner.children(of: node.id, in: vault, ignore: rules)
        let nodes = entries.map { entry in
            if let n = reuse[entry.id], n.isFolder == entry.isFolder { return n }
            return FileNode(id: entry.id, name: entry.name, ref: entry.ref, parent: node, depth: node.depth + 1)
        }
        return sorted(nodes, in: vault)
    }

    /// `children(of:)` gives folders then files, each by name; this applies `sort`.
    private func sorted(_ nodes: [FileNode], in vault: Vault) -> [FileNode] {
        var folders = nodes.filter(\.isFolder)
        var files = nodes.filter { !$0.isFolder }
        switch sort {
        case .nameAscending:
            break
        case .nameDescending:
            folders.reverse(); files.reverse()
        case .modifiedNewest, .modifiedOldest, .createdNewest, .createdOldest:
            let key: URLResourceKey = sort.group == 1 ? .contentModificationDateKey : .creationDateKey
            let dates = Dictionary(uniqueKeysWithValues: files.map { n in
                (n.id, (try? vault.root.appendingPathComponent(n.id).resourceValues(forKeys: [key]))
                    .flatMap { key == .creationDateKey ? $0.creationDate : $0.contentModificationDate } ?? .distantPast)
            })
            let newest = sort == .modifiedNewest || sort == .createdNewest
            // Stable on ties: `files` is already in name order.
            files = files.enumerated().sorted { a, b in
                let da = dates[a.element.id]!, db = dates[b.element.id]!
                if da != db { return newest ? da > db : da < db }
                return a.offset < b.offset
            }.map(\.element)
        }
        return folders + files
    }
}
