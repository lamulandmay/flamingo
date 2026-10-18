import Foundation
import FlamingoCore

extension IndexStore {
    /// Builds the link graph from sidecars (and trail edges if present) and writes graph.json
    /// when it differs from what this process last wrote there.
    ///
    /// Nodes are every indexed file, every sidecar target whose file is gone, and every
    /// wikilink target that resolves to nothing (so each link in each sidecar is an edge).
    /// `link` edges point from the commented file to the linked one; weight is the number
    /// of comments making that link. Wikilinks in the body of Markdown notes are edges from
    /// the note, weight 1, as in Obsidian. `extraEdges` between known nodes are merged in.
    /// `mentionsReuseFor` is `mentionEdges`'.
    public func buildGraph(extraEdges: [Graph.Edge] = [], mentionsReuseFor: TimeInterval = 0) throws -> Graph {
        try requireVault()   // never recreate `.flamingo` in a folder that was moved away
        let (paths, counts, linking, written) = try read(snapshot: true) { db in
            (try db.query("SELECT path FROM files ORDER BY path") { $0.string(0) },
             try db.query("SELECT path, count(*) FROM comments GROUP BY path") { ($0.string(0), $0.int(1)) },
             try db.query("SELECT path, text FROM comments WHERE instr(text, '[[') > 0 AND origin != 'ai' ORDER BY rowid") { ($0.string(0), $0.string(1)) }
             + db.query("""
                SELECT s.path, group_concat(coalesce(s.title, '') || char(10) || s.text, char(10)) FROM sections s
                JOIN files f ON f.path = s.path
                WHERE f.ext IN ('md', 'markdown', 'mdown', 'mkd', 'mdx') AND (instr(s.text, '[[') > 0 OR instr(s.title, '[[') > 0)
                GROUP BY s.path ORDER BY s.path
                """) { ($0.string(0), $0.string(1)) },
             // Links a model wrote into a reply are suggestions, not links a person made.
             try db.query("SELECT path, text FROM comments WHERE instr(text, '[[') > 0 AND origin = 'ai' ORDER BY rowid") { ($0.string(0), $0.string(1)) })
        }
        var nodes: [String: Graph.Node] = [:]
        nodes.reserveCapacity(paths.count + counts.count)
        for p in paths { nodes[p] = Self.node(p) }
        // A thought on a folder (`.flamingo/notes/<folder>.md`) counts on the folder's node (`folder/`),
        // which is where the graph draws folders; anything else without a file keeps its own node.
        let fileSet = Set(paths)
        var folderNotes = Set<String>()
        for (p, n) in counts {
            if !fileSet.contains(p), !FileRef(relativePath: p).isVirtual, isDirectory(p) {
                let id = p + "/"
                folderNotes.insert(p)
                nodes[id, default: Graph.Node(id: id, name: FileRef(relativePath: p).name, ext: "")].commentCount += n
            } else {
                nodes[p, default: Self.node(p)].commentCount = n
            }
        }
        func sourceID(_ path: String) -> String { folderNotes.contains(path) ? path + "/" : path }

        let resolver = LinkResolver(paths: paths, aliases: try PathAliases(vault: vault).all())
        // Unresolved targets differing only in case are one node, spelled the same every build.
        var spellings: [String: String] = [:]
        for (_, text) in linking + written {
            for target in Wikilink.parse(text) where resolver.resolve(target, from: "") == nil {
                spellings[target.lowercased()] = min(spellings[target.lowercased()] ?? target, target)
            }
        }
        var weights: [EdgeKey: Double] = [:]
        func addLinks(_ rows: [(String, String)], kind: Graph.Edge.Kind) {
            for (source, text) in rows {
                var linked = Set<String>()
                let from = sourceID(source)
                for target in Wikilink.parse(text) {
                    let dest = resolver.resolve(target, from: source) ?? spellings[target.lowercased()] ?? target
                    guard dest != source, linked.insert(dest).inserted else { continue }
                    if nodes[dest] == nil { nodes[dest] = Self.node(dest) }
                    if nodes[from] == nil { nodes[from] = Self.node(from) }
                    weights[EdgeKey(source: from, target: dest, kind: kind), default: 0] += 1
                }
            }
        }
        addLinks(linking, kind: .link)
        addLinks(written, kind: .related)
        for (key, w) in try mentionEdges(paths: paths, reuseFor: mentionsReuseFor) where nodes[key.source] != nil && nodes[key.target] != nil {
            weights[key, default: 0] += w
        }
        for e in extraEdges where e.source != e.target && nodes[e.source] != nil && nodes[e.target] != nil {
            weights[EdgeKey(source: e.source, target: e.target, kind: e.kind), default: 0] += e.weight
        }

        let graph = Graph(
            nodes: Self.sortedNodes(nodes, files: paths, fileSet: fileSet),
            edges: weights.map { Graph.Edge(source: $0.key.source, target: $0.key.target, kind: $0.key.kind, weight: $0.value) }
                .sorted { ($0.source, $0.target, $0.kind.rawValue) < ($1.source, $1.target, $1.kind.rawValue) })
        try writeGraphFile(graph)
        return graph
    }

    /// `nodes` by ID. `files` come from SQLite already in order (byte order, which is Swift's
    /// for normalized text), so the sort mostly confirms runs instead of shuffling a whole disk.
    private static func sortedNodes(_ nodes: [String: Graph.Node], files: [String], fileSet: Set<String>) -> [Graph.Node] {
        guard fileSet.count == files.count else { return nodes.values.sorted { $0.id < $1.id } }
        var ids = files
        ids.reserveCapacity(nodes.count)
        if nodes.count > files.count { ids += nodes.keys.filter { !fileSet.contains($0) }.sorted() }
        ids.sort()
        return ids.map { nodes[$0]! }
    }

    /// Writes graph.json unless it already holds this graph. On a whole disk the file is tens
    /// of megabytes and most rebuilds change nothing in it; one changed or removed since it
    /// was written here is written again.
    private func writeGraphFile(_ graph: Graph) throws {
        let path = graphURL.path, fingerprint = Self.fingerprint(graph)
        if let last = Self.graphFilesLock.withLock({ Self.graphFiles[path] }),
           last.fingerprint == fingerprint, last.stamp == Self.stamp(path) { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try encoder.encode(graph).write(to: graphURL, options: .atomic)
        let written = (fingerprint: fingerprint, stamp: Self.stamp(path))
        Self.graphFilesLock.withLock { Self.graphFiles[path] = written }
    }

    /// What each graph.json was last written with, in this process.
    nonisolated(unsafe) private static var graphFiles: [String: (fingerprint: Int, stamp: [Int])] = [:]
    private static let graphFilesLock = NSLock()

    /// The file as it sits on disk: inode, size and modification time. Empty when it's gone.
    private static func stamp(_ path: String) -> [Int] {
        var st = stat()
        guard stat(path, &st) == 0 else { return [] }
        return [Int(truncatingIfNeeded: st.st_ino), Int(st.st_size), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
    }

    /// A hash of everything graph.json says, over the exact bytes of every string.
    private static func fingerprint(_ graph: Graph) -> Int {
        var h = Hasher()
        func add(_ s: String) {
            var s = s
            s.withUTF8 { h.combine(bytes: UnsafeRawBufferPointer($0)) }
            h.combine(0xFF as UInt8)   // never in UTF-8: keeps "ab"+"c" apart from "a"+"bc"
        }
        h.combine(graph.nodes.count)
        for n in graph.nodes { add(n.id); add(n.name); add(n.ext); h.combine(n.commentCount) }
        h.combine(graph.edges.count)
        for e in graph.edges { add(e.source); add(e.target); add(e.kind.rawValue); h.combine(e.weight) }
        return h.finalize()
    }

    /// Comments on other files whose wikilinks resolve to `ref`, newest first.
    public func backlinks(to ref: FileRef) throws -> [(FileRef, Comment)] {
        let rows = try read(snapshot: true) { db in
            try db.query("""
                SELECT path, id, ts, anchor_kind, anchor_value, text, provenance, meta FROM comments
                WHERE instr(text, '[[') > 0 ORDER BY ts DESC, rowid DESC
                """) { (path: $0.string(0), comment: Self.comment($0, 1, provenanceColumn: 6, metaColumn: 7)) }
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
