import Foundation
import FlamingoCore

extension IndexStore {
    /// Builds the link graph from sidecars (and trail edges if present) and writes graph.json.
    ///
    /// Nodes are every indexed file, every sidecar target whose file is gone, and every
    /// wikilink target that resolves to nothing (so each link in each sidecar is an edge).
    /// `link` edges point from the commented file to the linked one; weight is the number
    /// of comments making that link. `extraEdges` between known nodes are merged in.
    public func buildGraph(extraEdges: [Graph.Edge] = []) throws -> Graph {
        let (paths, counts, linking) = try read { db in
            (try db.query("SELECT path FROM files ORDER BY path") { $0.string(0) },
             try db.query("SELECT path, count(*) FROM comments GROUP BY path") { ($0.string(0), $0.int(1)) },
             try db.query("SELECT path, text FROM comments WHERE instr(text, '[[') > 0 ORDER BY rowid") { ($0.string(0), $0.string(1)) })
        }
        var nodes: [String: Graph.Node] = [:]
        for p in paths { nodes[p] = Self.node(p) }
        for (p, n) in counts { nodes[p, default: Self.node(p)].commentCount = n }

        var resolver = LinkResolver(vault: vault, paths: paths)
        var unresolved: [String: String] = [:]   // lowercased target → first spelling seen
        var weights: [EdgeKey: Double] = [:]
        for (source, text) in linking {
            var linked = Set<String>()
            for target in Wikilink.parse(text) {
                var dest = resolver.resolve(target, from: source)
                if dest == nil {
                    let spelled = unresolved[target.lowercased(), default: target]
                    unresolved[target.lowercased()] = spelled
                    dest = spelled
                }
                guard let dest, dest != source, linked.insert(dest).inserted else { continue }
                if nodes[dest] == nil { nodes[dest] = Self.node(dest) }
                weights[EdgeKey(source: source, target: dest, kind: .link), default: 0] += 1
            }
        }
        for e in extraEdges where e.source != e.target && nodes[e.source] != nil && nodes[e.target] != nil {
            weights[EdgeKey(source: e.source, target: e.target, kind: e.kind), default: 0] += e.weight
        }

        let graph = Graph(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: weights.map { Graph.Edge(source: $0.key.source, target: $0.key.target, kind: $0.key.kind, weight: $0.value) }
                .sorted { ($0.source, $0.target, $0.kind.rawValue) < ($1.source, $1.target, $1.kind.rawValue) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try encoder.encode(graph).write(to: graphURL, options: .atomic)
        return graph
    }

    /// Comments on other files whose wikilinks resolve to `ref`, newest first.
    public func backlinks(to ref: FileRef) throws -> [(FileRef, Comment)] {
        let stem = (ref.name as NSString).deletingPathExtension
        let rows = try read { db in
            try db.query("""
                SELECT path, id, ts, anchor_kind, anchor_value, text FROM comments
                WHERE instr(text, '[[') > 0 ORDER BY ts DESC, rowid DESC
                """) { (path: $0.string(0), comment: Self.comment($0, 1)) }
        }
        var resolver = LinkResolver(vault: vault, paths: try indexedPaths())
        return rows.compactMap { row -> (FileRef, Comment)? in
            guard row.path != ref.relativePath, row.comment.text.range(of: stem, options: .caseInsensitive) != nil else { return nil }
            let hits = Wikilink.parse(row.comment.text).contains {
                $0.range(of: stem, options: .caseInsensitive) != nil && resolver.resolve($0, from: row.path) == ref.relativePath
            }
            return hits ? (FileRef(relativePath: row.path), row.comment) : nil
        }
    }

    static func node(_ path: String) -> Graph.Node {
        let ref = FileRef(relativePath: path)
        return Graph.Node(id: path, name: ref.name, ext: ref.ext)
    }
}

struct EdgeKey: Hashable {
    var source: String
    var target: String
    var kind: Graph.Edge.Kind
}

/// `Wikilink.resolve`, preferring a match in the linking file's own folder, memoized.
struct LinkResolver {
    let vault: Vault
    let all: [FileRef]
    let exact: Set<String>
    let byFolder: [String: [FileRef]]
    private var memo: [String: String?] = [:]

    init(vault: Vault, paths: [String]) {
        self.vault = vault
        all = paths.map(FileRef.init(relativePath:))
        exact = Set(paths)
        byFolder = Dictionary(grouping: all) { ($0.relativePath as NSString).deletingLastPathComponent }
    }

    mutating func resolve(_ target: String, from source: String) -> String? {
        if exact.contains(target) { return target }
        let folder = (source as NSString).deletingLastPathComponent
        let key = folder + "\u{0}" + target
        if let hit = memo[key] { return hit }
        let local = byFolder[folder].flatMap { Wikilink.resolve(target, in: vault, candidates: $0) }
        let found = (local ?? Wikilink.resolve(target, in: vault, candidates: all))?.relativePath
        memo[key] = found
        return found
    }
}
