import Foundation
import FlamingoCore

extension IndexStore {
    // MARK: - Embedding

    /// Embed new sections in the background after each reindex and update. Off under XCTest,
    /// where tests call `embedPending` themselves.
    public nonisolated(unsafe) static var autoEmbed = NSClassFromString("XCTestCase") == nil

    static let embedBatch = 32
    /// Below this cosine a section isn't about the query at all.
    static let semanticFloor: Float = 0.55
    /// nomic's scores bunch together; past this distance below the best hit they're noise.
    static let semanticSpread: Float = 0.1
    /// Keyword ranks count a little more, so an exact match still leads.
    static let semanticWeight = 0.8
    /// After Ollama fails, semantic search waits this long before trying it again.
    static let downInterval: TimeInterval = 30

    /// Queues `embedPending` at background QoS. Calls while one is queued coalesce.
    public func scheduleEmbedding() {
        let state = embedding
        let first = state.lock.withLock { () -> Bool in
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard first else { return }
        state.queue.async { [weak self] in
            state.lock.withLock { state.scheduled = false }
            self?.embedPending()
        }
    }

    /// Embeds every section without a vector, 32 at a time, with `nomic-embed-text`.
    /// Stops quietly when Ollama isn't there; the next reindex tries again. Returns how many
    /// sections it embedded.
    @discardableResult
    public func embedPending() -> Int {
        let embedder = embedding.lock.withLock { embedding.embedder }
        let state = embedding
        let start = state.lock.withLock { () -> Bool in
            defer { state.running = true }
            return !state.running
        }
        guard start else { return 0 }
        defer { state.lock.withLock { state.running = false } }

        var last = 0
        var count = 0
        while true {
            let rows = (try? read { db in
                try db.query("""
                    SELECT s.rowid, s.title, s.text FROM sections s LEFT JOIN embeddings e ON e.section = s.rowid
                    WHERE e.section IS NULL AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                    """, last, Self.embedBatch) { (id: $0.int(0), title: $0.optionalString(1), text: $0.string(2)) }
            }) ?? []
            guard let end = rows.last?.id else { break }
            last = end
            guard let vectors = embedder.embed(rows.map { Embedder.document(title: $0.title, text: $0.text) }, timeout: 120) else {
                state.lock.withLock { state.downSince = Date() }
                break
            }
            writeLock.lock()
            // The section may have been re-extracted meanwhile; only a row with the same text gets the vector.
            try? writer.transaction {
                for (row, v) in zip(rows, vectors) {
                    try writer.run("""
                        INSERT OR REPLACE INTO embeddings(section, model, vector)
                        SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM sections WHERE rowid = ?1 AND text = ?4)
                        """, row.id, Embedder.model, VectorMatrix.blob(v), row.text)
                }
            }
            writeLock.unlock()
            count += rows.count
            state.lock.withLock { state.matrix = nil; state.downSince = nil }
        }
        return count
    }

    /// Sections with a vector, and sections in all.
    public func embeddingProgress() throws -> (embedded: Int, total: Int) {
        try read { db in
            (try db.scalarInt("SELECT count(*) FROM embeddings"), try db.scalarInt("SELECT count(*) FROM sections"))
        }
    }

    // MARK: - Semantic search

    struct SemanticHit {
        var section: Int
        var path: String
        var ord: Int
        var anchor: FileAnchor?
        var title: String
        var text: String
        var score: Float
    }

    /// Sections nearest the query by cosine, best first. Empty when nothing is embedded or
    /// Ollama can't embed the query within half a second.
    func semanticSections(_ query: String, limit: Int) -> [SemanticHit] {
        let embedder = embedding.lock.withLock { embedding.embedder }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let matrix = loadMatrix(), !matrix.isEmpty, let vector = queryVector(q, embedder: embedder) else { return [] }
        var nearest = matrix.nearest(vector, limit: limit, floor: Self.semanticFloor)
        guard let best = nearest.first?.score else { return [] }
        nearest = nearest.filter { $0.score >= best - Self.semanticSpread }
        let rows = (try? read { db in
            try db.query("""
                SELECT rowid, path, ord, anchor_kind, anchor_value, coalesce(title, ''), substr(text, 1, 400)
                FROM sections WHERE rowid IN (SELECT value FROM json_each(?))
                """, Self.json(nearest.map(\.section))) {
                ($0.int(0), ($0.string(1), $0.int(2), Self.anchor($0, 3), $0.string(5), $0.string(6)))
            }
        }) ?? []
        let byID = Dictionary(rows, uniquingKeysWith: { a, _ in a })
        return nearest.compactMap { n in
            guard let r = byID[n.section] else { return nil }
            return SemanticHit(section: n.section, path: r.0, ord: r.1, anchor: r.2, title: r.3, text: r.4, score: n.score)
        }
    }

    func semanticSnippet(_ hit: SemanticHit) -> String {
        let text = Self.clean(hit.text)
        let lead = text.count > 120 ? String(text.prefix(120)) + "…" : text
        if hit.ord == 0 || hit.title.isEmpty { return lead }
        return lead.isEmpty ? Self.clean(hit.title) : Self.clean(hit.title) + " — " + lead
    }

    private func queryVector(_ q: String, embedder: Embedder) -> [Float]? {
        let state = embedding
        let cached: [Float]? = state.lock.withLock {
            if let down = state.downSince, Date().timeIntervalSince(down) < Self.downInterval { return [] }
            return state.queries[q]
        }
        if let cached { return cached.isEmpty ? nil : cached }
        guard let v = embedder.embed([Embedder.query(q)], timeout: 0.5)?.first else {
            state.lock.withLock { state.downSince = Date() }
            return nil
        }
        state.lock.withLock {
            if state.queries.count > 256 { state.queries.removeAll() }
            state.queries[q] = v
        }
        return v
    }

    private func loadMatrix() -> VectorMatrix? {
        if let m = embedding.lock.withLock({ embedding.matrix }) { return m }
        guard let rows = try? read({ db in
            try db.query("SELECT section, vector FROM embeddings WHERE model = ?", Embedder.model) { ($0.int(0), $0.data(1)) }
        }) else { return nil }
        let dim = rows.first.map { $0.1.count / MemoryLayout<Float>.size } ?? 0
        var sections: [Int] = []
        var values: [Float] = []
        sections.reserveCapacity(rows.count)
        values.reserveCapacity(rows.count * dim)
        for (id, blob) in rows where blob.count == dim * MemoryLayout<Float>.size && dim > 0 {
            sections.append(id)
            values += VectorMatrix.floats(blob)
        }
        let m = VectorMatrix(sections: sections, dim: dim, values: values)
        embedding.lock.withLock { embedding.matrix = m }
        return m
    }
}
