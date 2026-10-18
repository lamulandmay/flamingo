import Foundation

/// A lightweight folder catalog derived from graph paths, without scanning the vault.
/// Folder IDs end in `/`; `/` represents the vault root.
public enum GraphFolders {
    /// Adds every source path's folder ancestry, including source folder nodes themselves.
    /// `sourceNodes` can contain files omitted from `graph`: their folders remain available
    /// for zooming, while containment edges only join nodes actually retained in the result.
    /// Existing file nodes and non-containment edges are preserved.
    ///
    /// A whole disk is close to a million source paths, so each is read once as UTF-8, never
    /// split, and a file in the same folder as the one before costs one comparison.
    public static func addingAncestors(to graph: Graph, from sourceNodes: [Graph.Node]? = nil) -> Graph {
        var nodes = graph.nodes
        var present = Set<String>(minimumCapacity: nodes.count)
        for node in nodes { present.insert(node.id) }
        let uniqueIDs = present.count == nodes.count
        var folders = Set<Substring>()
        var sawRoot = false
        var sourceFolders: [String: Graph.Node] = [:]
        var lastStart: Substring?

        func collect(_ node: Graph.Node, parentEnd: Int?) {
            let id = node.id
            guard let parentEnd else { return }
            sawRoot = true
            let isFolder = id.utf8.last == slash
            if isFolder { sourceFolders[id] = node }
            // A folder is in the catalog itself; a file starts at its parent. Ancestors of a
            // folder already there are there too.
            guard id != "/" else { return }
            var folder = isFolder ? id[...] : Substring(id.utf8.prefix(parentEnd))
            guard !folder.isEmpty, folder != lastStart else { return }
            lastStart = folder
            while folders.insert(folder).inserted {
                guard let cut = folder.utf8.dropLast().lastIndex(of: slash) else { break }
                folder = Substring(folder.utf8[...cut])
            }
        }

        let ends = graph.nodes.map { parentEnd(of: $0.id) }
        for (node, end) in zip(graph.nodes, ends) { collect(node, parentEnd: end) }
        if let sourceNodes { for node in sourceNodes { collect(node, parentEnd: parentEnd(of: node.id)) } }

        var catalog = folders.map(String.init)
        if sawRoot { catalog.append("/") }
        catalog.sort()
        var added: [Int?] = []
        for id in catalog where present.insert(id).inserted {
            let node = sourceFolders[id] ?? Graph.Node(id: id, name: id == "/" ? "/" : folderName(id), ext: "")
            nodes.append(node)
            added.append(parentEnd(of: node.id))
        }

        var edges: [Graph.Edge] = []
        edges.reserveCapacity(graph.edges.count + nodes.count)
        var containment = Set<Containment>()
        var hadContainment = false
        for edge in graph.edges {
            if edge.kind == .folder {
                hadContainment = true
                guard present.contains(edge.source), present.contains(edge.target),
                      containment.insert(.init(source: edge.source, target: edge.target)).inserted else { continue }
            }
            edges.append(edge)
        }
        // Each node gets one containment edge at most, so only existing ones or a repeated ID
        // can make a duplicate.
        let dedupe = hadContainment || !uniqueIDs
        var lastParent: (end: Substring, id: String, present: Bool)?
        for (node, end) in zip(nodes, ends + added) {
            guard node.id != "/", let end else { continue }
            let parent: String, known: Bool
            if end == 0 {
                parent = "/"; known = present.contains(parent)
            } else {
                let prefix = Substring(node.id.utf8.prefix(end))
                if let last = lastParent, last.end == prefix {
                    parent = last.id; known = last.present
                } else {
                    parent = String(prefix); known = present.contains(parent)
                    lastParent = (prefix, parent, known)
                }
            }
            guard known else { continue }
            if dedupe, !containment.insert(.init(source: parent, target: node.id)).inserted { continue }
            edges.append(Graph.Edge(source: parent, target: node.id, kind: .folder))
        }
        return Graph(nodes: nodes, edges: edges)
    }

    private static let slash = UInt8(ascii: "/")

    /// Where `id`'s parent folder ID ends: the offset just past its last `/` before the name
    /// (`a/b/` in both `a/b/c` and `a/b/c/`), 0 for something at the root, and for `/` itself.
    /// Nil for unresolved targets that cannot describe a path inside the vault, along with
    /// synthetic inbox and web notes and Flamingo's own state. Their original graph data survives.
    static func parentEnd(of id: String) -> Int? {
        if id == "/" { return 0 }
        let utf8 = id.utf8
        guard let first = utf8.first, first != slash else { return nil }
        // A folder's trailing slash ends its last component.
        let end = utf8.last == slash ? utf8.count - 1 : utf8.count
        var offset = 0, start = 0, parent = 0, dotsOnly = true

        // Components are never empty, `.` or `..`; the first is never one of Flamingo's own.
        func valid(upTo i: Int) -> Bool {
            let length = i - start
            if length == 0 || (dotsOnly && length <= 2) { return false }
            if start == 0 {
                let name = utf8.prefix(length)
                if name.elementsEqual(FileRef.inboxDirectory.utf8) || name.elementsEqual(FileRef.webDirectory.utf8)
                    || name.elementsEqual(".flamingo".utf8) { return false }
            }
            return true
        }

        for byte in utf8 {
            if byte == 0 { return nil }
            if offset < end {
                if byte == slash {
                    guard valid(upTo: offset) else { return nil }
                    parent = offset + 1; start = offset + 1; dotsOnly = true
                } else if byte != UInt8(ascii: ".") {
                    dotsOnly = false
                }
            }
            offset += 1
        }
        return valid(upTo: end) ? parent : nil
    }

    /// The last component of a folder ID: `b` for `a/b/`.
    private static func folderName(_ id: String) -> String {
        let inner = id.utf8.dropLast()
        guard let cut = inner.lastIndex(of: slash) else { return String(Substring(inner)) }
        return String(Substring(inner[inner.index(after: cut)...]))
    }

    private struct Containment: Hashable {
        var source: String
        var target: String
    }
}
