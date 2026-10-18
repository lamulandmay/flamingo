import Foundation
import SQLite3
import FlamingoCore

/// Where semantic search stands for one index, for status displays.
public struct SemanticStatus: Sendable, Equatable {
    /// The model new vectors are made with (`qwen3-embedding:0.6b`, `apple-nl-contextual`…),
    /// nil when none is installed or running.
    public var model: String?
    /// Sections with vectors from `model`, and sections in all.
    public var embedded: Int
    public var total: Int
    /// Thoughts with vectors, and thoughts in all.
    public var embeddedComments: Int
    public var comments: Int
}

extension IndexStore {
    // MARK: - Embedding

    /// Embed new sections in the background after each reindex and update. Off under XCTest,
    /// where tests call `embedPending` themselves.
    public nonisolated(unsafe) static var autoEmbed = NSClassFromString("XCTestCase") == nil
    /// Lexical `unifiedSearch` starts loading vectors and the query's embedding in the
    /// background, so the semantic pass that follows it is instant. Off under XCTest.
    public nonisolated(unsafe) static var prefetchSemantic = NSClassFromString("XCTestCase") == nil

    static let embedBatch = 32
    /// Legacy constants (nomic); profiles now carry their own floors.
    static let semanticFloor: Float = 0.55
    static let semanticSpread: Float = 0.1
    /// Keyword ranks count a little more, so an exact match still leads.
    static let semanticWeight = 0.8
    /// After Ollama fails, semantic search waits this long before trying it again.
    static let downInterval: TimeInterval = 30
    /// How long an interactive query waits for its embedding. A slower answer (a model
    /// still loading) lands in the cache for the next keystroke.
    static let interactiveEmbedWait: TimeInterval = 0.8
    static let directEmbedWait: TimeInterval = 3
    /// A full sweep (every file, newest first) at least this often; between sweeps only
    /// sections added since the last one are looked at.
    static let sweepInterval: TimeInterval = 60 * 60
    /// SQLite gives a new row max(rowid) + 1, so re-extracting the newest file can reuse
    /// rowids just below the watermark. Passes between sweeps look this far below it too.
    static let watermarkMargin = 10_000

    /// Queues `embedPending`, then `titlePending`, at background QoS. Calls while one is queued coalesce.
    public func scheduleEmbedding() {
        let state = embedding
        let first = state.lock.withLock { () -> Bool in
            if state.onDirty == nil, Self.autoEmbed {
                state.onDirty = { [weak self] in if IndexStore.autoEmbed { self?.scheduleEmbedding() } }
            }
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard first else { return }
        state.queue.async { [weak self] in
            state.lock.withLock { state.scheduled = false }
            guard let self, !state.lock.withLock({ state.cancelled }) else { return }
            self.embedPending()
            // Titling rewrites each file's title row, which drops its vector; embed those again.
            if Self.autoTitle, self.titlePending() > 0 { self.embedPending() }
        }
    }

    /// Embeds thoughts, then every section without a vector from the current model, newest
    /// files first. Passages whose exact text was embedded before (a re-extracted or renamed
    /// file) reuse the old vector. Yields to interactive searches, pauses on low battery or
    /// heat, and stops quietly when no model is available; the next reindex tries again.
    /// Returns how many sections it finished.
    @discardableResult
    public func embedPending() -> Int {
        let state = embedding
        let start = state.lock.withLock { () -> Bool in
            defer { state.running = true }
            return !state.running
        }
        guard start else { return 0 }
        defer { state.lock.withLock { state.running = false } }
        guard ensureSemanticSchema(), sqlite3_db_readonly(writer.handle, "main") == 0 else { return 0 }
        let embedder = state.lock.withLock { state.embedder }
        let current = metaValue("semantic_model")
        guard let profile = embedder.resolve(current: current) else { return 0 }
        if current != profile.id { setMeta("semantic_model", profile.id) }
        state.lock.withLock { state.activeModel = profile.id }

        let pass = EmbeddingPass(store: self, profile: profile, embedder: embedder)
        pass.comments()
        let sections = pass.sections()
        if pass.completed { pass.collectGarbage() }
        return sections
    }

    /// Sections with a vector from the current model, and sections in all.
    public func embeddingProgress() throws -> (embedded: Int, total: Int) {
        let model = embedding.lock.withLock { embedding.activeModel } ?? metaValue("semantic_model")
        return try read { db in
            let total = try db.scalarInt("SELECT count(*) FROM sections")
            guard try hasSemanticTables(db) else { return (0, total) }
            let embedded = model.map { (try? db.scalarInt("SELECT count(DISTINCT section) FROM embedding_spans WHERE model = ?", $0)) ?? 0 }
                ?? ((try? db.scalarInt("SELECT count(DISTINCT section) FROM embedding_spans")) ?? 0)
            return (embedded, total)
        }
    }

    /// The model in use and how far embedding has got.
    public func semanticStatus() -> SemanticStatus {
        let model = embedding.lock.withLock { embedding.activeModel } ?? metaValue("semantic_model")
        let counts = (try? read { db -> [Int] in
            let sections = try db.scalarInt("SELECT count(*) FROM sections")
            let comments = try db.scalarInt("SELECT count(*) FROM comments")
            guard try hasSemanticTables(db), let model else { return [0, sections, 0, comments] }
            return [try db.scalarInt("SELECT count(DISTINCT section) FROM embedding_spans WHERE model = ?", model), sections,
                    try db.scalarInt("SELECT count(*) FROM comment_vectors WHERE model = ?", model), comments]
        }) ?? [0, 0, 0, 0]
        return SemanticStatus(model: model, embedded: counts[0], total: counts[1], embeddedComments: counts[2], comments: counts[3])
    }

    /// Stop queued embedding/titling work when a vault closes. Extraction has a separate
    /// caller-owned cancellation closure because its API is synchronous.
    public func cancelBackgroundWork() { embedding.lock.withLock { embedding.cancelled = true } }

    /// Loads this index's vectors into memory and, given a query, its embedding, on a
    /// background queue. Returns at once. Calling it when a search field opens makes the
    /// first semantic result as fast as the rest. User-initiated: someone is typing and the
    /// semantic results they wait for start from this.
    public func warmSemanticSearch(query: String? = nil) {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let embedder = self.embedding.lock.withLock { self.embedding.embedder }
            for (_, profile) in self.semanticIndexes() {
                guard embedder.canEmbed(profile) else { continue }
                _ = self.queryVector(q?.isEmpty == false ? q! : "warm up", profile: profile, embedder: embedder, wait: 0)
            }
        }
    }

    // MARK: - Schema and meta

    /// Creates the semantic tables if this is the writer and they're missing. Read-only
    /// stores just check. Never changes `user_version` (see `Schema.semantic`).
    @discardableResult
    func ensureSemanticSchema() -> Bool {
        if let ready = embedding.lock.withLock({ embedding.schemaReady }), ready { return true }
        var ready = false
        if sqlite3_db_readonly(writer.handle, "main") == 0 {
            writeLock.lock()
            do {
                try writer.transaction {
                    let done = try writer.query("SELECT value FROM meta WHERE key = 'semantic_schema'") { $0.string(0) }.first
                    guard done != Self.semanticSchemaVersion else { return }
                    let columns = try writer.query("PRAGMA table_info(embedding_spans)") { $0.string(1) }
                    for c in Schema.semanticColumns where !columns.contains(c.column) { try writer.exec(c.ddl) }
                    try writer.exec(Schema.semantic)
                    // Vectors from before passages had hashes are in another format: drop them.
                    try writer.exec("DELETE FROM embedding_spans WHERE hash IS NULL AND offset >= 0; DELETE FROM embeddings;")
                    try writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('semantic_schema', ?)", Self.semanticSchemaVersion)
                }
                ready = true
            } catch {
                ready = false
            }
            writeLock.unlock()
        } else {
            ready = (try? read { try hasSemanticTables($0) }) ?? false
        }
        embedding.lock.withLock { embedding.schemaReady = ready }
        return ready
    }

    func hasSemanticTables(_ db: Database) throws -> Bool {
        try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name IN ('semantic_cache', 'comment_vectors')") == 2
    }

    func metaValue(_ key: String) -> String? {
        (try? read { db in try db.query("SELECT value FROM meta WHERE key = ?", key) { $0.string(0) }.first }) ?? nil
    }

    func setMeta(_ key: String, _ value: String) {
        writeLock.lock(); defer { writeLock.unlock() }
        try? writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", key, value)
    }

    var semanticFileKey: String { databaseURL.standardizedFileURL.path }
    static let semanticSchemaVersion = "1"

    // MARK: - Semantic search

    struct SemanticHit {
        var section: Int
        var path: String
        var ord: Int
        var anchor: FileAnchor?
        var title: String
        /// The passage that matched (or the thought's text).
        var text: String
        /// Cosine similarity under `model`.
        var score: Float
        /// 0…1 and beyond: how clearly the passage answers the query, comparable across models.
        var relevance: Double = 0
        var commentID: UUID? = nil
        var offset: Int = 0
        var model: String = ""
        var isCard: Bool = false
        /// Line breaks in the section before the passage (line-anchored text only).
        var linesBefore: Int = 0
        /// A thought with no file row behind it: in the inbox, on a web page, or on a folder.
        var isGhost: Bool = false
    }

    /// The in-memory indexes for every model with vectors in this file, refreshed.
    func semanticIndexes() -> [(VectorIndex, EmbeddingProfile)] {
        guard ensureSemanticSchema() else { return [] }
        let state = embedding
        let (dirty, known) = state.lock.withLock { () -> (Bool, [String: VectorIndex]) in
            defer { state.dirty = false }
            return (state.dirty, state.indexes)
        }
        var indexes = known
        if dirty || known.isEmpty {
            let models = (try? read { db in
                try db.query("SELECT model FROM embedding_spans WHERE offset >= 0 GROUP BY model") { $0.string(0) }
                    + db.query("SELECT model FROM comment_vectors GROUP BY model") { $0.string(0) }
            }) ?? []
            for model in Set(models) where indexes[model] == nil {
                guard let profile = EmbeddingProfile.forID(model) else { continue }
                indexes[model] = SemanticRuntime.shared.index(file: semanticFileKey, model: model, dimensions: profile.memoryDimensions)
            }
            state.lock.withLock { state.indexes = indexes }
        }
        var out: [(VectorIndex, EmbeddingProfile)] = []
        for (model, index) in indexes {
            guard let profile = EmbeddingProfile.forID(model) else { continue }
            do { try index.refresh(path: databaseURL.path, audit: dirty) } catch {
                do { try read { try index.refresh($0, audit: dirty) } } catch { continue }
            }
            if index.count > 0 { out.append((index, profile)) }
        }
        return out.sorted { $0.1.rank < $1.1.rank }
    }

    /// The query's vector under `profile`, from the shared cache or the model. Waits at most
    /// `wait` seconds; a request still running then completes into the cache.
    func queryVector(_ q: String, profile: EmbeddingProfile, embedder: Embedder, wait: TimeInterval) -> [Float]? {
        let input = profile.query(q)
        // A test's fake is its own model; never share its vectors through the process cache.
        if embedder.fake != nil { return embedder.embed([input], profile: profile, timeout: 1)?.first }
        let key = profile.id + "\u{1}" + q
        let runtime = SemanticRuntime.shared
        if let cached = runtime.cachedQuery(key) { return cached }
        guard embedder.canEmbed(profile) else { return nil }
        if case .ollama = profile.backend {
            runtime.embedOnce(key, wait: wait) { finish in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let v = embedder.embed([input], profile: profile, timeout: 30)?.first { runtime.storeQuery(key, v) }
                    finish()
                }
            }
        } else if let v = embedder.embed([input], profile: profile, timeout: max(wait, 1))?.first {
            runtime.storeQuery(key, v)
        }
        return runtime.cachedQuery(key)
    }

    /// Sections (and thoughts) nearest the query by meaning, best first, one per section,
    /// each with the passage that matched. Scope (`folder`, `filePredicate` over `files f`)
    /// applies before the limit. Empty when nothing is embedded or no model can embed the
    /// query in time.
    func semanticSections(_ query: String, limit: Int, folder: String? = nil, filePredicate: String = "1 = 1", commentsOnly: Bool = false,
                          wait: TimeInterval = IndexStore.directEmbedWait, shouldCancel: @Sendable () -> Bool = { false }) -> [SemanticHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0, !shouldCancel() else { return [] }
        SemanticRuntime.shared.noteInteractive()
        let indexes = semanticIndexes()
        guard !indexes.isEmpty else { return [] }
        let embedder = embedding.lock.withLock { embedding.embedder }
        let scoped = folder.map { !$0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty } == true || filePredicate != "1 = 1"
        let k = max(limit * 4, 64)

        var queries: [(VectorIndex, EmbeddingProfile, [Float])] = []
        for (index, profile) in indexes {
            guard !shouldCancel(), let v = queryVector(q, profile: profile, embedder: embedder, wait: wait) else { continue }
            queries.append((index, profile, v))
        }
        guard !queries.isEmpty, !shouldCancel() else { return [] }

        func rank(allow: ((VectorIndex.Row) -> Bool)?) -> [SemanticHit] {
            var candidates: [(VectorIndex, EmbeddingProfile, VectorIndex.Row, Float)] = []
            for (index, profile, v) in queries {
                for found in index.nearest(v, k: k, floor: profile.floor, allow: allow) {
                    candidates.append((index, profile, index.row(found.row), found.score))
                }
            }
            return resolve(candidates, folder: folder, filePredicate: filePredicate)
        }
        var hits = rank(allow: commentsOnly ? { $0.isComment } : nil)
        if scoped, hits.count < limit, !shouldCancel(), let allowed = scopeSets(folder: folder, filePredicate: filePredicate) {
            hits = rank { $0.isComment ? allowed.comments.contains($0.owner) : (!commentsOnly && allowed.sections.contains($0.owner)) }
        }
        guard let best = hits.first?.relevance else { return [] }
        // Far below the best hit is noise, however many there are.
        let cut = best - 0.75
        return Array(hits.filter { $0.relevance >= cut }.prefix(limit))
    }

    /// One hit per file, best first. A file card wins on meaning but has no text to show, so
    /// it borrows the location and passage of the file's next best hit when one is close.
    static func bestPerFile(_ hits: [SemanticHit]) -> [SemanticHit] {
        var order: [String] = []
        var byFile: [String: [SemanticHit]] = [:]
        for h in hits {
            if byFile[h.path] == nil { order.append(h.path) }
            byFile[h.path, default: []].append(h)
        }
        return order.compactMap { path in
            guard let all = byFile[path], var best = all.first else { return nil }
            if best.isCard, let shown = all.dropFirst().first(where: { !$0.isCard && $0.relevance >= best.relevance - 0.35 }) {
                let relevance = best.relevance, score = best.score
                best = shown
                best.relevance = relevance
                best.score = score
            }
            return best
        }
    }

    /// Section and comment rowids inside a scope, for ranking only what the scope admits.
    /// Nil when the scope is so broad that filtering after ranking is as good.
    private func scopeSets(folder: String?, filePredicate: String) -> (sections: Set<Int64>, comments: Set<Int64>)? {
        try? read { db in
            let cap = 400_000
            var sections = Set<Int64>(), comments = Set<Int64>()
            _ = try db.query("""
                SELECT s.rowid FROM files f CROSS JOIN sections s ON s.path = f.path
                WHERE \(filePredicate) \(Self.folderPredicate(folder, column: "f.path")) LIMIT ?
                """, cap + 1) { sections.insert(Int64($0.int(0))) }
            _ = try db.query("""
                SELECT c.rowid FROM comments c LEFT JOIN files f ON f.path = c.path
                WHERE \(filePredicate) \(Self.folderPredicate(folder, column: "c.path"))
                """) { comments.insert(Int64($0.int(0))) }
            return sections.count > cap ? nil : (sections, comments)
        } ?? nil
    }

    /// Reads candidates back from SQL: applies scope, drops vectors whose rows are gone,
    /// keeps the best passage per section, best first.
    private func resolve(_ candidates: [(VectorIndex, EmbeddingProfile, VectorIndex.Row, Float)], folder: String?, filePredicate: String) -> [SemanticHit] {
        guard !candidates.isEmpty else { return [] }
        let spans = candidates.filter { !$0.2.isComment }
        let comments = candidates.filter { $0.2.isComment }
        struct Found { var section: Int; var path: String; var ord: Int; var anchor: FileAnchor?; var title: String; var text: String; var length: Int; var commentID: UUID?; var lines = 0; var ghost = false }
        var found: [Int64: Found] = [:]
        var live = Set<Int64>()
        _ = try? read(snapshot: true) { db in
            if !spans.isEmpty {
                let keys = Self.json(spans.map(\.2.key))
                let owners = Dictionary(spans.map { ($0.2.key, $0.2.owner) }, uniquingKeysWith: { a, _ in a })
                _ = try db.query("SELECT rowid, section FROM embedding_spans WHERE rowid IN (SELECT value FROM json_each(?))", keys) { r in
                    let key = Int64(r.int(0))
                    if owners[key] == Int64(r.int(1)) { live.insert(key) }
                }
                _ = try db.query("""
                    SELECT e.rowid, e.section, s.path, s.ord, s.anchor_kind, s.anchor_value, coalesce(s.title, ''),
                        CASE WHEN coalesce(e.length, 0) > 0 THEN substr(s.text, e.offset + 1, e.length) ELSE substr(s.text, 1, 400) END,
                        coalesce(e.length, 0),
                        CASE WHEN s.anchor_kind = 'line' AND e.offset > 0
                            THEN length(substr(s.text, 1, e.offset)) - length(replace(substr(s.text, 1, e.offset), char(10), '')) ELSE 0 END
                    FROM embedding_spans e JOIN sections s ON s.rowid = e.section JOIN files f ON f.path = s.path
                    WHERE e.rowid IN (SELECT value FROM json_each(?1)) \(Self.folderPredicate(folder, column: "s.path")) AND \(filePredicate)
                    """, keys) {
                    found[Int64($0.int(0))] = Found(section: $0.int(1), path: $0.string(2), ord: $0.int(3), anchor: Self.anchor($0, 4),
                                                    title: $0.string(6), text: $0.string(7), length: $0.int(8), commentID: nil, lines: $0.int(9))
                }
            }
            if !comments.isEmpty {
                let ids = Self.json(comments.map(\.2.owner))
                _ = try db.query("SELECT comment FROM comment_vectors WHERE comment IN (SELECT value FROM json_each(?))", ids) { live.insert(-Int64($0.int(0))) }
                _ = try db.query("""
                    SELECT c.rowid, c.path, c.id, c.anchor_kind, c.anchor_value, c.text, f.path IS NULL
                    FROM comments c LEFT JOIN files f ON f.path = c.path
                    WHERE c.rowid IN (SELECT value FROM json_each(?1)) \(Self.folderPredicate(folder, column: "c.path")) AND \(filePredicate)
                    """, ids) {
                    found[-Int64($0.int(0))] = Found(section: -$0.int(0), path: $0.string(1), ord: -1, anchor: Self.anchor($0, 3),
                                                     title: "", text: $0.string(5), length: 0, commentID: UUID(uuidString: $0.string(2)), ghost: $0.int(6) != 0)
                }
            }
        }
        var gone: [ObjectIdentifier: (VectorIndex, [Int64])] = [:]
        var best: [Int: SemanticHit] = [:]
        for (index, profile, row, score) in candidates {
            guard live.contains(row.key) else {
                gone[ObjectIdentifier(index), default: (index, [])].1.append(row.key)
                continue
            }
            guard let f = found[row.key] else { continue }
            let relevance = Double((score - profile.floor) / max(0.01, profile.strong - profile.floor))
            let hit = SemanticHit(section: f.section, path: f.path, ord: f.ord, anchor: f.anchor, title: f.title, text: f.text, score: score,
                                  relevance: relevance, commentID: f.commentID, offset: row.offset, model: profile.id,
                                  isCard: f.commentID == nil && f.ord == 0 && f.length == 0, linesBefore: f.lines, isGhost: f.ghost)
            if let prior = best[f.section], prior.relevance >= relevance { continue }
            best[f.section] = hit
        }
        for (index, keys) in gone.values { index.remove(keys: keys) }
        return best.values.sorted { $0.relevance != $1.relevance ? $0.relevance > $1.relevance : $0.section < $1.section }
    }

    // MARK: - What a thought is embedded as

    /// `Question on Pricing memo (pricing-memo.docx), slide 7 · re: <parent line>`, and for a thought
    /// with no file behind it also ` · links: <titles>`. The kind word comes from the rules alone,
    /// and state and due date are left out, so a thought's vector changes only when its text does.
    ///
    /// Measured on the fixture vault (`SemanticBenchmarkTests`), with qwen3-embedding: "Question" and
    /// "To do" lift file-level ranking (palette 0.939/0.836 → 0.939/0.841, hybrid MRR 0.824 → 0.855);
    /// an "Intent" word and `links:` on thoughts that sit on a file each cost a partial hit
    /// (palette recall 0.939 → 0.924), so intents read as plain thoughts and file thoughts carry no
    /// link titles. Thought recall (`ThoughtEval`) is 0.95 / 0.95 either way.
    static func thoughtHeader(path: String, title: String?, tags: String?, hasFile: Bool, isFolder: Bool, kind: ThoughtKind,
                              anchor: FileAnchor?, parentLine: String?, links: [String]) -> String {
        let label: String
        switch kind {
        case .question: label = "Question"
        case .todo: label = "To do"
        case .intent, .idea: label = "Thought"
        }
        var header = label + " on " + thoughtSubject(path: path, title: title, tags: tags, hasFile: hasFile, isFolder: isFolder)
        if let anchor { header += ", " + anchor.label }
        if let parentLine, !parentLine.isEmpty { header += " · re: " + parentLine }
        if !hasFile, !links.isEmpty { header += " · links: " + links.joined(separator: ", ") }
        return header
    }

    static func thoughtSubject(path: String, title: String?, tags: String?, hasFile: Bool, isFolder: Bool) -> String {
        let ref = FileRef(relativePath: path)
        if ref.isInbox { return "a note with no file" }
        if ref.isWeb {
            let parts = ref.components
            let host = parts.count > 1 ? parts[1] : "web"
            var slug = (parts.last ?? "")
            if let dash = slug.lastIndex(of: "-") { slug = String(slug[..<dash]) }
            return "web page " + host + (slug.isEmpty ? "" : " (" + slug.replacingOccurrences(of: "-", with: " ") + ")")
        }
        if isFolder { return "folder " + ref.name }
        return SemanticChunker.FileContext(path: path, title: title, tags: tags).display
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: filePath(FileRef(relativePath: path)), isDirectory: &isDir) && isDir.boolValue
    }

    /// Titles (else names) of the files a thought links to, at most three.
    func linkedTitles(in text: String, from path: String, using resolver: LinkResolver) -> [String] {
        guard text.contains("[[") else { return [] }
        var resolved: [String] = []
        for target in Wikilink.parse(text) {
            if let dest = resolver.resolve(target, from: path), !resolved.contains(dest) { resolved.append(dest) }
            if resolved.count == 3 { break }
        }
        guard !resolved.isEmpty else { return [] }
        let titles = (try? read { db in
            try db.query("SELECT path, title FROM files WHERE path IN (SELECT value FROM json_each(?))", Self.json(resolved)) { ($0.string(0), $0.optionalString(1)) }
        }) ?? []
        let byPath = Dictionary(titles.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        return resolved.map { p in
            let name = FileRef(relativePath: p).name
            if let t = byPath[p] ?? nil, !t.isEmpty, t != name { return t }
            return name
        }
    }

    // MARK: - Snippets

    /// The passage that explains a semantic hit: its best sentence for the query (words the
    /// query shares are marked «…»), after the section title.
    func semanticSnippet(_ hit: SemanticHit, query: String = "") -> String {
        let title = Self.clean(hit.title)
        if hit.isCard { return title.isEmpty ? FileRef(relativePath: hit.path).name : title }
        let passage = Self.bestSentences(Self.clean(hit.text), query: query, width: 150)
        if passage.isEmpty { return title.isEmpty ? FileRef(relativePath: hit.path).name : title }
        if hit.commentID != nil || hit.ord <= 0 || title.isEmpty { return passage }
        // A slide or page's text usually starts with its title; don't say it twice.
        let plain = passage.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
        if plain.hasPrefix(title) || plain.dropFirst().hasPrefix(title) { return passage }
        return title + " — " + passage
    }

    /// The window of `text` around its sentence sharing the most words with `query`, marked.
    static func snippetStems(_ query: String) -> Set<String> {
        Set(FTSQuery.terms(query).flatMap { $0.text.lowercased().split { !$0.isLetter && !$0.isNumber } }
            .filter { $0.count >= 3 && !snippetStopwords.contains(String($0)) }
            .map { String($0.prefix(5)) })
    }

    /// Where in `chars` the sentence sharing the most words with the query starts (0 if none).
    static func bestSentenceStart(_ chars: [Character], stems: Set<String>) -> Int {
        guard !stems.isEmpty else { return 0 }
        var starts = [0]
        for (i, c) in chars.enumerated() where i + 1 < chars.count && (".!?。！？;；\n".contains(c)) { starts.append(i + 1) }
        var bestStart = 0, bestScore = 0
        for (n, s) in starts.enumerated() {
            let e = n + 1 < starts.count ? starts[n + 1] : chars.count
            guard e > s else { continue }
            let sentence = String(chars[s..<e]).lowercased()
            let score = stems.reduce(0) { $0 + (sentence.contains($1) ? 1 : 0) }
            if score > bestScore { bestScore = score; bestStart = s }
        }
        return bestStart
    }

    /// For a line-anchored passage, the line of its best sentence: the section's first line,
    /// plus lines before the passage, plus lines inside it before that sentence.
    static func passageLine(_ hit: SemanticHit, query: String) -> FileAnchor? {
        guard let anchor = hit.anchor, anchor.kind == .line, let base = Int(anchor.value), hit.commentID == nil, !hit.isCard,
              !["html", "htm", "xhtml", "rtf", "rtfd", "ipynb"].contains(FileRef(relativePath: hit.path).ext) else { return hit.anchor }
        let chars = Array(hit.text)
        let start = bestSentenceStart(chars, stems: snippetStems(query))
        let inside = chars[..<min(start, chars.count)].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return FileAnchor(kind: .line, value: String(base + hit.linesBefore + inside))
    }

    static func bestSentences(_ text: String, query: String, width: Int) -> String {
        guard !text.isEmpty else { return "" }
        let stems = snippetStems(query)
        let chars = Array(text)
        var start = bestSentenceStart(chars, stems: stems)
        while start < chars.count, chars[start].isWhitespace { start += 1 }
        let end = min(chars.count, start + width)
        var window = String(chars[start..<end])
        if end < chars.count, let space = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: space) > width / 2 {
            window = String(window[..<space])
        }
        for stem in stems {
            guard let re = try? NSRegularExpression(pattern: "(?i)\\b" + NSRegularExpression.escapedPattern(for: stem) + "\\w*") else { continue }
            window = re.stringByReplacingMatches(in: window, range: NSRange(window.startIndex..., in: window), withTemplate: "«$0»")
        }
        return (start > 0 ? "…" : "") + window + (end < chars.count ? "…" : "")
    }

    static let snippetStopwords: Set<String> = ["the", "and", "for", "what", "who", "how", "why", "when", "where", "which", "did", "does",
                                               "about", "with", "that", "this", "from", "into", "have", "has", "was", "were", "are", "our",
                                               "your", "say", "said", "doc", "file", "files", "document"]
}

// MARK: - The embedding pass

/// One run of `embedPending`: thoughts first, then sections, in pages; each page's
/// vectors are written in one transaction. Never holds the write lock while a model runs.
final class EmbeddingPass {
    let store: IndexStore
    let profile: EmbeddingProfile
    let embedder: Embedder
    private(set) var completed = false
    private var stopped = false
    private var secondsPerInput: Double = 0.03
    private let state: EmbeddingState

    init(store: IndexStore, profile: EmbeddingProfile, embedder: Embedder) {
        self.store = store; self.profile = profile; self.embedder = embedder
        state = store.embedding
    }

    private var cancelled: Bool { stopped || state.lock.withLock { state.cancelled } }

    struct Pending {
        var section: Int
        var path: String
        var ord: Int
        var anchor: FileAnchor?
        var title: String?
        var text: String
    }

    struct Prepared {
        var section: Int
        var text: String
        var title: String
        var chunks: [(offset: Int, length: Int, input: String, hash: Int64)]
    }

    // MARK: Thoughts

    func comments() {
        var after = 0
        var resolver: LinkResolver?
        while !cancelled {
            struct Row { var rowid: Int; var path: String; var anchorKind: String?; var anchorValue: String?; var text: String; var ts: Double
                         var title: String?; var tags: String?; var hasFile: Bool; var parent: String? }
            let raw: [Row] = (try? store.read { db in
                try db.query("""
                    SELECT c.rowid, c.path, c.anchor_kind, c.anchor_value, c.text, f.title, f.tags, c.ts, f.path IS NOT NULL,
                        CASE WHEN c.parent IS NULL THEN NULL ELSE
                            (SELECT substr(p.text, 1, 400) FROM comments p WHERE p.path = c.path AND p.uid = c.parent LIMIT 1) END
                    FROM comments c LEFT JOIN files f ON f.path = c.path
                    WHERE c.rowid > ?1 AND NOT EXISTS (SELECT 1 FROM comment_vectors v WHERE v.comment = c.rowid AND v.model = ?2)
                    ORDER BY c.rowid LIMIT 128
                    """, after, profile.id) {
                    Row(rowid: $0.int(0), path: $0.string(1), anchorKind: $0.optionalString(2), anchorValue: $0.optionalString(3), text: $0.string(4),
                        ts: $0.double(7), title: $0.optionalString(5), tags: $0.optionalString(6), hasFile: $0.int(8) != 0, parent: $0.optionalString(9))
                }
            }) ?? []
            guard let last = raw.last else { return }
            after = last.rowid
            if resolver == nil, raw.contains(where: { !$0.hasFile && $0.text.contains("[[") }) {
                resolver = LinkResolver(paths: (try? store.indexedPaths()) ?? [], aliases: [:])
            }
            let rows = raw.map { r -> (Int, String, String) in
                let anchor = IndexStore.anchor(r.anchorKind, r.anchorValue)
                let titles = r.hasFile ? [] : (resolver.map { store.linkedTitles(in: r.text, from: r.path, using: $0) } ?? [])
                let header = IndexStore.thoughtHeader(path: r.path, title: r.title, tags: r.tags, hasFile: r.hasFile,
                                                      isFolder: !r.hasFile && !FileRef(relativePath: r.path).isVirtual && store.isDirectory(r.path),
                                                      kind: ThoughtRules.read(r.text, at: Date(timeIntervalSince1970: r.ts)).kind,
                                                      anchor: anchor, parentLine: r.parent.map(IndexStore.firstLine), links: titles)
                let body = String(String.UnicodeScalarView(r.text.unicodeScalars.prefix(SemanticChunker.maxCommentScalars)))
                return (r.rowid, r.text, profile.document(header: header, body: body))
            }
            let hashes = rows.map { SemanticChunker.hash(profile.id, $0.2) }
            guard let vectors = vectors(for: rows.map(\.2), hashes: hashes) else { return }
            store.writeLock.lock()
            try? store.writer.transaction {
                for (i, row) in rows.enumerated() {
                    guard let v = vectors[i] else { continue }
                    guard try store.writer.scalarInt("SELECT count(*) FROM comments WHERE rowid = ? AND text = ?", row.0, row.1) == 1 else { continue }
                    try store.writer.run("INSERT OR REPLACE INTO comment_vectors(comment, model, hash, vector) VALUES (?, ?, ?, ?)",
                                         row.0, profile.id, Int(hashes[i]), v)
                }
            }
            store.writeLock.unlock()
            markDirty()
        }
    }

    // MARK: Sections

    /// Returns how many sections were written.
    func sections() -> Int {
        let top = (try? store.read { try $0.scalarInt("SELECT coalesce(max(rowid), 0) FROM sections") }) ?? 0
        let (watermark, lastSweep) = state.lock.withLock { (state.watermark[profile.id], state.lastSweep[profile.id]) }
        let sweep = watermark == nil || Date().timeIntervalSince(lastSweep ?? .distantPast) > IndexStore.sweepInterval
        var count = 0
        if sweep {
            count = sweepFiles()
            if completed { state.lock.withLock { state.lastSweep[profile.id] = Date() } }
        } else {
            count = newSections(after: max(0, watermark! - IndexStore.watermarkMargin))
        }
        if completed {
            // Rowids above `top` arrived during the pass; the next one picks them up.
            state.lock.withLock { state.watermark[profile.id] = top }
        }
        return count
    }

    /// Every file, newest first: what someone is likely to search for gets meaning first.
    private func sweepFiles() -> Int {
        var cursor: (mtime: Double, rowid: Int) = (.greatestFiniteMagnitude, Int.max)
        var count = 0
        while !cancelled {
            let files = (try? store.read { db in
                try db.query("""
                    SELECT rowid, path, mtime FROM files WHERE (mtime, rowid) < (?1, ?2) ORDER BY mtime DESC, rowid DESC LIMIT 24
                    """, cursor.mtime, cursor.rowid) { (rowid: $0.int(0), path: $0.string(1), mtime: $0.double(2)) }
            }) ?? []
            guard let last = files.last else { completed = true; break }
            cursor = (last.mtime, last.rowid)
            let pending = (try? store.read { db in
                try db.query("""
                    SELECT s.rowid, s.path, s.ord, s.anchor_kind, s.anchor_value, s.title, s.text FROM sections s
                    WHERE s.path IN (SELECT value FROM json_each(?1))
                    AND NOT EXISTS (SELECT 1 FROM embedding_spans e WHERE e.section = s.rowid AND e.model = ?2)
                    ORDER BY s.path, s.ord
                    """, IndexStore.json(files.map(\.path)), profile.id, row: Self.pendingRow)
            }) ?? []
            if pending.isEmpty { continue }
            guard process(pending) else { break }
            count += pending.count
        }
        return count
    }

    /// Sections added since the last finished pass, newest first.
    private func newSections(after watermark: Int) -> Int {
        var below = Int.max, count = 0
        while !cancelled {
            let pending = (try? store.read { db in
                try db.query("""
                    SELECT s.rowid, s.path, s.ord, s.anchor_kind, s.anchor_value, s.title, s.text FROM sections s
                    WHERE s.rowid > ?1 AND s.rowid < ?2
                    AND NOT EXISTS (SELECT 1 FROM embedding_spans e WHERE e.section = s.rowid AND e.model = ?3)
                    ORDER BY s.rowid DESC LIMIT 48
                    """, watermark, below, profile.id, row: Self.pendingRow)
            }) ?? []
            guard let last = pending.last else { completed = true; break }
            below = last.section
            guard process(pending) else { break }
            count += pending.count
        }
        return count
    }

    private static func pendingRow(_ r: Row) -> Pending {
        Pending(section: r.int(0), path: r.string(1), ord: r.int(2), anchor: IndexStore.anchor(r, 3), title: r.optionalString(5), text: r.string(6))
    }

    /// Chunks, embeds and writes one page. False when it had to stop.
    private func process(_ pending: [Pending]) -> Bool {
        let paths = Array(Set(pending.map(\.path)))
        let needsCard = Set(pending.filter { $0.ord == 0 && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.path))
        var files: [String: SemanticChunker.FileContext] = [:]
        var outlines: [String: (titles: [String], opening: String)] = [:]
        _ = try? store.read(snapshot: true) { db in
            _ = try db.query("SELECT path, title, tags FROM files WHERE path IN (SELECT value FROM json_each(?))", IndexStore.json(paths)) {
                files[$0.string(0)] = SemanticChunker.FileContext(path: $0.string(0), title: $0.optionalString(1), tags: $0.optionalString(2))
            }
            if !needsCard.isEmpty {
                _ = try db.query("""
                    SELECT path, coalesce(title, ''), substr(text, 1, 600) FROM sections
                    WHERE path IN (SELECT value FROM json_each(?)) AND ord > 0 ORDER BY path, ord
                    """, IndexStore.json(Array(needsCard))) {
                    var o = outlines[$0.string(0)] ?? ([], "")
                    o.titles.append($0.string(1))
                    if o.opening.count < 300 { o.opening += (o.opening.isEmpty ? "" : "\n") + $0.string(2) }
                    outlines[$0.string(0)] = o
                }
            }
        }
        var perFile: [String: Int] = [:]
        var prepared: [Prepared] = []
        for p in pending {
            let file = files[p.path] ?? SemanticChunker.FileContext(path: p.path, title: nil, tags: nil)
            var chunks: [(Int, Int, String, Int64)] = []
            var bodies: [(offset: Int, length: Int, body: String)] = []
            let header: String
            if p.ord == 0 {
                header = SemanticChunker.fileHeader(file)
                if needsCard.contains(p.path) {
                    let o = outlines[p.path] ?? ([], "")
                    bodies = [(0, 0, SemanticChunker.card(outline: o.titles, opening: o.opening))]
                } else {
                    bodies = SemanticChunker.split(p.text).map { ($0.offset, $0.length, $0.body) }
                    if bodies.isEmpty { bodies = [(0, 0, "")] }
                }
            } else {
                header = SemanticChunker.sectionHeader(file, title: p.title, anchor: p.anchor)
                let columns = SemanticChunker.columnHeader(p.text)
                bodies = SemanticChunker.split(p.text).enumerated().map { i, c in
                    (c.offset, c.length, i > 0 && columns != nil ? "Columns: " + columns! + "\n" + c.body : c.body)
                }
            }
            for b in bodies {
                guard perFile[p.path, default: 0] < SemanticChunker.maxChunksPerFile else { break }
                perFile[p.path, default: 0] += 1
                let input = profile.document(header: header, body: b.body)
                chunks.append((b.offset, b.length, input, SemanticChunker.hash(profile.id, input)))
            }
            prepared.append(Prepared(section: p.section, text: p.text, title: p.title ?? "", chunks: chunks))
        }
        let inputs = prepared.flatMap { $0.chunks.map(\.2) }
        let hashes = prepared.flatMap { $0.chunks.map(\.3) }
        guard let vectors = vectors(for: inputs, hashes: hashes) else { return false }
        var i = 0
        store.writeLock.lock()
        do {
            try store.writer.transaction {
                for p in prepared {
                    let slice = vectors[i..<(i + p.chunks.count)]
                    i += p.chunks.count
                    // A re-extraction may have replaced the row (or reused its rowid) meanwhile.
                    guard try store.writer.scalarInt("SELECT count(*) FROM sections WHERE rowid = ? AND text = ? AND coalesce(title, '') = ?",
                                                     p.section, p.text, p.title) == 1 else { continue }
                    try store.writer.run("DELETE FROM embedding_spans WHERE section = ?", p.section)
                    var wrote = false
                    for (chunk, vector) in zip(p.chunks, slice) {
                        guard let vector else { continue }
                        try store.writer.run("INSERT INTO embedding_spans(section, offset, model, vector, hash, length) VALUES (?, ?, ?, ?, ?, ?)",
                                             p.section, chunk.offset, profile.id, vector, Int(chunk.hash), chunk.length)
                        wrote = true
                    }
                    if !wrote {
                        try store.writer.run("INSERT INTO embedding_spans(section, offset, model, vector, hash, length) VALUES (?, -1, ?, x'', NULL, 0)",
                                             p.section, profile.id)
                    }
                }
            }
        } catch {
            store.writeLock.unlock()
            return false
        }
        store.writeLock.unlock()
        markDirty()
        return true
    }

    // MARK: Vectors

    /// Encoded vectors for `inputs`: from the cache by hash, else from the model in batches
    /// sized to about a third of a second each. Nil when the model stopped answering.
    private func vectors(for inputs: [String], hashes: [Int64]) -> [Data?]? {
        guard !inputs.isEmpty else { return [] }
        var out = [Data?](repeating: nil, count: inputs.count)
        var cached: [Int64: Data] = [:]
        _ = try? store.read { db in
            for start in stride(from: 0, to: hashes.count, by: 500) {
                let slice = Array(hashes[start..<min(hashes.count, start + 500)])
                _ = try db.query("SELECT hash, vector FROM semantic_cache WHERE model = ?1 AND hash IN (SELECT value FROM json_each(?2))",
                                 profile.id, IndexStore.json(slice.map { Int($0) })) { cached[Int64($0.int(0))] = $0.data(1) }
            }
        }
        var missing: [Int] = []
        var firstOf: [Int64: Int] = [:]
        var duplicates: [(Int, Int)] = []
        for (i, h) in hashes.enumerated() {
            if let v = cached[h] { out[i] = v }
            else if let j = firstOf[h] { duplicates.append((i, j)) }
            else { firstOf[h] = i; missing.append(i) }
        }
        var next = 0
        while next < missing.count {
            if cancelled || IndexStore.onLowBattery() { stopped = true; return nil }
            if embedder.fake == nil { SemanticRuntime.shared.waitForQuiet(cancelled: { self.cancelled }) }
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { Thread.sleep(forTimeInterval: 2) }
            let size = max(1, min(IndexStore.embedBatch, Int(0.35 / max(0.001, secondsPerInput))))
            let batch = Array(missing[next..<min(missing.count, next + size)])
            let started = Date()
            guard let vectors = embedder.embed(batch.map { inputs[$0] }, profile: profile, timeout: 120), vectors.count == batch.count else {
                stopped = true
                return nil
            }
            let elapsed = Date().timeIntervalSince(started)
            secondsPerInput = 0.7 * secondsPerInput + 0.3 * elapsed / Double(batch.count)
            for (i, v) in zip(batch, vectors) { out[i] = VectorCodec.encode(Self.stored(v, profile)) }
            next += batch.count
            // Leave the GPU some air between batches.
            if case .ollama = profile.backend { Thread.sleep(forTimeInterval: min(0.25, elapsed * 0.15)) }
        }
        for (i, j) in duplicates { out[i] = out[j] }
        return out
    }

    /// Matryoshka models are stored at the dimensions search uses: half the disk and a
    /// faster load, with no loss (truncating later gives the same vector).
    static func stored(_ v: [Float], _ profile: EmbeddingProfile) -> [Float] {
        guard let d = profile.memoryDimensions, d < v.count else { return v }
        return Embedder.normalized(Array(v.prefix(d)))
    }

    private func markDirty() { state.lock.withLock { state.dirty = true } }

    /// After a finished pass: old cached vectors go after two weeks, or sooner when the cache
    /// outgrows the live index.
    func collectGarbage() {
        store.writeLock.lock(); defer { store.writeLock.unlock() }
        try? store.writer.transaction {
            try store.writer.run("DELETE FROM semantic_cache WHERE ts < ?", Date().timeIntervalSince1970 - 14 * 86_400)
            let live = try store.writer.scalarInt("SELECT count(*) FROM embedding_spans")
            let cached = try store.writer.scalarInt("SELECT count(*) FROM semantic_cache")
            let keep = max(50_000, live)
            if cached > keep {
                try store.writer.run("""
                    DELETE FROM semantic_cache WHERE (model, hash) IN (SELECT model, hash FROM semantic_cache ORDER BY ts LIMIT ?)
                    """, cached - keep)
            }
        }
    }
}
