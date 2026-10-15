import Foundation
import FlamingoCore

extension IndexStore {
    /// Discovered connections: a file whose text names another file by its name. "See
    /// q3-model.xlsx" in a memo, a deck that cites the brief, a note that says "arc launch plan".
    /// One FTS phrase query per distinctively named file; names that are too short, generic, or
    /// that hit everywhere are skipped so the graph gains signal, not noise.
    func mentionEdges(paths: [String]) throws -> [EdgeKey: Double] {
        var candidates: [(path: String, phrase: String)] = []
        for p in paths {
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
                for (source, n) in rows where source != c.path {
                    weights[EdgeKey(source: source, target: c.path, kind: .mention), default: 0] += Double(min(n, 5))
                }
            }
        }
        return weights
    }

    static let mentionQueryCap = 6000
    static let mentionHitCap = 40
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
