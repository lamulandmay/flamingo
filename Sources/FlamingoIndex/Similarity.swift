import Accelerate
import Foundation
import FlamingoCore

/// One vector per file: the normalized mean of its passage vectors (thoughts count half,
/// and only when the file has little text of its own). Built from the in-memory passage
/// index, cached until it changes, and rebuilt at most every few seconds while embedding runs.
final class FileVectors: @unchecked Sendable {
    let generation: Int
    let built: Date
    let dim: Int
    let paths: [String]
    let indexOf: [String: Int]
    /// Unit rows, Int8 with a scale each.
    let codes: [Int8]
    let scales: [Float]
    /// Passage rows of each file in the passage index: `rows[starts[i]..<starts[i + 1]]`.
    let starts: [Int]
    let rows: [Int32]

    init(generation: Int, dim: Int, paths: [String], codes: [Int8], scales: [Float], starts: [Int], rows: [Int32]) {
        self.generation = generation; self.built = Date(); self.dim = dim; self.paths = paths
        self.codes = codes; self.scales = scales; self.starts = starts; self.rows = rows
        indexOf = Dictionary(paths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    var count: Int { paths.count }

    func vector(_ i: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dim)
        codes.withUnsafeBufferPointer { vDSP_vflt8($0.baseAddress! + i * dim, 1, &out, 1, vDSP_Length(dim)) }
        var s = scales[i]
        vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(dim))
        return out
    }

    /// Rows `range` dequantized into one row-major Float32 block.
    func block(_ range: Range<Int>, into out: inout [Float]) {
        let n = range.count * dim
        if out.count < n { out = [Float](repeating: 0, count: n) }
        codes.withUnsafeBufferPointer { vDSP_vflt8($0.baseAddress! + range.lowerBound * dim, 1, &out, 1, vDSP_Length(n)) }
        for (j, i) in range.enumerated() {
            var s = scales[i]
            out.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress! + j * dim, 1, &s, p.baseAddress! + j * dim, 1, vDSP_Length(dim)) }
        }
    }

    /// Cosine of every file with `query` (unit, `dim` long).
    func scores(_ query: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        var floats: [Float] = []
        let blockRows = 2048
        var start = 0
        while start < count {
            let end = min(count, start + blockRows)
            block(start..<end, into: &floats)
            out.withUnsafeMutableBufferPointer { p in
                vDSP_mmul(floats, 1, query, 1, p.baseAddress! + start, 1, vDSP_Length(end - start), 1, vDSP_Length(dim))
            }
            start = end
        }
        return out
    }
}

extension IndexStore {
    /// Files whose content is closest in meaning to `ref`'s, best first, excluding `ref`:
    /// `score` is the cosine of the two files' mean passage vectors (0…1), `passage` the other
    /// file's passage closest to `ref` (a short excerpt). Only neighbours at or above
    /// `similarityFloor()` are returned. Empty, not an error, when nothing is embedded yet or
    /// `ref` has no vectors. Cheap enough for every selection change: file vectors are cached
    /// across calls and results per file are memoized until the vectors change.
    public func similarFiles(to ref: FileRef, limit: Int) throws -> [(file: FileRef, score: Double, passage: String?)] {
        guard limit > 0, let (index, profile) = similarityIndex(), let files = fileVectors(index) else { return [] }
        let cacheKey = "\(ref.relativePath)\u{1}\(limit)\u{1}\(files.generation)\u{1}\(ObjectIdentifier(files).hashValue)"
        if let cached = embedding.lock.withLock({ embedding.similar[cacheKey] }) { return cached }
        guard let query = fileVector(of: ref, files: files, index: index) else { return [] }
        let scores = files.scores(query)
        let floor = profile.relatedFloor
        var top = TopK(k: limit + 1, floor: floor)
        for (i, s) in scores.enumerated() where s >= top.threshold && files.paths[i] != ref.relativePath { top.insert(Int32(i), s) }
        var picked = top.sorted().prefix(limit).map { (Int($0.0), $0.1) }
        // Drop files that left the index since the vectors were built.
        let present = Set((try? read { db in
            try db.query("SELECT path FROM files WHERE path IN (SELECT value FROM json_each(?))", Self.json(picked.map { files.paths[$0.0] })) { $0.string(0) }
        }) ?? [])
        picked = picked.filter { present.contains(files.paths[$0.0]) }
        let passages = bestPassages(for: picked.map(\.0), query: query, files: files, index: index)
        let result = picked.enumerated().map { n, p in
            (file: FileRef(relativePath: files.paths[p.0]), score: Double(max(0, min(1, p.1))), passage: passages[n])
        }
        embedding.lock.withLock {
            if embedding.similar.count > 256 { embedding.similar.removeAll() }
            embedding.similar[cacheKey] = result
        }
        return result
    }

    /// Whole-vault suggested connections: pairs of files (relative paths, `a < b`, each pair
    /// once) whose mean passage vectors have cosine ≥ `minScore`, each file contributing at
    /// most its `perFile` nearest. Best first.
    ///
    /// Cost is quadratic, done as blocked matrix products on Accelerate: about a second for
    /// 20k files on an M-series Mac. Above `similarPairsFileCap` (50,000) files only the most
    /// recently modified 50,000 take part. Call off the main thread. Empty when nothing is embedded.
    ///
    /// The answer is kept until the file vectors change. With `reuseFor` it is kept that many
    /// seconds even then: on a whole disk the vectors change every few seconds while embedding
    /// runs, and this is the most expensive part of a graph build.
    public func similarPairs(minScore: Double, perFile: Int, reuseFor maxAge: TimeInterval = 0) throws -> [(a: String, b: String, score: Double)] {
        guard perFile > 0 else { return [] }
        let last = embedding.lock.withLock { embedding.pairs }
        if maxAge > 0, let last, last.answers(minScore: minScore, perFile: perFile),
           Date().timeIntervalSince(last.made) < maxAge, last.model == largestSemanticModel() { return last.pairs }
        guard let (index, _) = similarityIndex(), let files = fileVectors(index), files.count > 1 else { return [] }
        if let last, last.vectors === files, last.model == index.model, last.answers(minScore: minScore, perFile: perFile) { return last.pairs }
        let pairs = computeSimilarPairs(files, minScore: minScore, perFile: perFile)
        embedding.lock.withLock {
            embedding.pairs = SimilarPairsMemo(model: index.model, vectors: files, minScore: minScore, perFile: perFile, pairs: pairs)
        }
        return pairs
    }

    /// The model `similarityIndex` would pick, from the indexes already loaded: no refresh.
    private func largestSemanticModel() -> String? {
        embedding.lock.withLock { embedding.indexes }.max { $0.value.count < $1.value.count }?.key
    }

    private func computeSimilarPairs(_ files: FileVectors, minScore: Double, perFile: Int) -> [(a: String, b: String, score: Double)] {
        var chosen = Array(0..<files.count)
        if files.count > Self.similarPairsFileCap {
            let mtimes = Dictionary((try? read { db in try db.query("SELECT path, mtime FROM files") { ($0.string(0), $0.double(1)) } }) ?? [],
                                    uniquingKeysWith: max)
            chosen.sort { (mtimes[files.paths[$0]] ?? 0) > (mtimes[files.paths[$1]] ?? 0) }
            chosen = Array(chosen.prefix(Self.similarPairsFileCap)).sorted()
        }
        let n = chosen.count, dim = files.dim
        // Dequantize the chosen rows once: n × dim floats.
        var matrix = [Float](repeating: 0, count: n * dim)
        var scratch: [Float] = []
        for (j, i) in chosen.enumerated() {
            files.block(i..<(i + 1), into: &scratch)
            matrix.withUnsafeMutableBufferPointer { p in
                scratch.withUnsafeBufferPointer { s in (p.baseAddress! + j * dim).update(from: s.baseAddress!, count: dim) }
            }
        }
        let threshold = Float(minScore)
        let blockRows = 128
        var best: [Int64: Float] = [:]
        let lock = NSLock()
        let blocks = (n + blockRows - 1) / blockRows
        // (rows × dim) · (dim × n) per block, against the transpose built once.
        var transposed = [Float](repeating: 0, count: n * dim)
        vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(dim), vDSP_Length(n))
        matrix.withUnsafeBufferPointer { m in
            transposed.withUnsafeBufferPointer { t in
            DispatchQueue.concurrentPerform(iterations: blocks) { b in
                let start = b * blockRows, rows = min(blockRows, n - start)
                var scores = [Float](repeating: 0, count: rows * n)
                vDSP_mmul(m.baseAddress! + start * dim, 1, t.baseAddress!, 1, &scores, 1, vDSP_Length(rows), vDSP_Length(n), vDSP_Length(dim))
                var local: [(Int64, Float)] = []
                scores.withUnsafeMutableBufferPointer { s in
                    for r in 0..<rows {
                        let row = s.baseAddress! + r * n
                        row[start + r] = -2
                        for _ in 0..<perFile {
                            var value: Float = 0
                            var at: vDSP_Length = 0
                            vDSP_maxvi(row, 1, &value, &at, vDSP_Length(n))
                            guard value >= threshold else { break }
                            row[Int(at)] = -2
                            let a = start + r, c = Int(at)
                            local.append((Int64(min(a, c)) << 32 | Int64(max(a, c)), value))
                        }
                    }
                }
                lock.withLock { for (k, v) in local where v > best[k] ?? -2 { best[k] = v } }
            }
            }
        }
        return best.map { key, score -> (a: String, b: String, score: Double) in
            let x = files.paths[chosen[Int(key >> 32)]], y = files.paths[chosen[Int(key & 0xffff_ffff)]]
            return (a: min(x, y), b: max(x, y), score: Double(max(0, min(1, score))))
        }.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.a, $0.b) < ($1.a, $1.b) }
    }

    public static let similarPairsFileCap = 50_000

    /// The cosine below which two files' contents aren't meaningfully related under the
    /// current model (0.62 for qwen3-embedding). A sensible `minScore` for `similarPairs`.
    public func similarityFloor() -> Double {
        Double(similarityIndex()?.1.relatedFloor ?? EmbeddingProfile.known[0].make("").relatedFloor)
    }

    // MARK: - Internals

    /// The model with the most passages, when several are present mid-migration.
    func similarityIndex() -> (VectorIndex, EmbeddingProfile)? {
        semanticIndexes().max { $0.0.count < $1.0.count }
    }

    /// File vectors for `index`, rebuilt when the index changed (at most every 5 seconds).
    func fileVectors(_ index: VectorIndex) -> FileVectors? {
        let cached = index.fileVectors
        if let cached, cached.generation == index.generation || Date().timeIntervalSince(cached.built) < 5 { return cached.count > 0 ? cached : nil }
        let generation = index.generation
        // Owner → path, for passages and thoughts.
        var owners: [(row: Int32, owner: Int64, comment: Bool)] = []
        index.forEachRow { row, key, owner in owners.append((row, owner, key < 0)) }
        guard !owners.isEmpty else { return nil }
        var sectionPath: [Int64: Int32] = [:], commentPath: [Int64: Int32] = [:]
        var paths: [String] = [], pathIndex: [String: Int32] = [:]
        func intern(_ p: String) -> Int32 {
            if let i = pathIndex[p] { return i }
            let i = Int32(paths.count); paths.append(p); pathIndex[p] = i; return i
        }
        let wanted = Set(owners.filter { !$0.comment }.map(\.owner))
        let wantedComments = Set(owners.filter(\.comment).map(\.owner))
        _ = try? read(snapshot: true) { db in
            _ = try db.query("SELECT rowid, path FROM sections INDEXED BY sections_path WHERE path >= ''") {
                let id = Int64($0.int(0))
                if wanted.contains(id) { sectionPath[id] = intern($0.string(1)) }
            }
            if !wantedComments.isEmpty {
                _ = try db.query("SELECT rowid, path FROM comments") {
                    let id = Int64($0.int(0))
                    if wantedComments.contains(id) { commentPath[id] = intern($0.string(1)) }
                }
            }
        }
        var byFile: [(file: Int32, row: Int32, comment: Bool)] = []
        byFile.reserveCapacity(owners.count)
        for o in owners {
            if o.comment { if let f = commentPath[o.owner] { byFile.append((f, o.row, true)) } }
            else if let f = sectionPath[o.owner] { byFile.append((f, o.row, false)) }
        }
        byFile.sort { $0.file != $1.file ? $0.file < $1.file : $0.row < $1.row }
        let dim = index.dim
        var codes: [Int8] = [], scales: [Float] = [], starts: [Int] = [0], rows: [Int32] = [], kept: [String] = []
        codes.reserveCapacity(paths.count * dim)
        var i = 0
        var sum = [Float](repeating: 0, count: dim)
        while i < byFile.count {
            let file = byFile[i].file
            var j = i
            while j < byFile.count, byFile[j].file == file { j += 1 }
            let group = byFile[i..<j]
            let content = group.filter { !$0.comment }
            for k in sum.indices { sum[k] = 0 }
            for g in content { index.accumulate(g.row, weight: 1, into: &sum) }
            // Thoughts describe the file; they matter most when it has little text.
            let commentWeight: Float = content.count >= 4 ? 0.25 : 0.5
            for g in group where g.comment { index.accumulate(g.row, weight: commentWeight, into: &sum) }
            let v = Embedder.normalized(sum)
            if v.contains(where: { $0 != 0 }) {
                let data = VectorCodec.encode(v)
                data.withUnsafeBytes { raw in
                    let scale = Float(bitPattern: UInt32(littleEndian: raw.load(as: UInt32.self)))
                    scales.append(scale)
                    codes.append(contentsOf: UnsafeBufferPointer(start: raw.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int8.self), count: dim))
                }
                kept.append(paths[Int(file)])
                rows.append(contentsOf: group.map(\.row))
                starts.append(rows.count)
            }
            i = j
        }
        let built = FileVectors(generation: generation, dim: dim, paths: kept, codes: codes, scales: scales, starts: starts, rows: rows)
        index.fileVectors = built
        return built.count > 0 ? built : nil
    }

    /// `ref`'s file vector: cached, or averaged now from its sections (a file renamed or
    /// embedded since the cache was built).
    private func fileVector(of ref: FileRef, files: FileVectors, index: VectorIndex) -> [Float]? {
        if let i = files.indexOf[ref.relativePath] { return files.vector(i) }
        let sections = Set((try? read { db in
            try db.query("SELECT rowid FROM sections WHERE path = ?", ref.relativePath) { Int64($0.int(0)) }
        }) ?? [])
        guard !sections.isEmpty else { return nil }
        var rows: [Int32] = []
        index.forEachRow { row, key, owner in if key > 0, sections.contains(owner) { rows.append(row) } }
        guard !rows.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: index.dim)
        for r in rows { index.accumulate(r, weight: 1, into: &sum) }
        let v = Embedder.normalized(sum)
        return v.contains(where: { $0 != 0 }) ? v : nil
    }

    /// For each file, its passage nearest `query`, as a one-line excerpt.
    private func bestPassages(for picked: [Int], query: [Float], files: FileVectors, index: VectorIndex) -> [String?] {
        var best: [(row: VectorIndex.Row, score: Float)?] = []
        for i in picked {
            var top: (VectorIndex.Row, Float)?
            let rows = files.rows[files.starts[i]..<files.starts[i + 1]]
            // A file card has no text of its own to show; prefer real passages.
            let shown = rows.filter { let r = index.row($0); return r.isComment || r.length > 0 }
            for r in shown.isEmpty ? Array(rows) : shown {
                let v = index.vector(r)
                var s: Float = 0
                vDSP_dotpr(v, 1, query, 1, &s, vDSP_Length(min(v.count, query.count)))
                if top == nil || s > top!.1 { top = (index.row(r), s) }
            }
            best.append(top.map { ($0.0, $0.1) })
        }
        let spanKeys = best.compactMap { $0 }.filter { !$0.row.isComment }.map(\.row.key)
        let commentIDs = best.compactMap { $0 }.filter { $0.row.isComment }.map(\.row.owner)
        var text: [Int64: String] = [:]
        _ = try? read(snapshot: true) { db in
            if !spanKeys.isEmpty {
                _ = try db.query("""
                    SELECT e.rowid, CASE WHEN coalesce(e.length, 0) > 0 THEN substr(s.text, e.offset + 1, e.length) ELSE '' END, coalesce(s.title, '')
                    FROM embedding_spans e JOIN sections s ON s.rowid = e.section WHERE e.rowid IN (SELECT value FROM json_each(?))
                    """, Self.json(spanKeys)) {
                    let body = Self.clean($0.string(1))
                    text[Int64($0.int(0))] = body.isEmpty ? Self.clean($0.string(2)) : body
                }
            }
            if !commentIDs.isEmpty {
                _ = try db.query("SELECT rowid, text FROM comments WHERE rowid IN (SELECT value FROM json_each(?))", Self.json(commentIDs)) {
                    text[-Int64($0.int(0))] = Self.clean($0.string(1))
                }
            }
        }
        return best.map { b in
            guard let b, let t = text[b.row.key], !t.isEmpty else { return nil }
            return t.count > 160 ? String(t.prefix(160)).trimmingCharacters(in: .whitespaces) + "…" : t
        }
    }
}
