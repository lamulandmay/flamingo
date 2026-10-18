import Foundation
import FlamingoCore

extension IndexStore {
    /// Discovered connections: a file whose text names another file by its name. "See
    /// q3-model.xlsx" in a memo, a deck that cites the brief, a note that says "arc launch plan".
    /// One FTS phrase query per distinctively named file; names that are too short, generic, or
    /// that hit everywhere are skipped so the graph gains signal, not noise.
    ///
    /// With `reuseFor`, an answer younger than that many seconds is returned as it was: on a
    /// whole disk this is thousands of phrase queries, most of a graph build, and a disk's
    /// churn (logs, caches) rarely names anything. Edges to files gone since drop out where
    /// the caller keeps only edges between nodes it has.
    func mentionEdges(paths: [String], reuseFor maxAge: TimeInterval = 0) throws -> [EdgeKey: Double] {
        if maxAge > 0, let last = mentions.lock.withLock({ mentions.last }), Date().timeIntervalSince(last.made) < maxAge {
            return last.edges
        }
        let edges = try computeMentionEdges(paths: paths)
        mentions.lock.withLock { mentions.last = (Date(), edges) }
        return edges
    }

    private func computeMentionEdges(paths: [String]) throws -> [EdgeKey: Double] {
        var candidates: [(path: String, phrase: String)] = []
        for p in paths where !Self.isMachineListing(p) {
            guard let phrase = Self.mentionPhrase(for: p) else { continue }
            candidates.append((p, phrase))
        }
        if candidates.count > Self.mentionQueryCap {
            // A whole-disk vault: keep the documents people actually write about.
            candidates = candidates.filter { Self.documentExts.contains(FileRef(relativePath: $0.path).ext) }
            candidates = Array(candidates.prefix(Self.mentionQueryCap))
        }
        guard !candidates.isEmpty else { return [:] }
        var weights: [EdgeKey: Double] = [:]
        try read(snapshot: true) { db in
            let stmt = try db.prepare("""
                SELECT s.path, count(*) FROM sections_fts f JOIN sections s ON s.rowid = f.rowid
                WHERE sections_fts MATCH ? GROUP BY s.path LIMIT ?
                """)
            for c in candidates {
                let rows = try stmt.query([c.phrase, Self.mentionHitCap + 1]) { ($0.string(0), $0.int(1)) }
                // Hitting everywhere means the name is a common phrase, not a reference.
                guard rows.count <= Self.mentionHitCap else { continue }
                for (source, n) in rows where source != c.path && !Self.isMachineListing(source) {
                    weights[EdgeKey(source: source, target: c.path, kind: .mention), default: 0] += Double(min(n, 5))
                }
            }
        }
        return Self.strongestMentions(weights)
    }

    static let mentionQueryCap = 6000
    static let mentionHitCap = 40
    /// A file that names more files than this is a list, not a reference; keep its strongest.
    static let mentionSourceCap = 20
    /// Mentions a file keeps, either direction. A guess is worth showing only when it is
    /// among the few strongest; past that the graph is noise.
    static let mentionNodeCap = 5

    /// The strongest mentions first, each kept while its naming file is under
    /// `mentionSourceCap` and both of its files are under `mentionNodeCap`. Deterministic:
    /// ties go by path.
    static func strongestMentions(_ weights: [EdgeKey: Double]) -> [EdgeKey: Double] {
        let ranked = weights.sorted {
            $0.value != $1.value ? $0.value > $1.value : ($0.key.source, $0.key.target) < ($1.key.source, $1.key.target)
        }
        var named: [String: Int] = [:], degree: [String: Int] = [:]
        var kept: [EdgeKey: Double] = [:]
        for (key, w) in ranked {
            guard named[key.source, default: 0] < mentionSourceCap,
                  degree[key.source, default: 0] < mentionNodeCap,
                  degree[key.target, default: 0] < mentionNodeCap else { continue }
            named[key.source, default: 0] += 1
            degree[key.source, default: 0] += 1
            degree[key.target, default: 0] += 1
            kept[key] = w
        }
        return kept
    }

    /// Files that list other files' names for a machine, not a reader: package records and
    /// manifests, lockfiles, logs, transcripts, and anything inside an installed package, a
    /// build folder or a hidden folder. They neither mention nor are mentioned.
    static func isMachineListing(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let name = parts.last?.lowercased() else { return true }
        for dir in parts.dropLast() {
            let d = dir.lowercased()
            if d.hasPrefix(".") || machineFolders.contains(d) || d.hasSuffix(".dist-info") || d.hasSuffix(".egg-info") { return true }
        }
        if machineFiles.contains(name) { return true }
        return machineExts.contains((name as NSString).pathExtension)
    }

    static let machineFolders: Set<String> = [
        "conda-meta", "site-packages", "dist-packages", "node_modules", "bower_components", "build",
        "deriveddata", "pods", "__pycache__", "venv", "anaconda3", "miniconda3", "miniforge3",
    ]
    static let machineFiles: Set<String> = [
        "record", "paths.json", "installer", "wheel", "top_level.txt", "sources.txt", "package-lock.json",
        "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock", "pipfile.lock", "cargo.lock",
        "gemfile.lock", "composer.lock", "podfile.lock", "go.sum", "packages.lock.json", "uv.lock",
    ]
    static let machineExts: Set<String> = ["log", "jsonl", "lock"]
    static let documentExts: Set<String> = ["pptx", "key", "docx", "pages", "xlsx", "numbers", "pdf", "md", "markdown", "txt", "csv", "rtf"]

    static let genericStems: Set<String> = [
        "readme", "index", "notes", "note", "untitled", "document", "image", "photo", "screenshot",
        "scan", "draft", "final", "copy", "template", "main", "test", "tests", "data", "report",
        "summary", "overview", "todo", "misc", "temp", "new", "old", "backup", "export", "import",
        "config", "settings", "license", "changelog", "makefile", "package", "contents", "info",
    ]

    /// The system word list, lowercased, so plain English file names don't become references.
    static let dictionaryWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// The FTS phrase that finds this file by name, or nil when the name isn't worth searching.
    static func mentionPhrase(for path: String) -> String? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.count >= 4, stem.count <= 60 else { return nil }
        let lower = stem.lowercased()
        if genericStems.contains(lower) { return nil }
        // Camera, hash, and timestamp names: IMG_0231, DSC_, a1b2c3d4…, 2026-10-14 10.22.01.
        if lower.hasPrefix("img_") || lower.hasPrefix("dsc") || lower.hasPrefix("screen shot") || lower.hasPrefix("screenshot") { return nil }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty, tokens.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        if tokens.count == 1 {
            // A lone ordinary word ("forecast", "budget") is a word, not a reference.
            guard tokens[0].count >= 6, !genericStems.contains(tokens[0]), !dictionaryWords.contains(tokens[0]) else { return nil }
            if tokens[0].allSatisfy({ $0.isHexDigit }) { return nil }
        }
        let distinctive = tokens.filter { $0.count >= 3 || $0.contains(where: \.isNumber) }
        guard !distinctive.isEmpty else { return nil }
        return "\"" + tokens.joined(separator: " ").replacingOccurrences(of: "\"", with: "") + "\""
    }
}

/// The last `mentionEdges` answer and when it was worked out.
final class MentionMemo: @unchecked Sendable {
    let lock = NSLock()
    var last: (made: Date, edges: [EdgeKey: Double])?
}
