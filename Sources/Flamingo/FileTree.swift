import Foundation
import FlamingoCore

/// A folder tree built from the flat `VaultScanner` list. Nodes are classes so
/// `NSOutlineView` can use them as items. Plan 01 owns.
final class FileNode: Hashable, Identifiable {
    let id: String              // relative path; "" for the root
    let name: String
    let ref: FileRef?           // nil for folders
    private(set) var children: [FileNode] = []
    private(set) weak var parent: FileNode?
    let depth: Int              // root is -1, top-level items are 0

    var isFolder: Bool { ref == nil }
    var ext: String { ref?.ext ?? "" }

    init(id: String, name: String, ref: FileRef?, parent: FileNode?, depth: Int) {
        self.id = id; self.name = name; self.ref = ref; self.parent = parent; self.depth = depth
    }

    fileprivate func add(_ child: FileNode) { children.append(child) }

    fileprivate func sortChildren() {
        children.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for c in children where c.isFolder { c.sortChildren() }
    }

    /// Number of files beneath this node (files count as 1).
    lazy var fileCount: Int = isFolder ? children.reduce(0) { $0 + $1.fileCount } : 1

    /// Every ancestor folder, nearest first, excluding the root.
    var ancestors: [FileNode] {
        var out: [FileNode] = []
        var p = parent
        while let n = p, n.depth >= 0 { out.append(n); p = n.parent }
        return out
    }

    /// Depth-first, pre-order, honouring an expansion predicate.
    func visibleRows(isExpanded: (FileNode) -> Bool, into out: inout [FileNode]) {
        for c in children {
            out.append(c)
            if c.isFolder, isExpanded(c) { c.visibleRows(isExpanded: isExpanded, into: &out) }
        }
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

struct FileTree {
    let root: FileNode
    private(set) var byPath: [String: FileNode] = [:]

    static let empty = FileTree(files: [])

    init(files: [FileRef]) {
        root = FileNode(id: "", name: "", ref: nil, parent: nil, depth: -1)
        byPath[""] = root
        for f in files {
            let comps = f.relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !comps.isEmpty else { continue }
            var parent = root
            var path = ""
            for (i, comp) in comps.enumerated() {
                path = path.isEmpty ? comp : path + "/" + comp
                let isLast = i == comps.count - 1
                if isLast {
                    let node = FileNode(id: path, name: comp, ref: f, parent: parent, depth: i)
                    parent.add(node)
                    byPath[path] = node
                } else if let existing = byPath[path] {
                    parent = existing
                } else {
                    let node = FileNode(id: path, name: comp, ref: nil, parent: parent, depth: i)
                    parent.add(node)
                    byPath[path] = node
                    parent = node
                }
            }
        }
        root.sortChildren()
    }

    func node(for ref: FileRef) -> FileNode? { byPath[ref.relativePath] }
    func node(at path: String) -> FileNode? { byPath[path] }

    /// Folders expanded by default: depth 0 only.
    var defaultExpanded: Set<String> {
        Set(root.children.filter(\.isFolder).map(\.id))
    }

    var isEmpty: Bool { root.children.isEmpty }
}
