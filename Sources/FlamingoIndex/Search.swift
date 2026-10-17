import Foundation
import FlamingoCore
import FlamingoExtract

extension IndexStore {
    // MARK: - Search

    /// Best hits across file content and comments, one content hit per file (at its best
    /// section's anchor). All terms must match; if nothing does, any term may (question words
    /// like "what" and "did" aside).
    ///
    /// Hybrid: those keyword hits fused (weighted reciprocal rank, see `hybrid`) with the files
    /// whose passages or thoughts are nearest the query by meaning, once embedded. A file found
    /// only by meaning opens at its best passage, whose best sentence is the snippet.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        try search(query, inFolder: nil, limit: limit)
    }

    public func search(_ query: String, inFolder folder: String?, limit: Int = 50, includeSemantic: Bool = true) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let (keyword, strength) = try keywordSearch(query, limit: limit, folder: folder)
        guard includeSemantic else { return keyword }
        // One meaning hit per file (its best passage or thought), best first.
        let semantic = Self.bestPerFile(semanticSections(query, limit: 50, folder: folder))
            .map { (hit: semanticHit($0, query: query), relevance: $0.relevance) }
        guard !semantic.isEmpty else { return keyword }
        let key = { (h: SearchHit) in h.commentID?.uuidString ?? h.file.relativePath }
        return Self.hybrid(keyword: keyword.map { ($0, key($0)) }, strength: strength, query: query,
                           semantic: semantic.map { ($0.hit, key($0.hit), $0.relevance) }, limit: limit)
    }

    private func keywordSearch(_ query: String, limit: Int, folder: String?) throws -> ([SearchHit], KeywordStrength) {
        let (hits, strength) = try rankedStrategies(query, key: { $0.commentID?.uuidString ?? $0.file.relativePath }) { match in
            let content = try fileHits(match, limit: limit, folder: folder)
            let comments = try commentHits(match, limit: limit, folder: folder).map {
                SearchHit(file: $0.file, anchor: $0.comment.anchor, snippet: $0.snippet, score: $0.score, commentID: $0.comment.id)
            }
            var seen = Set<String>()
            let merged = (content + comments).sorted { $0.score > $1.score }.filter { seen.insert($0.id).inserted }
            return Array(merged.prefix(limit))
        }
        return (Array(hits.prefix(limit)), strength)
    }

    /// Every matching section, ranked, not grouped by file. For retrieval (plan 09).
    /// Keyword and nearest-by-meaning sections (and thoughts), fused by weighted reciprocal rank.
    public func searchSections(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        try searchSections(query, inFolder: nil, limit: limit)
    }

    public func searchSections(_ query: String, inFolder folder: String?, limit: Int = 50, includeSemantic: Bool = true) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        // Keyed by section (not the refined line a hit opens at), so a section found both ways fuses.
        let (keywordHits, strength) = try rankedStrategies(query, key: { $0.key }) { try sectionHits($0, limit: limit, folder: folder) }
        let keyword = Array(keywordHits.prefix(limit))
        guard includeSemantic else { return keyword.map(\.hit) }
        let semantic = semanticSections(query, limit: 50, folder: folder).map {
            (semanticHit($0, query: query), $0.commentID.map { "#comment:" + $0.uuidString } ?? Self.sectionKey($0.path, $0.anchor), $0.relevance)
        }
        guard !semantic.isEmpty else { return keyword.map(\.hit) }
        return Self.hybrid(keyword: keyword, strength: strength, query: query, semantic: semantic, limit: limit)
    }

    static func sectionKey(_ path: String, _ anchor: FileAnchor?) -> String { path + "|" + (anchor?.rendered ?? "") }

    /// A semantic hit as a search hit: opens at its section (or thought), explains itself with
    /// the matching passage.
    func semanticHit(_ hit: SemanticHit, query: String) -> SearchHit {
        SearchHit(file: FileRef(relativePath: hit.path), anchor: Self.passageLine(hit, query: query), snippet: semanticSnippet(hit, query: query),
                  score: hit.relevance, commentID: hit.commentID)
    }

    /// How much the keyword list can be trusted: every term matched, only some, or a
    /// substring in an unspaced script.
    enum KeywordStrength: Equatable {
        case none, all, any, substring
        var weight: Double {
            switch self {
            case .all, .substring: return 1
            case .any: return 0.35
            case .none: return 0
            }
        }
    }

    /// Weighted reciprocal rank fusion. Keyword hits count fully when every term matched and
    /// about half when only some did; a meaning hit counts by how clearly it answers the
    /// query. An item in both lists keeps the keyword hit (its marked snippet), but takes the
    /// meaning hit's location when the keyword one only matched the file's name.
    static func hybrid(keyword: [(hit: SearchHit, key: String)], strength: KeywordStrength, query: String = "",
                       semantic: [(hit: SearchHit, key: String, relevance: Double)], limit: Int) -> [SearchHit] {
        var scores: [String: (hit: SearchHit, score: Double, order: Int)] = [:]
        var order = 0
        let terms = strength == .any ? contentTerms(query) : []
        for (rank, item) in keyword.enumerated() {
            let k = item.key, hit = item.hit
            // A partial match counts by how many of the query's words it has.
            let share = terms.isEmpty ? 1 : max(0.2, coverage(hit.snippet, terms: terms))
            let add = strength.weight * share / (Fusion.k + Double(rank + 1))
            if let e = scores[k] { scores[k]?.score = e.score + add } else { scores[k] = (hit, add, order); order += 1 }
        }
        for (rank, item) in semantic.enumerated() {
            let k = item.key
            let add = Self.semanticWeight * (0.35 + 0.65 * min(1, max(0, item.relevance))) / (Fusion.k + Double(rank + 1))
            if var e = scores[k] {
                e.score += add
                if e.hit.anchor == nil, item.hit.anchor != nil, e.hit.commentID == nil {
                    e.hit.anchor = item.hit.anchor
                    e.hit.snippet = item.hit.snippet
                }
                scores[k] = e
            } else {
                scores[k] = (item.hit, add, order); order += 1
            }
        }
        return scores.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit).map { var h = $0.hit; h.score = $0.score; return h }
    }

    /// Matching comments, ranked.
    public func searchComments(_ query: String, limit: Int = 50) throws -> [CommentHit] {
        try searchComments(query, inFolder: nil, limit: limit)
    }

    public func searchComments(_ query: String, inFolder folder: String?, limit: Int = 50) throws -> [CommentHit] {
        guard limit > 0 else { return [] }
        return Array(try matchingStrategies(query, key: { $0.id.uuidString }) { try commentHits($0, limit: limit, folder: folder) }.prefix(limit))
    }

    /// Matching comments with how well the words matched (every word, some, or a substring).
    func rankedComments(_ query: String, inFolder folder: String?, limit: Int) throws -> (hits: [CommentHit], strength: KeywordStrength) {
        guard limit > 0 else { return ([], .none) }
        let (hits, strength) = try rankedStrategies(query, key: { $0.id.uuidString }) { try commentHits($0, limit: limit, folder: folder) }
        return (Array(hits.prefix(limit)), strength)
    }

    /// Most recently modified files.
    public func recent(limit: Int = 20) throws -> [FileRef] {
        try read { db in
            try db.query("SELECT path FROM files ORDER BY mtime DESC, path LIMIT ?", max(0, limit)) { FileRef(relativePath: $0.string(0)) }
        }
    }

    /// Fuzzy file-name match for the command palette. Empty query returns `recent`.
    public func files(matching query: String, limit: Int = 50) throws -> [FileRef] {
        try files(matching: query, inFolder: nil, limit: limit)
    }

    public func files(matching query: String, inFolder folder: String?, limit: Int = 50) throws -> [FileRef] {
        guard limit > 0 else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return try read { db in
                try db.query("SELECT path FROM files WHERE 1 = 1 \(Self.folderPredicate(folder)) ORDER BY mtime DESC, path LIMIT ?", limit) { FileRef(relativePath: $0.string(0)) }
            }
        }
        let paths: [String]
        if folder?.isEmpty == false {
            paths = try read { db in try db.query("SELECT path FROM files WHERE 1 = 1 \(Self.folderPredicate(folder)) ORDER BY path") { $0.string(0) } }
        } else { paths = try indexedPaths() }
        return FuzzyMatch.rank(q, in: paths, limit: limit).map(FileRef.init(relativePath:))
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
            try db.query("SELECT id, ts, anchor_kind, anchor_value, text, provenance, meta FROM comments WHERE path = ? ORDER BY ts, rowid",
                         ref.relativePath) { Self.comment($0, 0, provenanceColumn: 5, metaColumn: 6) }
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
        if terms.count > 1, let any = FTSQuery.build(anyTermQuery(query, terms), any: true) { plan.append(.fts(any)) }
        if FTSQuery.isUnspaced(query) { plan.append(.substring(terms.map(\.text))) }
        return plan
    }

    /// For the any-term fallback, drop words like "what", "did" and "about" (which match
    /// nearly everything) as long as something else is left. Quoted phrases stay as typed.
    static func anyTermQuery(_ query: String, _ terms: [FTSQuery.Term]) -> String {
        let kept = terms.filter { $0.phrase || !anyTermStopwords.contains($0.text.lowercased()) }
        guard !kept.isEmpty, kept.count < terms.count else { return query }
        let text = kept.map { $0.phrase ? "\"" + $0.text + "\"" : $0.text }.joined(separator: " ")
        // Keep the prefix match on the last word only if it was the last word typed.
        let typing = !(query.last?.isWhitespace ?? true) && query.last != "\""
        return typing && kept.last == terms.last ? text : text + " "
    }

    /// The query's words that count, lowercased: no stopwords, no duplicates.
    static func contentTerms(_ query: String) -> [String] {
        var seen = Set<String>()
        return FTSQuery.terms(query).map { $0.text.lowercased() }
            .filter { !anyTermStopwords.contains($0) && seen.insert($0).inserted }
    }

    /// The share of `terms` among the words a snippet marks «…» (prefixes count, as in FTS).
    static func coverage(_ snippet: String, terms: [String]) -> Double {
        guard !terms.isEmpty else { return 1 }
        var marked: [String] = []
        var rest = snippet[...]
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            marked.append(rest[rest.index(after: open)..<close].lowercased())
            rest = rest[rest.index(after: close)...]
        }
        guard !marked.isEmpty else { return 0 }
        let found = terms.filter { t in marked.contains { $0.hasPrefix(t) || t.hasPrefix($0) || $0.contains(t) } }
        return Double(found.count) / Double(terms.count)
    }

    static let anyTermStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "as", "into", "over",
        "what", "which", "whom", "whose", "did", "do", "does", "done", "is", "are", "was",
        "were", "be", "been", "being", "it", "its", "this", "that", "these", "those", "i", "we", "you", "he", "she", "they",
        "my", "our", "your", "their", "his", "her", "me", "us", "them", "say", "said", "says", "tell", "told", "there", "here",
        "can", "could", "should", "would", "will", "shall", "may", "might", "must", "has", "have", "had", "not", "no", "any",
        "some", "all", "doc", "docs", "document", "file", "files", "thing", "things", "find", "show", "get", "need", "much", "many",
    ]

    /// Unspaced scripts need substring matches even when a token-boundary FTS hit exists.
    /// Keep the stronger FTS ordering, append other exact-substring hits, and deduplicate.
    private func matchingStrategies<T>(_ query: String, key: (T) -> String, _ run: (Match) throws -> [T]) throws -> [T] {
        try rankedStrategies(query, key: key, run).hits
    }

    /// `matchingStrategies`, also saying which strategy produced the first hits.
    func rankedStrategies<T>(_ query: String, key: (T) -> String, _ run: (Match) throws -> [T]) throws -> (hits: [T], strength: KeywordStrength) {
        var hits: [T] = []
        var seen = Set<String>()
        var strength = KeywordStrength.none
        for (i, match) in Self.plan(query).enumerated() {
            if case .fts = match, !hits.isEmpty { continue }
            let next = try run(match)
            hits += next.filter { seen.insert(key($0)).inserted }
            if strength == .none, !hits.isEmpty {
                if case .substring = match { strength = .substring } else { strength = i == 0 ? .all : .any }
            }
            if !FTSQuery.isUnspaced(query), !hits.isEmpty { break }
        }
        return (hits, strength)
    }

    /// The input is a vault-relative folder, never query-language syntax. SQL literals are
    /// escaped here; the caller supplies only a fixed column name. Prefix bounds include all
    /// descendants and work for apostrophes, spaces, % and _ without LIKE escaping.
    static func folderPredicate(_ folder: String?, column: String = "path") -> String {
        guard let value = folder else { return "" }
        let folder = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !folder.isEmpty else { return "" }
        let lower = (folder + "/").replacingOccurrences(of: "'", with: "''")
        let upper = (folder + "0").replacingOccurrences(of: "'", with: "''")
        return " AND \(column) >= '\(lower)' AND \(column) < '\(upper)'"
    }

    // MARK: - Sections

    /// One hit per file, ranked by the file's best-matching section, opened at its best
    /// *anchored* match (a name or title match alone opens the file at the top). Grouping
    /// happens in SQL before the limit, so a few long documents can't crowd out other files.
    private func fileHits(_ match: Match, limit: Int, folder: String?) throws -> [SearchHit] {
        guard case .fts(let q) = match else {
            guard case .substring(let terms) = match else { return [] }
            let rows = try substringRows("sections", columns: "path, anchor_kind, anchor_value, title, text",
                                         textColumns: ["text", "coalesce(title, '')"], order: "path", terms: terms,
                                         limit: limit, folder: folder, onePerFile: true) {
                (FileRef(relativePath: $0.string(0)), Self.anchor($0, 1), $0.string(3), $0.string(4))
            }
            return rows.enumerated().map { i, r in
                let body = r.3.range(of: terms[0], options: .caseInsensitive) != nil ? r.3 : r.2
                let snippet = Self.substringSnippet(body, terms)
                return SearchHit(file: r.0, anchor: Self.matchAnchor(r.1, text: r.3, snippet: snippet, path: r.0.relativePath), snippet: snippet, score: 1 - Double(i) * 1e-6)
            }
        }
        return try read(snapshot: true) { db in
            let best = try db.query("""
                SELECT s.path, min(sections_fts.rank), sections_fts.rowid, s.ord
                FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid
                WHERE sections_fts MATCH ?1 \(Self.folderPredicate(folder, column: "s.path")) GROUP BY s.path ORDER BY 2 LIMIT ?2
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
                        snippet(sections_fts, 0, '«', '»', '…', 10) AS st,
                        snippet(sections_fts, 1, '«', '»', '…', 16) AS sx
                    FROM sections_fts WHERE sections_fts MATCH ?1 AND +rowid IN picked
                )
                SELECT m.id, s.anchor_kind, s.anchor_value, m.st, m.sx, s.text, s.path
                FROM m JOIN sections s ON s.rowid = m.id WHERE m.sx IS NOT NULL
                """, q, Self.json(best.compactMap { pick[$0.path] })) {
                ($0.int(0), (anchor: Self.matchAnchor(Self.anchor($0, 1), text: $0.string(5), snippet: $0.string(4), path: $0.string(6)), snippet: Self.snippet(title: $0.string(3), text: $0.string(4))))
            }
            let byRow = Dictionary(snippets, uniquingKeysWith: { a, _ in a })
            return best.compactMap { b in
                guard let rowid = pick[b.path], let s = byRow[rowid] else { return nil }
                return SearchHit(file: FileRef(relativePath: b.path), anchor: s.anchor, snippet: s.snippet, score: b.score)
            }
        }
    }

    private func sectionHits(_ match: Match, limit: Int, folder: String?) throws -> [(hit: SearchHit, key: String)] {
        switch match {
        case .fts(let q):
            return try read(snapshot: true) { db in
                // Rank first, then snippets for the survivors only: computing a snippet for
                // every match of a broad any-term query is most of its cost.
                let scope = folder.map { Self.folderPredicate($0) }.flatMap { $0.isEmpty ? nil : $0 }
                let ranked = try db.query("""
                    SELECT rowid, rank FROM sections_fts WHERE sections_fts MATCH ?1
                    \(scope.map { "AND +rowid IN (SELECT rowid FROM sections WHERE 1 = 1 \($0))" } ?? "") ORDER BY rank LIMIT ?2
                    """, q, limit) { ($0.int(0), -$0.double(1)) }
                guard !ranked.isEmpty else { return [] }
                let scores = Dictionary(ranked, uniquingKeysWith: { a, _ in a })
                let rows = try db.query("""
                    SELECT s.rowid, s.path, s.anchor_kind, s.anchor_value, m.st, m.sx, s.text FROM (
                        SELECT rowid, snippet(sections_fts, 0, '«', '»', '…', 10) AS st, snippet(sections_fts, 1, '«', '»', '…', 16) AS sx
                        FROM sections_fts WHERE sections_fts MATCH ?1 AND +rowid IN (SELECT value FROM json_each(?2))
                    ) m JOIN sections s ON s.rowid = m.rowid
                    """, q, Self.json(ranked.map(\.0))) { r -> (Int, (hit: SearchHit, key: String)) in
                    (r.int(0), (SearchHit(file: FileRef(relativePath: r.string(1)), anchor: Self.matchAnchor(Self.anchor(r, 2), text: r.string(6), snippet: r.string(5), path: r.string(1)),
                                          snippet: Self.snippet(title: r.string(4), text: r.string(5)), score: scores[r.int(0)] ?? 0),
                                Self.sectionKey(r.string(1), Self.anchor(r, 2))))
                }
                let byRow = Dictionary(rows, uniquingKeysWith: { a, _ in a })
                return ranked.compactMap { byRow[$0.0] }
            }
        case .substring(let terms):
            let rows = try substringRows("sections", columns: "path, anchor_kind, anchor_value, title, text",
                                         textColumns: ["text", "coalesce(title, '')"], order: "path, ord", terms: terms, limit: limit, folder: folder) {
                (FileRef(relativePath: $0.string(0)), Self.anchor($0, 1), $0.string(3), $0.string(4))
            }
            return rows.enumerated().map { i, r in
                let body = r.3.range(of: terms[0], options: .caseInsensitive) != nil ? r.3 : r.2
                return (SearchHit(file: r.0, anchor: Self.matchAnchor(r.1, text: r.3, snippet: Self.substringSnippet(body, terms), path: r.0.relativePath), snippet: Self.substringSnippet(body, terms), score: 1 - Double(i) * 1e-6),
                        Self.sectionKey(r.0.relativePath, r.1))
            }
        }
    }

    // MARK: - Comments

    func commentHits(_ match: Match, limit: Int, folder: String?) throws -> [CommentHit] {
        switch match {
        case .fts(let q):
            return try read { db in
                try db.query("""
                    SELECT c.path, c.id, c.ts, c.anchor_kind, c.anchor_value, c.text, f.snip, f.rank, c.provenance, c.meta FROM (
                        SELECT rowid, snippet(comments_fts, 0, '«', '»', '…', 16) AS snip, rank
                        FROM comments_fts WHERE comments_fts MATCH ?1
                        \(Self.folderPredicate(folder).isEmpty ? "" : "AND +rowid IN (SELECT rowid FROM comments WHERE 1 = 1 \(Self.folderPredicate(folder)))") ORDER BY rank LIMIT ?2
                    ) f JOIN comments c ON c.rowid = f.rowid ORDER BY f.rank
                    """, q, limit) {
                    CommentHit(file: FileRef(relativePath: $0.string(0)), comment: Self.comment($0, 1, provenanceColumn: 8, metaColumn: 9),
                               snippet: Self.clean($0.string(6)), score: -$0.double(7) * Self.commentBoost)
                }
            }
        case .substring(let terms):
            let rows = try substringRows("comments", columns: "path, id, ts, anchor_kind, anchor_value, text, provenance, meta",
                                         textColumns: ["text"], order: "ts DESC", terms: terms, limit: limit, folder: folder) {
                (FileRef(relativePath: $0.string(0)), Self.comment($0, 1, provenanceColumn: 6, metaColumn: 7))
            }
            return rows.enumerated().map { i, r in
                CommentHit(file: r.0, comment: r.1, snippet: Self.substringSnippet(r.1.text, terms),
                           score: (1 - Double(i) * 1e-6) * Self.commentBoost)
            }
        }
    }

    /// Rows whose text contains every term. A scan, so only used when FTS can't help.
    private func substringRows<T>(_ table: String, columns: String, textColumns: [String], order: String,
                                  terms: [String], limit: Int, folder: String?, onePerFile: Bool = false, row: (Row) throws -> T) throws -> [T] {
        func test(_ i: Int) -> String {
            // Caseless scripts skip lower(), which roughly halves the scan.
            let caseless = terms[i].lowercased() == terms[i].uppercased()
            return textColumns.map { caseless ? "instr(\($0), ?\(i + 1)) > 0" : "instr(lower(\($0)), lower(?\(i + 1))) > 0" }
                .joined(separator: " OR ")
        }
        let predicate = terms.indices.map { "(\(test($0)))" }.joined(separator: " AND ") + Self.folderPredicate(folder)
        let source = onePerFile
            ? "(SELECT *, row_number() OVER (PARTITION BY path ORDER BY CASE WHEN ord = 0 THEN 1 ELSE 0 END, ord) AS picked FROM \(table) WHERE \(predicate)) WHERE picked = 1"
            : "\(table) WHERE \(predicate)"
        let sql = "SELECT \(columns) FROM \(source) ORDER BY \(order) LIMIT ?\(terms.count + 1)"
        let values: [(any SQLBindable)?] = terms.map { $0 } + [limit]
        return try read { db in try db.prepare(sql).query(values, row: row) }
    }

    // MARK: - Helpers

    /// Preserve the true source line rather than returning the start of a whole text section.
    static func matchAnchor(_ anchor: FileAnchor?, text: String, snippet: String, path: String) -> FileAnchor? {
        guard !["html", "htm", "xhtml", "rtf", "rtfd", "ipynb"].contains(FileRef(relativePath: path).ext) else { return anchor }
        guard let anchor, anchor.kind == .line, let base = Int(anchor.value),
              let open = snippet.firstIndex(of: "«"), let close = snippet[snippet.index(after: open)...].firstIndex(of: "»") else { return anchor }
        let needle = String(snippet[snippet.index(after: open)..<close])
        guard !needle.isEmpty, let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return anchor }
        let preceding = text[..<found.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return FileAnchor(kind: .line, value: String(base + preceding))
    }

    static func anchor(_ kind: String?, _ value: String?) -> FileAnchor? {
        guard let kind, let value, let k = FileAnchor.Kind(rawValue: kind) else { return nil }
        return FileAnchor(kind: k, value: value)
    }

    static func anchor(_ row: Row, _ i: Int32) -> FileAnchor? {
        guard let k = row.optionalString(i), let kind = FileAnchor.Kind(rawValue: k) else { return nil }
        return FileAnchor(kind: kind, value: row.string(i + 1))
    }

    /// Reads `id, ts, anchor_kind, anchor_value, text` starting at column `i`.
    static func comment(_ row: Row, _ i: Int32, provenanceColumn: Int32? = nil) -> Comment {
        comment(row, i, provenanceColumn: provenanceColumn, metaColumn: nil)
    }

    /// As above, and with `metaColumn` (the whole hidden-line JSON the note carries, which
    /// includes the provenance) the thought's uid, thread parent, state and so on come back too.
    static func comment(_ row: Row, _ i: Int32, provenanceColumn: Int32?, metaColumn: Int32?) -> Comment {
        var c = Comment(id: UUID(uuidString: row.string(i)) ?? UUID(),
                        timestamp: Date(timeIntervalSince1970: row.double(i + 1)),
                        anchor: anchor(row, i + 2), text: row.string(i + 4),
                        provenance: provenanceColumn.flatMap { row.optionalString($0) }.flatMap { try? JSONDecoder().decode(CommentProvenance.self, from: Data($0.utf8)) })
        if let json = metaColumn.flatMap({ row.optionalString($0) }) { SidecarFormat.applyMetadata(json, to: &c) }
        return c
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
