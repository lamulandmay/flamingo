import Foundation

/// A lightweight folder catalog derived from graph paths, without scanning the vault.
/// Folder IDs end in `/`; `/` represents the vault root.
public enum GraphFolders {
    /// Adds every source path's folder ancestry, including source folder nodes themselves.
    /// `sourceNodes` can contain files omitted from `graph`: their folders remain available
    /// for zooming, while containment edges only join nodes actually retained in the result.
    /// Existing file nodes and non-containment edges are preserved.
    public static func addingAncestors(to graph: Graph, from sourceNodes: [Graph.Node]? = nil) -> Graph {
        var nodes = graph.nodes
        var present = Set(nodes.map(\.id))
        var folders = Set<String>()
        var sourceFolders: [String: Graph.Node] = [:]

        func collect(_ node: Graph.Node) {
            guard let components = pathComponents(node.id) else { return }
            folders.insert("/")
            let isFolder = node.id.hasSuffix("/")
            if isFolder { sourceFolders[node.id] = node }
            let ancestorCount = components.count - (isFolder ? 0 : 1)
            var path = ""
            for component in components.prefix(ancestorCount) {
                path += component + "/"
                folders.insert(path)
            }
        }

        for node in graph.nodes { collect(node) }
        if let sourceNodes { for node in sourceNodes { collect(node) } }
        for id in folders.sorted() where present.insert(id).inserted {
            nodes.append(sourceFolders[id] ?? Graph.Node(
                id: id, name: id == "/" ? "/" : (String(id.dropLast()) as NSString).lastPathComponent, ext: ""))
        }

        var edges: [Graph.Edge] = []
        var containment = Set<Containment>()
        for edge in graph.edges {
            if edge.kind == .folder {
                guard present.contains(edge.source), present.contains(edge.target),
                      containment.insert(.init(source: edge.source, target: edge.target)).inserted else { continue }
            }
            edges.append(edge)
        }
        for node in nodes {
            guard let components = pathComponents(node.id), !components.isEmpty else { continue }
            let parent = components.count == 1 ? "/" : components.dropLast().joined(separator: "/") + "/"
            guard present.contains(parent),
                  containment.insert(.init(source: parent, target: node.id)).inserted else { continue }
            edges.append(Graph.Edge(source: parent, target: node.id, kind: .folder))
        }
        return Graph(nodes: nodes, edges: edges)
    }

    /// Reject unresolved targets that cannot describe a path inside the vault, along with
    /// synthetic inbox and web notes and Flamingo's own state. Their original graph data survives.
    private static func pathComponents(_ id: String) -> [String]? {
        if id == "/" { return [] }
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\0") else { return nil }
        let path = id.hasSuffix("/") ? String(id.dropLast()) : id
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, first != FileRef.inboxDirectory, first != FileRef.webDirectory, first != ".flamingo",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    private struct Containment: Hashable {
        var source: String
        var target: String
    }
}
