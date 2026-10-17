import Foundation
import FlamingoCore

/// One semantic search result with what explains it.
public struct SemanticSearchHit: Sendable, Equatable {
    /// File, location (section anchor, or the thought's), snippet (the passage's best
    /// sentence, query words marked «…») and `commentID` for thoughts. `score` is `relevance`.
    public var hit: SearchHit
    /// The whole passage that matched.
    public var passage: String
    /// How clearly the passage answers the query: 0 at the model's floor, 1 at a strong match
    /// (can exceed 1). Comparable across models.
    public var relevance: Double
    /// Raw cosine similarity under `model`.
    public var score: Double
    public var model: String
}

extension IndexStore {
    /// Passages (and thoughts) nearest the query by meaning, one per section, best first.
    /// Empty when nothing is embedded or no model can embed the query within a few seconds.
    public func semanticSearch(_ query: String, inFolder folder: String? = nil, limit: Int = 20) throws -> [SemanticSearchHit] {
        semanticSections(query, limit: limit, folder: folder).map {
            SemanticSearchHit(hit: semanticHit($0, query: query), passage: Self.clean($0.text), relevance: $0.relevance,
                              score: Double($0.score), model: $0.model)
        }
    }
}

/// Synthetic latency benchmarks for the in-memory vector index and file similarity.
public enum SemanticBench {
    /// Builds a throwaway index with `passages` vectors (512 dimensions, as stored for
    /// qwen3-embedding), ten passages a file in clustered topics, and times loading, queries,
    /// `similarFiles` and `similarPairs`. Returns report lines.
    public static func vectorSearch(passages: Int, in scratch: URL) throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-vector-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(vault: Vault(root: root))
        guard store.ensureSemanticSchema() else { return ["semantic schema unavailable"] }
        let model = "qwen3-embedding:0.6b", stored = 512
        let files = max(1, passages / 10), topics = max(4, files / 25)
        var rng = SystemRandomNumberGenerator()
        func gaussian() -> Float {
            let u = Float.random(in: Float.ulpOfOne..<1, using: &rng), v = Float.random(in: 0..<1, using: &rng)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        let centers = (0..<topics).map { _ in Embedder.normalized((0..<stored).map { _ in gaussian() }) }
        var lines: [String] = []
        var t = Date()
        store.writeLock.lock()
        try store.writer.exec("DROP TRIGGER IF EXISTS sections_ai")   // skip FTS: not what's measured
        try store.writer.transaction {
            try store.writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('semantic_model', ?)", model)
            var section = 0
            for f in 0..<files {
                let path = "topic\(f % topics)/file\(f).md"
                try store.writer.run("INSERT INTO files(path, mtime, size, ext, indexed_at) VALUES (?, ?, 1, 'md', 0)", path, Double(f))
                let center = centers[f % topics]
                for p in 0..<min(10, passages - f * 10) {
                    section += 1
                    try store.writer.run("INSERT INTO sections(rowid, path, ord, title, text) VALUES (?, ?, ?, '', 'x')", section, path, p)
                    let v = Embedder.normalized(center.map { $0 + gaussian() * 0.035 })
                    try store.writer.run("INSERT INTO embedding_spans(section, offset, model, vector, hash, length) VALUES (?, 0, ?, ?, ?, 1)",
                                         section, model, VectorCodec.encode(v), section)
                }
            }
        }
        store.writeLock.unlock()
        lines.append("built \(passages) passages / \(files) files in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")

        t = Date()
        let indexes = store.semanticIndexes()
        guard let (index, profile) = indexes.first else { return lines + ["no index"] }
        let load = Date().timeIntervalSince(t)
        let bytes = index.count * (index.dim + 4 + 8 + 8 + 4 + 4 + 1 + 40)
        lines.append("load: \(String(format: "%.0f", load * 1000)) ms, \(index.count) rows × \(index.dim) dims, ~\(bytes / 1_048_576) MB in memory")

        func time(_ runs: Int, _ body: () -> Void) -> (p50: Double, p95: Double) {
            var ms: [Double] = []
            for _ in 0..<runs { let s = DispatchTime.now(); body(); ms.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6) }
            ms.sort()
            return (ms[ms.count / 2], ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))])
        }
        let queries = (0..<40).map { i in Embedder.normalized(centers[i % topics].map { $0 + gaussian() * 0.05 }) }
        var qi = 0
        let worst = time(40) { _ = index.nearest(queries[qi % queries.count], k: 200, floor: -1); qi += 1 }
        let typical = time(40) { _ = index.nearest(queries[qi % queries.count], k: 200, floor: profile.floor); qi += 1 }
        lines.append("query top-200: p50 \(String(format: "%.1f", typical.p50)) ms, p95 \(String(format: "%.1f", typical.p95)) ms (no floor: p50 \(String(format: "%.1f", worst.p50)) ms)")

        t = Date()
        let first = try store.similarFiles(to: FileRef(relativePath: "topic0/file0.md"), limit: 10)
        let build = Date().timeIntervalSince(t)
        var fi = 0
        let similar = time(20) { _ = try? store.similarFiles(to: FileRef(relativePath: "topic\(fi % topics)/file\(fi).md"), limit: 10); fi += 1 }
        lines.append("similarFiles: first \(String(format: "%.0f", build * 1000)) ms (builds \(files) file vectors), then p50 \(String(format: "%.2f", similar.p50)) ms, p95 \(String(format: "%.2f", similar.p95)) ms; \(first.count) results")

        if files <= 60_000 {
            t = Date()
            let pairs = try store.similarPairs(minScore: Double(profile.relatedFloor), perFile: 3)
            lines.append("similarPairs(perFile: 3) over \(files) files: \(String(format: "%.2f", Date().timeIntervalSince(t)))s, \(pairs.count) pairs")
        }
        return lines
    }
}
