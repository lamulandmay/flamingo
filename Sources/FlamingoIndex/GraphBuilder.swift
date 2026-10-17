import Foundation
import FlamingoCore

extension IndexStore {
    /// Builds the link graph from sidecars (and trail edges if present) and writes graph.json.
    ///
    /// Nodes are every indexed file, every sidecar target whose file is gone, and every
    /// wikilink target that resolves to nothing (so each link in each sidecar is an edge).
    /// `link` edges point from the commented file to the linked one; weight is the number
    /// of comments making that link. Wikilinks in the body of Markdown notes are edges from
    /// the note, weight 1, as in Obsidian. `extraEdges` between known nodes are merged in.
    public func buildGraph(extraEdges: [Graph.Edge] = []) throws -> Graph {
        try requireVault()   // never recreate `.flamingo` in a folder that was moved away
        let (paths, counts, linking) = try read(snapshot: true) { db in
            (try db.query("SELECT path FROM files ORDER BY path") { $0.string(0) },
             try db.query("SELECT path, count(*) FROM comments GROUP BY path") { ($0.string(0), $0.int(1)) },
             try db.query("SELECT path, text FROM comments WHERE instr(text, '[[') > 0 ORDER BY rowid") { ($0.string(0), $0.string(1)) }
             + db.query("""
                SELECT s.path, group_concat(coalesce(s.title, '') || char(10) || s.text, char(10)) FROM sections s
                JOIN files f ON f.path = s.path
                WHERE f.ext IN ('md', 'markdown', 'mdown', 'mkd', 'mdx') AND (instr(s.text, '[[') > 0 OR instr(s.title, '[[') > 0)
                GROUP BY s.path ORDER BY s.path
                """) { ($0.string(0), $0.string(1)) })
        }
        var nodes: [String: Graph.Node] = [:]
        for p in paths { nodes[p] = Self.node(p) }
        for (p, n) in counts { nodes[p, default: Self.node(p)].commentCount = n }

        let resolver = LinkResolver(paths: paths, aliases: try PathAliases(vault: vault).all())
        // Unresolved targets differing only in case are one node, spelled the same every build.
        var spellings: [String: String] = [:]
        for (_, text) in linking {
            for target in Wikilink.parse(text) where resolver.resolve(target, from: "") == nil {
                spellings[target.lowercased()] = min(spellings[target.lowercased()] ?? target, target)
            }
        }
        var weights: [EdgeKey: Double] = [:]
        for (source, text) in linking {
            var linked = Set<String>()
            for target in Wikilink.parse(text) {
                let dest = resolver.resolve(target, from: source) ?? spellings[target.lowercased()] ?? target
                guard dest != source, linked.insert(dest).inserted else { continue }
                if nodes[dest] == nil { nodes[dest] = Self.node(dest) }
                weights[EdgeKey(source: source, target: dest, kind: .link), default: 0] += 1
            }
        }
        for (key, w) in try mentionEdges(paths: paths) where nodes[key.source] != nil && nodes[key.target] != nil {
            weights[key, default: 0] += w
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
        let rows = try read(snapshot: true) { db in
            try db.query("""
                SELECT path, id, ts, anchor_kind, anchor_value, text, provenance FROM comments
                WHERE instr(text, '[[') > 0 ORDER BY ts DESC, rowid DESC
                """) { (path: $0.string(0), comment: Self.comment($0, 1, provenanceColumn: 6)) }
        }
        let resolver = LinkResolver(paths: try indexedPaths(), aliases: try PathAliases(vault: vault).all())
        var found = rows.compactMap { row -> (FileRef, Comment)? in
            guard row.path != ref.relativePath else { return nil }
            let hits = Wikilink.parse(row.comment.text).contains {
                resolver.resolve($0, from: row.path) == ref.relativePath
            }
            return hits ? (FileRef(relativePath: row.path), row.comment) : nil
        }
        let markdown = try read { db in
            try db.query("""
                SELECT s.path, s.anchor_kind, s.anchor_value, s.text, f.mtime FROM sections s
                JOIN files f ON f.path = s.path WHERE f.ext IN ('md', 'markdown', 'mdown', 'mkd', 'mdx')
                AND instr(s.text, '[[') > 0 AND (s.ord > 0 OR NOT EXISTS (SELECT 1 FROM sections other WHERE other.path = s.path AND other.ord > 0))
                """) { ($0.string(0), Self.anchor($0, 1), $0.string(3), $0.double(4)) }
        }
        for (path, anchor, text, mtime) in markdown where path != ref.relativePath {
            guard Wikilink.parse(text).contains(where: { resolver.resolve($0, from: path) == ref.relativePath }) else { continue }
            let date = Date(timeIntervalSince1970: mtime)
            let id = SidecarFormat.stableID(target: path, timestamp: "markdown", anchor: anchor, text: text, occurrence: 0)
            found.append((FileRef(relativePath: path), Comment(id: id, timestamp: date, anchor: anchor, text: text)))
        }
        return found.sorted { $0.1.timestamp > $1.1.timestamp }
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

/// `Wikilink.Resolver` over the indexed files, by path. The resolver's rules are plan 02's:
/// path, then basename, then case-insensitive; ties go to the linking file's own folder.
struct LinkResolver {
    private let resolver: Wikilink.Resolver

    init(paths: [String], aliases: [String: String] = [:]) { resolver = Wikilink.Resolver(candidates: paths.map(FileRef.init(relativePath:)), aliases: aliases) }

    /// `source` is the linking file's path; `""` when there is none.
    func resolve(_ target: String, from source: String) -> String? {
        (source.isEmpty ? resolver.resolve(target) : resolver.resolve(target, from: FileRef(relativePath: source)))?.relativePath
    }
}
