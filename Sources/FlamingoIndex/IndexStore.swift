import Foundation
import Darwin
import FlamingoCore
import FlamingoExtract

public struct SearchHit: Identifiable, Sendable, Equatable {
    public var id: String { file.relativePath + (anchor?.rendered ?? "") }
    public var file: FileRef
    public var anchor: FileAnchor?
    public var snippet: String   // with match ranges marked as «…»
    public var score: Double
    /// Set when the hit is one of the user's own comments rather than file content.
    public var commentID: UUID? = nil
    public init(file: FileRef, anchor: FileAnchor? = nil, snippet: String, score: Double) {
        self.file = file; self.anchor = anchor; self.snippet = snippet; self.score = score
    }
    public init(file: FileRef, anchor: FileAnchor?, snippet: String, score: Double, commentID: UUID?) {
        self.init(file: file, anchor: anchor, snippet: snippet, score: score)
        self.commentID = commentID
    }
}

/// A comment matching a search, with the file it is on.
public struct CommentHit: Identifiable, Sendable, Equatable {
    public var id: UUID { comment.id }
    public var file: FileRef
    public var comment: Comment
    public var snippet: String
    public var score: Double
    public init(file: FileRef, comment: Comment, snippet: String, score: Double) {
        self.file = file; self.comment = comment; self.snippet = snippet; self.score = score
    }
}

/// What the last `reindex` did.
public struct ReindexReport: Sendable, Equatable {
    public var scanned: Int
    public var extracted: Int
    public var removed: Int
    public var seconds: Double
}

public struct IndexStats: Sendable, Equatable {
    public var files: Int
    public var sections: Int
    public var comments: Int
}

/// SQLite + FTS5 at `<vault>/.flamingo/index.sqlite`. Plan 05 owns.
///
/// Thread-safe. Writes (`reindex`, `update`, `remove`) are serialized on one connection;
/// reads use a second WAL connection, so search stays fast while a reindex runs.
public final class IndexStore: @unchecked Sendable {
    public let vault: Vault
    public var databaseURL: URL { vault.stateDir.appendingPathComponent("index.sqlite") }
    public var graphURL: URL { vault.stateDir.appendingPathComponent("graph.json") }

    static let schemaVersion = 2
    /// Changes whenever extraction output may differ, so files indexed by older extractors
    /// are re-extracted even though they haven't changed on disk.
    static var extractVersion: String { "1" }
    static let batchSize = 200
    static let extractionWidth = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    static let commentBoost = 1.5
    static let maxFileText = 2_000_000
    static let maxSectionText = 500_000

    let sidecars: SidecarStore
    private let writer: Database
    private let reader: Database
    private let writeLock = NSRecursiveLock()
    private let readLock = NSLock()
    private let cacheLock = NSLock()
    private var pathCache: [String]?
    private var report: ReindexReport?

    public init(vault: Vault) throws {
        self.vault = vault
        sidecars = SidecarStore(vault: vault)
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let path = vault.stateDir.appendingPathComponent("index.sqlite").path
        writer = try Self.openWriter(path)
        reader = try Database(path: path)
        try reader.exec("PRAGMA query_only = 1")
    }

    /// `nil` until a `reindex` finishes.
    public var lastReindex: ReindexReport? { cacheLock.lock(); defer { cacheLock.unlock() }; return report }

    // MARK: - Writing

    /// `reindex`, re-extracting every file when `force` is set.
    public func reindex(force: Bool, progress: ((Double) -> Void)? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        if force { try writer.exec("UPDATE files SET mtime = -1") }
        try reindex(progress: progress)
    }

    /// Full reindex. Reports progress 0...1 on the calling thread.
    /// Unchanged files (same mtime and size) are skipped, so re-running is cheap.
    public func reindex(progress: ((Double) -> Void)? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let started = Date()
        progress?(0)
        let known = try stamps()
        var todo: [Pending] = []
        var seen = Set<String>()
        for ref in VaultScanner.files(in: vault) {
            seen.insert(ref.relativePath)
            guard let stamp = Stamp(url: vault.url(for: ref)) else { continue }
            if let k = known[ref.relativePath], k.stamp == stamp { continue }
            todo.append(Pending(ref: ref, stamp: stamp, id: known[ref.relativePath]?.id))
        }
        let gone = known.keys.filter { !seen.contains($0) }
        if !gone.isEmpty {
            try writer.transaction { for p in gone { try deleteRows(path: p) } }
        }
        progress?(0.05)
        try ingest(todo) { progress?(0.05 + 0.9 * $0) }
        _ = try? sidecars.reconcile()   // notes whose file was renamed while we weren't looking
        try replaceAllComments((try? sidecars.all()) ?? [:])
        invalidateCaches()
        cacheLock.lock()
        report = ReindexReport(scanned: seen.count, extracted: todo.count, removed: gone.count,
                               seconds: Date().timeIntervalSince(started))
        cacheLock.unlock()
        progress?(1)
    }

    /// Incremental: re-extract these files only (when their mtime or size changed), drop
    /// the ones that are gone, and re-ingest their sidecar comments. A directory means
    /// everything under it; `""` means the whole vault. A new path carrying the
    /// `FileIdentity` of a vanished one is treated as a rename: it keeps its rows, and
    /// its sidecar follows it (`SidecarStore.reconcile`).
    public func update(_ refs: [FileRef]) throws {
        let refs = Array(Set(refs)).filter { Self.isIndexable($0.relativePath) }
        guard !refs.isEmpty else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        if refs.contains(where: { $0.relativePath.isEmpty }) { return try reindex() }

        let fm = FileManager.default
        var present: [(FileRef, Stamp)] = []
        var missing: [String] = []
        var staleUnder: [(dir: String, keep: Set<String>)] = []
        var commentTargets = Set(refs)
        for ref in refs {
            let url = vault.url(for: ref)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                missing.append(ref.relativePath); continue
            }
            if isDir.boolValue && !Self.isPackage(url) {
                let sub = VaultScanner.files(in: Vault(root: url)).map {
                    FileRef(relativePath: ref.relativePath + "/" + $0.relativePath)
                }
                staleUnder.append((ref.relativePath, Set(sub.map(\.relativePath))))
                commentTargets.formUnion(sub)
                for s in sub { if let st = Stamp(url: vault.url(for: s)) { present.append((s, st)) } }
            } else if let st = Stamp(url: url) {
                present.append((ref, st))
            }
        }

        let known = try stamps(for: present.map(\.0.relativePath))
        try writer.transaction {
            for (ref, _) in present {
                if let k = known[ref.relativePath] {
                    if k.id == nil { try recordIdentity(of: ref) }
                } else {
                    try adoptRenamedRow(for: ref)
                }
            }
        }
        if missing.contains(where: hasSidecars), let moves = try? sidecars.reconcile() {
            for m in moves { commentTargets.insert(m.from); commentTargets.insert(m.to) }
        }
        let afterRename = try stamps(for: present.map(\.0.relativePath))
        let todo = present.compactMap { ref, st -> Pending? in
            let k = afterRename[ref.relativePath]
            return k?.stamp == st ? nil : Pending(ref: ref, stamp: st, id: k?.id)
        }
        try ingest(todo) { _ in }
        try writer.transaction {
            for p in missing { try deleteRows(path: p); try deleteRows(under: p) }
            for (dir, keep) in staleUnder {
                let rows = try writer.query("SELECT path FROM files WHERE substr(path, 1, length(?1)) = ?1", dir + "/") { $0.string(0) }
                for p in rows where !keep.contains(p) { try deleteRows(path: p) }
            }
            for ref in commentTargets { try replaceComments(for: ref) }
        }
        invalidateCaches()
    }

    public func remove(_ refs: [FileRef]) throws {
        guard !refs.isEmpty else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.transaction {
            for ref in refs {
                try deleteRows(path: ref.relativePath)
                if !ref.relativePath.isEmpty { try deleteRows(under: ref.relativePath) }
            }
        }
        invalidateCaches()
    }

    /// Replaces every indexed comment with these. `reindex` calls it with `SidecarStore.all()`.
    func replaceAllComments(_ all: [FileRef: [Comment]]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.transaction {
            try writer.exec("DELETE FROM comments")
            for (ref, comments) in all { try insertComments(comments, for: ref) }
        }
    }

    // MARK: - Search

    /// Best hits across file content and comments, one content hit per file (at its best
    /// section's anchor). All terms must match; if nothing does, any term may.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        return try firstNonEmpty(query) { match in
            let content = Self.bestPerFile(try sectionHits(match, limit: max(limit * 4, 100)))
            let comments = try commentHits(match, limit: limit).map {
                SearchHit(file: $0.file, anchor: $0.comment.anchor, snippet: $0.snippet, score: $0.score, commentID: $0.comment.id)
            }
            var seen = Set<String>()
            let merged = (content + comments).sorted { $0.score > $1.score }.filter { seen.insert($0.id).inserted }
            return Array(merged.prefix(limit))
        }
    }

    /// Every matching section, ranked, not grouped by file. For retrieval (plan 09).
    public func searchSections(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        return try firstNonEmpty(query) { try sectionHits($0, limit: limit) }
    }

    /// Matching comments, ranked.
    public func searchComments(_ query: String, limit: Int = 50) throws -> [CommentHit] {
        guard limit > 0 else { return [] }
        return try firstNonEmpty(query) { try commentHits($0, limit: limit) }
    }

    /// Most recently modified files.
    public func recent(limit: Int = 20) throws -> [FileRef] {
        try read { db in
            try db.query("SELECT path FROM files ORDER BY mtime DESC, path LIMIT ?", limit) { FileRef(relativePath: $0.string(0)) }
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
        try read { db in
            IndexStats(files: try db.scalarInt("SELECT count(*) FROM files"),
                       sections: try db.scalarInt("SELECT count(*) FROM sections"),
                       comments: try db.scalarInt("SELECT count(*) FROM comments"))
        }
    }

    // MARK: - Internals

    struct Stamp: Equatable {
        var mtime: Double
        var size: Int
        init(mtime: Double, size: Int) { self.mtime = mtime; self.size = size }
        /// `nil` unless a regular file or a folder (packages): never a pipe or a device,
        /// which would block extraction forever.
        init?(url: URL) {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return nil }
            mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            size = Int(st.st_size)
        }
    }

    struct Pending {
        var ref: FileRef
        var stamp: Stamp
        var id: String?
    }

    struct Extraction {
        var ref: FileRef
        var stamp: Stamp
        var id: String?
        var extracted: Extracted?
    }

    struct RawHit {
        var path: String
        var anchor: FileAnchor?
        var snippet: String
        var score: Double
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        readLock.lock(); defer { readLock.unlock() }
        return try body(reader)
    }

    func indexedPaths() throws -> [String] {
        cacheLock.lock()
        if let p = pathCache { cacheLock.unlock(); return p }
        cacheLock.unlock()
        let paths = try read { db in try db.query("SELECT path FROM files ORDER BY path") { $0.string(0) } }
        cacheLock.lock(); pathCache = paths; cacheLock.unlock()
        return paths
    }

    private func invalidateCaches() {
        cacheLock.lock(); pathCache = nil; cacheLock.unlock()
    }

    private static func openWriter(_ path: String) throws -> Database {
        do {
            return try configure(Database(path: path))
        } catch {
            // The index is a cache. If it is unreadable or from the future, start over.
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            return try configure(Database(path: path))
        }
    }

    private static func configure(_ db: Database) throws -> Database {
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY;")
        let v = db.userVersion
        if v > schemaVersion { throw IndexError(code: 0, message: "index.sqlite schema \(v) is newer than \(schemaVersion)") }
        if v < 1 { try db.transaction { try db.exec(Schema.v1) } }
        if v < 2 { try db.transaction { try db.exec(Schema.v2) } }
        let stored = try db.query("SELECT value FROM meta WHERE key = 'extract_version'") { $0.string(0) }.first
        if stored != extractVersion {
            try db.transaction {
                try db.exec("UPDATE files SET mtime = -1")   // stale; keep serving old text until reindexed
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('extract_version', ?)", extractVersion)
            }
        }
        return db
    }

    private func stamps() throws -> [String: (stamp: Stamp, id: String?)] {
        let rows = try writer.query("SELECT path, mtime, size, id FROM files") {
            ($0.string(0), (stamp: Stamp(mtime: $0.double(1), size: $0.int(2)), id: $0.optionalString(3)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    private func stamps(for paths: [String]) throws -> [String: (stamp: Stamp, id: String?)] {
        var out: [String: (stamp: Stamp, id: String?)] = [:]
        for p in paths {
            let row = try writer.query("SELECT mtime, size, id FROM files WHERE path = ?", p) {
                (stamp: Stamp(mtime: $0.double(0), size: $0.int(1)), id: $0.optionalString(2))
            }
            if let r = row.first { out[p] = r }
        }
        return out
    }

    /// Ids are read, never assigned: a file has one once someone comments on it.
    private func recordIdentity(of ref: FileRef) throws {
        guard let id = (try? FileIdentity.existingID(for: vault.url(for: ref))) ?? nil else { return }
        try writer.run("UPDATE files SET id = ? WHERE path = ?", id.uuidString, ref.relativePath)
    }

    /// If `ref` is new but carries the identity of a row whose file vanished, move that row.
    private func adoptRenamedRow(for ref: FileRef) throws {
        guard let id = (try? FileIdentity.existingID(for: vault.url(for: ref))) ?? nil else { return }
        let candidates = try writer.query("SELECT path, title FROM files WHERE id = ? AND path != ?",
                                          id.uuidString, ref.relativePath) { ($0.string(0), $0.optionalString(1)) }
        guard let (old, title) = candidates.first(where: {
            !FileManager.default.fileExists(atPath: vault.url(for: FileRef(relativePath: $0.0)).path)
        }) else { return }
        try deleteRows(path: ref.relativePath)
        try writer.run("UPDATE files SET path = ?, ext = ? WHERE path = ?", ref.relativePath, ref.ext, old)
        try writer.run("UPDATE sections SET path = ? WHERE path = ?", ref.relativePath, old)
        try writer.run("UPDATE sections SET title = ? WHERE path = ? AND ord = 0", Self.fileTitle(title, ref), ref.relativePath)
    }

    private func ingest(_ todo: [Pending], progress: (Double) -> Void) throws {
        guard !todo.isEmpty else { progress(1); return }
        let queue = ExtractionQueue(todo, vault: vault, width: Self.extractionWidth)
        var written = 0
        defer { queue.cancel() }
        while let batch = queue.next(batchSize: Self.batchSize) {
            try writer.transaction { for e in batch { try write(e) } }
            written += batch.count
            progress(Double(written) / Double(todo.count))
        }
    }

    private func write(_ e: Extraction) throws {
        let path = e.ref.relativePath
        let x = e.extracted ?? Extracted(text: "")
        let title = x.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try deleteRows(path: path)
        try writer.run("""
            INSERT INTO files(path, id, mtime, size, ext, title, indexed_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, path, e.id, e.stamp.mtime, e.stamp.size, e.ref.ext, title, Date().timeIntervalSince1970)

        // Row 0 is the file itself: its name and title, plus the full text when the
        // sections don't already cover it (or there are none).
        let covered = x.sections.reduce(0) { $0 + $1.text.utf16.count }
        let wholeText = x.sections.isEmpty || covered * 10 < x.text.utf16.count * 9
        let insert = "INSERT INTO sections(path, ord, anchor_kind, anchor_value, title, text) VALUES (?, ?, ?, ?, ?, ?)"
        var budget = Self.maxFileText
        let fileText = wholeText ? Self.capped(x.text, budget) : ""
        budget -= fileText.utf16.count
        try writer.run(insert, path, 0, nil, nil, Self.fileTitle(title, e.ref), fileText)
        for (i, s) in x.sections.enumerated() {
            let text = Self.capped(s.text, max(0, min(Self.maxSectionText, budget)))
            budget -= text.utf16.count
            try writer.run(insert, path, i + 1, s.anchor.kind.rawValue, s.anchor.value, s.title, text)
        }
    }

    private func deleteRows(path: String) throws {
        try writer.run("DELETE FROM sections WHERE path = ?", path)
        try writer.run("DELETE FROM files WHERE path = ?", path)
    }

    private func deleteRows(under dir: String) throws {
        let prefix = dir + "/"
        try writer.run("DELETE FROM sections WHERE substr(path, 1, length(?1)) = ?1", prefix)
        try writer.run("DELETE FROM files WHERE substr(path, 1, length(?1)) = ?1", prefix)
    }

    /// A note for this path, or (for a folder) notes for anything under it.
    private func hasSidecars(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: sidecars.sidecarURL(for: FileRef(relativePath: path)).path)
            || fm.fileExists(atPath: vault.notesDir.appendingPathComponent(path, isDirectory: true).path)
    }

    private func replaceComments(for ref: FileRef) throws {
        let comments: [Comment]
        if !FileManager.default.fileExists(atPath: sidecars.sidecarURL(for: ref).path) {
            comments = []
        } else if let c = try? sidecars.comments(for: ref) {
            comments = c
        } else {
            return  // unreadable mid-write; keep what we had
        }
        try writer.run("DELETE FROM comments WHERE path = ?", ref.relativePath)
        try insertComments(comments, for: ref)
    }

    private func insertComments(_ comments: [Comment], for ref: FileRef) throws {
        for c in comments {
            try writer.run("""
                INSERT INTO comments(path, id, ts, anchor_kind, anchor_value, text) VALUES (?, ?, ?, ?, ?, ?)
                """, ref.relativePath, c.id.uuidString, c.timestamp.timeIntervalSince1970,
                c.anchor?.kind.rawValue, c.anchor?.value, c.text)
        }
    }

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

    private func sectionHits(_ match: Match, limit: Int) throws -> [SearchHit] {
        switch match {
        case .fts(let q): return try rawSectionHits(q, limit: limit)
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

    private func commentHits(_ match: Match, limit: Int) throws -> [CommentHit] {
        switch match {
        case .fts(let q): return try rawCommentHits(q, limit: limit)
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

    private func substringRows<T>(_ table: String, columns: String, textColumns: [String], order: String,
                                  terms: [String], limit: Int, row: (Row) throws -> T) throws -> [T] {
        let test = { (t: Int) in textColumns.map { "instr(lower(\($0)), lower(?\(t + 1))) > 0" }.joined(separator: " OR ") }
        let sql = "SELECT \(columns) FROM \(table) WHERE "
            + terms.indices.map { "(\(test($0)))" }.joined(separator: " AND ")
            + " ORDER BY \(order) LIMIT ?\(terms.count + 1)"
        let values: [(any SQLBindable)?] = terms.map { $0 } + [limit]
        return try read { db in try db.prepare(sql).query(values, row: row) }
    }

    private func rawSectionHits(_ q: String, limit: Int) throws -> [SearchHit] {
        try read { db in
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
    }

    private func rawCommentHits(_ q: String, limit: Int) throws -> [CommentHit] {
        try read { db in
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
    }

    /// One hit per file, ranked by its best section. If that is the file-level row (a name
    /// or title match) but a deeper section also matched, open at the deeper section.
    static func bestPerFile(_ hits: [SearchHit]) -> [SearchHit] {
        var order: [String] = []
        var best: [String: SearchHit] = [:]
        for h in hits {
            let p = h.file.relativePath
            if var b = best[p] {
                if b.anchor == nil, h.anchor != nil { b.anchor = h.anchor; b.snippet = h.snippet; best[p] = b }
            } else {
                order.append(p); best[p] = h
            }
        }
        return order.compactMap { best[$0] }
    }

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

    static func fileTitle(_ title: String?, _ ref: FileRef) -> String {
        guard let title, title != ref.name, title != (ref.name as NSString).deletingPathExtension else { return ref.name }
        return title + " · " + ref.name
    }

    static func capped(_ s: String, _ limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        return String(s.utf16.prefix(limit)) ?? String(s.prefix(limit / 2))
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

    static func isIndexable(_ path: String) -> Bool {
        path.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !VaultScanner.ignoredNames.contains(String($0)) }
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }
}

/// Extracts files on a few background threads and hands back finished batches in
/// completion order, so one slow file never holds up writing the rest.
private final class ExtractionQueue: @unchecked Sendable {
    private let todo: [IndexStore.Pending]
    private let vault: Vault
    private let lock = NSCondition()
    private var nextIndex = 0
    private var done: [IndexStore.Extraction] = []
    private var delivered = 0
    private var cancelled = false

    init(_ todo: [IndexStore.Pending], vault: Vault, width: Int) {
        self.todo = todo; self.vault = vault
        for _ in 0..<min(width, todo.count) {
            Thread.detachNewThread { [self] in work() }
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// Blocks until `batchSize` results are ready (or everything left is), `nil` when finished.
    func next(batchSize: Int) -> [IndexStore.Extraction]? {
        lock.lock(); defer { lock.unlock() }
        let remaining = todo.count - delivered
        guard remaining > 0 else { return nil }
        let want = min(batchSize, remaining)
        while done.count < want { lock.wait() }
        let batch = done
        done.removeAll(keepingCapacity: true)
        delivered += batch.count
        return batch
    }

    private func work() {
        while true {
            lock.lock()
            let i = nextIndex
            nextIndex += 1
            let stop = cancelled || i >= todo.count
            lock.unlock()
            if stop { return }
            let p = todo[i]
            let result: IndexStore.Extraction = autoreleasepool {
                let url = vault.url(for: p.ref)
                let id = ((try? FileIdentity.existingID(for: url)) ?? nil)?.uuidString ?? p.id
                return IndexStore.Extraction(ref: p.ref, stamp: p.stamp, id: id, extracted: try? Extract.extract(url))
            }
            lock.lock()
            done.append(result)
            lock.signal()
            lock.unlock()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
