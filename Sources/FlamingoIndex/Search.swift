import Foundation
import FlamingoCore
import FlamingoExtract

extension IndexStore {
    // MARK: - Search

    /// Best hits across file content and comments, one content hit per file (at its best
    /// section's anchor). All terms must match; if nothing does, any term may.
    ///
    /// Hybrid: those keyword hits fused (reciprocal rank) with the files whose sections are
    /// nearest the query by meaning, once sections are embedded. A file found only by meaning
    /// opens at its nearest section.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let keyword = try keywordSearch(query, limit: limit)
        var seen = Set<String>()
        let semantic = semanticSections(query, limit: 50)
            .filter { seen.insert($0.path).inserted }
            .map { SearchHit(file: FileRef(relativePath: $0.path), anchor: $0.anchor, snippet: semanticSnippet($0), score: Double($0.score)) }
        guard !semantic.isEmpty else { return keyword }
        let fused = Fusion.fuse([keyword, semantic], weights: [1, Self.semanticWeight]) { $0.commentID?.uuidString ?? $0.file.relativePath }
        return fused.prefix(limit).map { var h = $0.item; h.score = $0.score; return h }
    }

    private func keywordSearch(_ query: String, limit: Int) throws -> [SearchHit] {
        try firstNonEmpty(query) { match in
            let content = try fileHits(match, limit: limit)
            let comments = try commentHits(match, limit: limit).map {
                SearchHit(file: $0.file, anchor: $0.comment.anchor, snippet: $0.snippet, score: $0.score, commentID: $0.comment.id)
            }
            var seen = Set<String>()
            let merged = (content + comments).sorted { $0.score > $1.score }.filter { seen.insert($0.id).inserted }
            return Array(merged.prefix(limit))
        }
    }

    /// Every matching section, ranked, not grouped by file. For retrieval (plan 09).
    /// Keyword and nearest-by-meaning sections, fused by reciprocal rank.
    public func searchSections(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let keyword = try firstNonEmpty(query) { try sectionHits($0, limit: limit) }
        let semantic = semanticSections(query, limit: 50).map {
            SearchHit(file: FileRef(relativePath: $0.path), anchor: $0.anchor, snippet: semanticSnippet($0), score: Double($0.score))
        }
        guard !semantic.isEmpty else { return keyword }
        return Fusion.fuse([keyword, semantic], weights: [1, Self.semanticWeight], key: \.id).prefix(limit).map { var h = $0.item; h.score = $0.score; return h }
    }

    /// Matching comments, ranked.
    public func searchComments(_ query: String, limit: Int = 50) throws -> [CommentHit] {
        guard limit > 0 else { return [] }
        return try firstNonEmpty(query) { try commentHits($0, limit: limit) }
    }

    /// Most recently modified files.
    public func recent(limit: Int = 20) throws -> [FileRef] {
        try read { db in
            try db.query("SELECT path FROM files ORDER BY mtime DESC, path LIMIT ?", max(0, limit)) { FileRef(relativePath: $0.string(0)) }
        }
    }

    /// Fuzzy file-name match for the command palette. Empty query returns `recent`.
    public func files(matching query: String, limit: Int = 50) throws -> [FileRef] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try recent(limit: limit) }
        return FuzzyMatch.rank(q, in: try indexedPaths(), limit: limit).map(FileRef.init(relativePath:))
    }

    public func sections(of ref: FileRef) throws -> [Section] {
        try read { db in
            try db.query("""
                SELECT anchor_kind, anchor_value, title, text FROM sections
                WHERE path = ? AND ord > 0 ORDER BY ord
                """, ref.relativePath) { row -> Section? in
                guard let anchor = Self.anchor(row, 0) else { return nil }
                return Section(anchor: anchor, title: row.optionalString(2), text: row.string(3))
            }.compactMap { $0 }
        }
    }

    public func text(of ref: FileRef) throws -> String? {
        let parts = try read { db in
            try db.query("SELECT text FROM sections WHERE path = ? ORDER BY ord", ref.relativePath) { $0.string(0) }
        }
        guard !parts.isEmpty else { return nil }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Every indexed file, sorted by path.
    public func indexedFiles() throws -> [FileRef] { try indexedPaths().map(FileRef.init(relativePath:)) }

    /// Comment count per file, including sidecars whose file is gone.
    public func commentCounts() throws -> [FileRef: Int] {
        let rows = try read { db in
            try db.query("SELECT path, count(*) FROM comments GROUP BY path") { (FileRef(relativePath: $0.string(0)), $0.int(1)) }
        }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    /// Indexed comments on one file, oldest first.
    public func comments(on ref: FileRef) throws -> [Comment] {
        try read { db in
            try db.query("SELECT id, ts, anchor_kind, anchor_value, text FROM comments WHERE path = ? ORDER BY ts, rowid",
                         ref.relativePath) { Self.comment($0, 0) }
        }
    }

    public func stats() throws -> IndexStats {
        try read(snapshot: true) { db in
            IndexStats(files: try db.scalarInt("SELECT count(*) FROM files"),
                       sections: try db.scalarInt("SELECT count(*) FROM sections"),
                       comments: try db.scalarInt("SELECT count(*) FROM comments"))
        }
    }

    // MARK: - Query plans

    enum Match: Equatable {
        case fts(String)
        /// Plain substrings, for scripts written without spaces (Chinese, Japanese, Thai),
        /// which the unicode61 tokenizer can't split into words.
        case substring([String])
    }

    /// All terms, then any term, then substrings when the query is in an unspaced script.
    static func plan(_ query: String) -> [Match] {
        guard let all = FTSQuery.build(query) else { return [] }
        let terms = FTSQuery.terms(query)
        var plan: [Match] = [.fts(all)]
        if terms.count > 1, let any = FTSQuery.build(query, any: true) { plan.append(.fts(any)) }
        if FTSQuery.isUnspaced(query) { plan.append(.substring(terms.map(\.text))) }
        return plan
    }

    private func firstNonEmpty<T>(_ query: String, _ run: (Match) throws -> [T]) throws -> [T] {
        for match in Self.plan(query) {
            let hits = try run(match)
            if !hits.isEmpty { return hits }
        }
        return []
    }

    // MARK: - Sections

    /// One hit per file, ranked by the file's best-matching section, opened at its best
    /// *anchored* match (a name or title match alone opens the file at the top). Grouping
    /// happens in SQL before the limit, so a few long documents can't crowd out other files.
    private func fileHits(_ match: Match, limit: Int) throws -> [SearchHit] {
        guard case .fts(let q) = match else {
            var seen = Set<String>()
            return try sectionHits(match, limit: limit * 20).filter { seen.insert($0.file.relativePath).inserted }.prefix(limit).map { $0 }
        }
        return try read(snapshot: true) { db in
            let best = try db.query("""
                SELECT s.path, min(sections_fts.rank), sections_fts.rowid, s.ord
                FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid
                WHERE sections_fts MATCH ?1 GROUP BY s.path ORDER BY 2 LIMIT ?2
                """, q, limit) { (path: $0.string(0), score: -$0.double(1), rowid: $0.int(2), ord: $0.int(3)) }
            var pick = Dictionary(best.map { ($0.path, $0.rowid) }, uniquingKeysWith: { a, _ in a })
            let unanchored = best.filter { $0.ord == 0 }.map(\.path)
            if !unanchored.isEmpty {
                let deeper = try db.query("""
                    SELECT s.path, min(sections_fts.rank), sections_fts.rowid
                    FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid
                    WHERE sections_fts MATCH ?1 AND s.ord > 0 AND s.path IN (SELECT value FROM json_each(?2))
                    GROUP BY s.path
                    """, q, Self.json(unanchored)) { ($0.string(0), $0.int(2)) }
                for (path, rowid) in deeper { pick[path] = rowid }
            }
            // One pass over the matches, snippets only for the picked rows. Looking rows up one
            // by one would re-run the MATCH for each, which is slow for a prefix with many terms.
            let snippets = try db.query("""
                WITH picked(id) AS (SELECT value FROM json_each(?2)),
                m AS MATERIALIZED (
                    SELECT rowid AS id,
                        CASE WHEN rowid IN picked THEN snippet(sections_fts, 0, '«', '»', '…', 10) END AS st,
                        CASE WHEN rowid IN picked THEN snippet(sections_fts, 1, '«', '»', '…', 16) END AS sx
                    FROM sections_fts WHERE sections_fts MATCH ?1
                )
                SELECT m.id, s.anchor_kind, s.anchor_value, m.st, m.sx
                FROM m JOIN sections s ON s.rowid = m.id WHERE m.sx IS NOT NULL
                """, q, Self.json(best.compactMap { pick[$0.path] })) {
                ($0.int(0), (anchor: Self.anchor($0, 1), snippet: Self.snippet(title: $0.string(3), text: $0.string(4))))
            }
            let byRow = Dictionary(snippets, uniquingKeysWith: { a, _ in a })
            return best.compactMap { b in
                guard let rowid = pick[b.path], let s = byRow[rowid] else { return nil }
                return SearchHit(file: FileRef(relativePath: b.path), anchor: s.anchor, snippet: s.snippet, score: b.score)
            }
        }
    }

    private func sectionHits(_ match: Match, limit: Int) throws -> [SearchHit] {
        switch match {
        case .fts(let q):
            return try read { db in
                try db.query("""
                    SELECT s.path, s.anchor_kind, s.anchor_value, f.st, f.sx, f.rank FROM (
                        SELECT rowid, rank,
                            snippet(sections_fts, 0, '«', '»', '…', 10) AS st,
                            snippet(sections_fts, 1, '«', '»', '…', 16) AS sx
                        FROM sections_fts WHERE sections_fts MATCH ?1 ORDER BY rank LIMIT ?2
                    ) f JOIN sections s ON s.rowid = f.rowid ORDER BY f.rank
                    """, q, limit) {
                    SearchHit(file: FileRef(relativePath: $0.string(0)), anchor: Self.anchor($0, 1),
                              snippet: Self.snippet(title: $0.string(3), text: $0.string(4)), score: -$0.double(5))
                }
            }
        case .substring(let terms):
            let rows = try substringRows("sections", columns: "path, anchor_kind, anchor_value, title, text",
                                         textColumns: ["text", "coalesce(title, '')"], order: "path, ord", terms: terms, limit: limit) {
                (FileRef(relativePath: $0.string(0)), Self.anchor($0, 1), $0.string(3), $0.string(4))
            }
            return rows.enumerated().map { i, r in
                let body = r.3.range(of: terms[0], options: .caseInsensitive) != nil ? r.3 : r.2
                return SearchHit(file: r.0, anchor: r.1, snippet: Self.substringSnippet(body, terms), score: 1 - Double(i) * 1e-6)
            }
        }
    }

    // MARK: - Comments

    private func commentHits(_ match: Match, limit: Int) throws -> [CommentHit] {
        switch match {
        case .fts(let q):
            return try read { db in
                try db.query("""
                    SELECT c.path, c.id, c.ts, c.anchor_kind, c.anchor_value, c.text, f.snip, f.rank FROM (
                        SELECT rowid, snippet(comments_fts, 0, '«', '»', '…', 16) AS snip, rank
                        FROM comments_fts WHERE comments_fts MATCH ?1 ORDER BY rank LIMIT ?2
                    ) f JOIN comments c ON c.rowid = f.rowid ORDER BY f.rank
                    """, q, limit) {
                    CommentHit(file: FileRef(relativePath: $0.string(0)), comment: Self.comment($0, 1),
                               snippet: Self.clean($0.string(6)), score: -$0.double(7) * Self.commentBoost)
                }
            }
        case .substring(let terms):
            let rows = try substringRows("comments", columns: "path, id, ts, anchor_kind, anchor_value, text",
                                         textColumns: ["text"], order: "ts DESC", terms: terms, limit: limit) {
                (FileRef(relativePath: $0.string(0)), Self.comment($0, 1))
            }
            return rows.enumerated().map { i, r in
                CommentHit(file: r.0, comment: r.1, snippet: Self.substringSnippet(r.1.text, terms),
                           score: (1 - Double(i) * 1e-6) * Self.commentBoost)
            }
        }
    }

    /// Rows whose text contains every term. A scan, so only used when FTS can't help.
    private func substringRows<T>(_ table: String, columns: String, textColumns: [String], order: String,
                                  terms: [String], limit: Int, row: (Row) throws -> T) throws -> [T] {
        func test(_ i: Int) -> String {
            // Caseless scripts skip lower(), which roughly halves the scan.
            let caseless = terms[i].lowercased() == terms[i].uppercased()
            return textColumns.map { caseless ? "instr(\($0), ?\(i + 1)) > 0" : "instr(lower(\($0)), lower(?\(i + 1))) > 0" }
                .joined(separator: " OR ")
        }
        let sql = "SELECT \(columns) FROM \(table) WHERE "
            + terms.indices.map { "(\(test($0)))" }.joined(separator: " AND ")
            + " ORDER BY \(order) LIMIT ?\(terms.count + 1)"
        let values: [(any SQLBindable)?] = terms.map { $0 } + [limit]
        return try read { db in try db.prepare(sql).query(values, row: row) }
    }

    // MARK: - Helpers

    static func anchor(_ row: Row, _ i: Int32) -> FileAnchor? {
        guard let k = row.optionalString(i), let kind = FileAnchor.Kind(rawValue: k) else { return nil }
        return FileAnchor(kind: kind, value: row.string(i + 1))
    }

    /// Reads `id, ts, anchor_kind, anchor_value, text` starting at column `i`.
    static func comment(_ row: Row, _ i: Int32) -> Comment {
        Comment(id: UUID(uuidString: row.string(i)) ?? UUID(),
                timestamp: Date(timeIntervalSince1970: row.double(i + 1)),
                anchor: anchor(row, i + 2), text: row.string(i + 4))
    }

    static func json<T: Encodable>(_ values: [T]) -> String {
        (try? String(decoding: JSONEncoder().encode(values), as: UTF8.self)) ?? "[]"
    }

    /// The text snippet when the match is in the text, else the matching title with the
    /// start of the text for context.
    static func snippet(title: String, text: String) -> String {
        let t = clean(title), x = clean(text)
        if x.contains("«") || t.isEmpty { return x }
        return x.isEmpty ? t : t + " — " + x
    }

    /// A window around the first match, every term marked «…».
    static func substringSnippet(_ text: String, _ terms: [String]) -> String {
        let flat = clean(text)
        guard let first = terms.lazy.compactMap({ flat.range(of: $0, options: .caseInsensitive) }).first else {
            return String(flat.prefix(80))
        }
        let start = flat.index(first.lowerBound, offsetBy: -24, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(first.upperBound, offsetBy: 48, limitedBy: flat.endIndex) ?? flat.endIndex
        var window = String(flat[start..<end])
        for t in terms {
            guard let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: t), options: .caseInsensitive) else { continue }
            window = re.stringByReplacingMatches(in: window, range: NSRange(window.startIndex..., in: window), withTemplate: "«$0»")
        }
        return (start > flat.startIndex ? "…" : "") + window + (end < flat.endIndex ? "…" : "")
    }

    /// Snippets keep the text's own line breaks; a result row wants one line.
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
