import Foundation
import FlamingoCore

/// One row of the sidebar. Nodes are classes so `NSOutlineView` can use them as items.
/// Plan 01 owns.
final class FileNode: Hashable, Identifiable {
    let id: String              // relative path; "" for the vault root (as a pin) and the tree's root
    let name: String
    let ref: FileRef?           // nil for folders
    private(set) weak var parent: FileNode?
    let depth: Int              // the tree's root is -1, pins are 0
    /// The top-level node for a pinned folder.
    let isPin: Bool
    /// `nil` until the folder is first expanded (or revealed into).
    fileprivate(set) var loaded: [FileNode]?

    var isFolder: Bool { ref == nil }
    var ext: String { ref?.ext ?? "" }
    var children: [FileNode] { loaded ?? [] }

    init(id: String, name: String, ref: FileRef?, parent: FileNode?, depth: Int, isPin: Bool = false) {
        self.id = id; self.name = name; self.ref = ref; self.parent = parent; self.depth = depth; self.isPin = isPin
    }

    /// The pin this node hangs from (itself for a pin).
    var pin: FileNode? {
        var n: FileNode? = self
        while let c = n, !c.isPin { n = c.parent }
        return n
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// The sidebar's tree: one top-level node per pin, each folder listed from disk the first
/// time it is opened (`VaultScanner.children(of:)`), never the whole vault. A folder pinned
/// twice (`Documents` and `Documents/work`) appears twice, as separate nodes.
@MainActor
final class FileTree {
    let vault: Vault?
    let pins: Pins
    let root = FileNode(id: "", name: "", ref: nil, parent: nil, depth: -1)
    private var rules: IgnoreRules

    static let empty = FileTree(vault: nil, pins: Pins())

    init(vault: Vault?, pins: Pins) {
        self.vault = vault
        self.pins = pins
        rules = vault.map(VaultScanner.ignoreRules(in:)) ?? .empty
        root.loaded = pins.paths.map { path in
            let name = path.isEmpty ? (vault?.name ?? "") : (path as NSString).lastPathComponent
            return FileNode(id: path, name: name, ref: nil, parent: root, depth: 0, isPin: true)
        }
    }

    var isEmpty: Bool { root.children.isEmpty }

    /// Lists the folder from disk if it hasn't been yet. Returns its children.
    @discardableResult
    func load(_ node: FileNode) -> [FileNode] {
        if let loaded = node.loaded { return loaded }
        node.loaded = list(node, keeping: [])
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
        return true
    }

    /// Re-reads the ignore file (the user may have edited it).
    func reloadRules() {
        if let vault { rules = VaultScanner.ignoreRules(in: vault) }
    }

    /// Loaded folder nodes for a relative folder path, in every pin that shows it.
    func loadedNodes(at folder: String) -> [FileNode] {
        var out: [FileNode] = []
        for pin in root.children {
            if let n = find(folder, from: pin, loading: false), n.loaded != nil { out.append(n) }
        }
        return out
    }

    /// Every loaded folder node, pins included.
    var loadedFolders: [FileNode] {
        var out: [FileNode] = []
        func walk(_ n: FileNode) {
            guard n.isFolder, let kids = n.loaded else { return }
            out.append(n)
            kids.forEach(walk)
        }
        root.children.forEach(walk)
        return out
    }

    /// The node for `path` under the innermost pin that contains it, listing folders on the
    /// way down as needed. `nil` when no pin contains it or it isn't on disk.
    func node(for path: String) -> FileNode? {
        let candidates = root.children.filter { Self.contains($0.id, path) }
        guard let pin = candidates.max(by: { $0.id.count < $1.id.count }) else { return nil }
        return find(path, from: pin, loading: true)
    }

    func node(for ref: FileRef) -> FileNode? { node(for: ref.relativePath) }

    /// `true` when `path` is `folder` or inside it. `""` contains everything.
    static func contains(_ folder: String, _ path: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    // MARK: Private

    private func find(_ path: String, from pin: FileNode, loading: Bool) -> FileNode? {
        guard Self.contains(pin.id, path) else { return nil }
        if path == pin.id { return pin }
        let rest = pin.id.isEmpty ? path : String(path.dropFirst(pin.id.count + 1))
        var node = pin
        var current = pin.id
        for comp in rest.split(separator: "/") {
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
        return VaultScanner.children(of: node.id, in: vault, ignore: rules).map { entry in
            if let n = reuse[entry.id], n.isFolder == entry.isFolder { return n }
            return FileNode(id: entry.id, name: entry.name, ref: entry.ref, parent: node, depth: node.depth + 1)
        }
    }
}
