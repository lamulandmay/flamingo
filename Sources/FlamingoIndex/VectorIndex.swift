import Accelerate
import Foundation
import SQLite3

/// Every vector of one model in one index file, held in memory as contiguous Int8 rows with
/// a Float32 scale each: 512 dimensions cost about 540 bytes a passage (54 MB for 100k).
/// Loaded once, then topped up incrementally (new rows have larger rowids), and shared by
/// every `IndexStore` open on the same file, so the app's search readers don't each hold a copy.
///
/// A query is one pass of Int8→Float conversion and matrix–vector products over blocks,
/// spread across cores, keeping a running top-k: no per-query SQL over vectors.
final class VectorIndex: @unchecked Sendable {
    let model: String
    let dimensions: Int?
    private(set) var dim = 0

    private var codes: [Int8] = []
    private var scales: [Float] = []
    /// `embedding_spans.rowid` for passages; minus the comment rowid for thoughts.
    private var keys: [Int64] = []
    /// `sections.rowid` for passages, `comments.rowid` for thoughts.
    private var owners: [Int64] = []
    private var offsets: [Int32] = []
    private var lengths: [Int32] = []
    private var alive: [Bool] = []
    private var rowOfKey: [Int64: Int32] = [:]
    private var dead = 0
    private var lastRowid: Int64 = 0
    private var lastIdentity: (section: Int64, offset: Int64)?
    private var commentSignature: [Int] = []
    private var lastAudit = Date.distantPast
    /// Bumped whenever rows are added or removed.
    private(set) var generation = 0
    private var lock = pthread_rwlock_t()
    private let refreshLock = NSLock()
    private let cacheLock = NSLock()
    private var cachedFiles: FileVectors?
    /// File-level vectors built from this index (Similarity.swift), with the generation they saw.
    var fileVectors: FileVectors? {
        get { cacheLock.withLock { cachedFiles } }
        set { cacheLock.withLock { cachedFiles = newValue } }
    }

    init(model: String, dimensions: Int?) {
        self.model = model
        self.dimensions = dimensions
        pthread_rwlock_init(&lock, nil)
    }

    deinit { pthread_rwlock_destroy(&lock) }

    var count: Int { read { keys.count - dead } }

    struct Row: Sendable {
        var key: Int64
        var owner: Int64
        var offset: Int
        var length: Int
        var isComment: Bool { key < 0 }
    }

    func row(_ i: Int32) -> Row {
        read { Row(key: keys[Int(i)], owner: owners[Int(i)], offset: Int(offsets[Int(i)]), length: Int(lengths[Int(i)])) }
    }

    // MARK: Loading

    /// Adds rows written since the last call and drops rows that are gone. Cheap when nothing
    /// changed: two index seeks. A full audit of deletions runs at most every `auditInterval`
    /// (or when `audit` is set); results are verified against SQL anyway, so a deleted row is
    /// never returned, only scored until then.
    func refresh(_ db: Database, audit: Bool = false) throws {
        refreshLock.lock(); defer { refreshLock.unlock() }
        try refreshLocked(db, audit: audit)
    }

    /// `refresh` on the index's own read-only connection to `path`, so loading vectors never
    /// holds a store's reader (and the keystroke searches queued behind it).
    func refresh(path: String, audit: Bool = false) throws {
        refreshLock.lock(); defer { refreshLock.unlock() }
        if connection == nil || connectionPath != path {
            connection = try Database(path: path, readOnly: true)
            try connection?.exec("PRAGMA query_only = 1")
            connectionPath = path
        }
        try refreshLocked(connection!, audit: audit)
    }

    private var connection: Database?
    private var connectionPath: String?

    private func refreshLocked(_ db: Database, audit: Bool) throws {
        let top = Int64(try db.scalarInt("SELECT coalesce(max(rowid), 0) FROM embedding_spans"))
        var mustAudit = audit && Date().timeIntervalSince(lastAudit) > Self.auditInterval
        if top < lastRowid { mustAudit = true }
        if let identity = lastIdentity, top >= lastRowid {
            let same = try db.query("SELECT section, offset FROM embedding_spans WHERE rowid = ?", Int(lastRowid)) { (Int64($0.int(0)), Int64($0.int(1))) }.first
            if same.map({ $0 != identity }) ?? true { mustAudit = true }
        }
        if mustAudit { try auditSpans(db) }
        if top > lastRowid { try loadSpans(db, after: lastRowid) }
        let signature = try db.query("SELECT count(*), coalesce(max(comment), 0), coalesce(sum(comment), 0) FROM comment_vectors WHERE model = ?", model) {
            [$0.int(0), $0.int(1), $0.int(2)]
        }.first ?? []
        if signature != commentSignature { try loadComments(db, signature: signature) }
    }

    static let auditInterval: TimeInterval = 10

    private func loadSpans(_ db: Database, after: Int64) throws {
        var batch = Batch(dimensions: dimensions)
        var last = after, identity = lastIdentity
        _ = try db.query("""
            SELECT rowid, section, offset, coalesce(length, 0), vector FROM embedding_spans
            WHERE rowid > ? AND model = ? AND offset >= 0 ORDER BY rowid
            """, Int(after), model) { r -> Void in
            let rowid = Int64(r.int(0))
            last = rowid
            identity = (Int64(r.int(1)), Int64(r.int(2)))
            batch.append(r.handle, column: 4, key: rowid, owner: Int64(r.int(1)), offset: Int32(clamping: r.int(2)), length: Int32(clamping: r.int(3)))
        }
        // The newest rowid of any model, so the next refresh starts after it.
        let top = Int64(try db.scalarInt("SELECT coalesce(max(rowid), 0) FROM embedding_spans"))
        if top > last {
            last = top
            identity = try db.query("SELECT section, offset FROM embedding_spans WHERE rowid = ?", Int(top)) { (Int64($0.int(0)), Int64($0.int(1))) }.first
        }
        write {
            append(batch)
            lastRowid = last
            lastIdentity = identity
        }
    }

    /// Marks rows whose span no longer exists. One scan of the model index, no vectors read.
    private func auditSpans(_ db: Database) throws {
        var live = Set<Int64>()
        _ = try db.query("SELECT rowid FROM embedding_spans WHERE model = ?", model) { live.insert(Int64($0.int(0))) }
        lastAudit = Date()
        write {
            var removed = 0
            for (i, key) in keys.enumerated() where key > 0 && alive[i] && !live.contains(key) {
                alive[i] = false; removed += 1
            }
            dead += removed
            // Rows above the current maximum may be reused by new inserts; reload from there.
            let top = live.max() ?? 0
            if top < lastRowid {
                for (i, key) in keys.enumerated() where key > top && alive[i] { alive[i] = false; dead += 1 }
                lastRowid = top
            }
            if removed > 0 { generation += 1 }
            compactIfNeeded()
        }
        lastIdentity = nil
    }

    private func loadComments(_ db: Database, signature: [Int]) throws {
        var batch = Batch(dimensions: dimensions)
        _ = try db.query("SELECT comment, vector FROM comment_vectors WHERE model = ?", model) { r -> Void in
            let id = Int64(r.int(0))
            batch.append(r.handle, column: 1, key: -id, owner: id, offset: 0, length: 0)
        }
        write {
            for (i, key) in keys.enumerated() where key < 0 && alive[i] { alive[i] = false; dead += 1 }
            append(batch)
            commentSignature = signature
            compactIfNeeded()
        }
    }

    /// Tells the index a row is gone (found missing while resolving results).
    func remove(keys gone: [Int64]) {
        guard !gone.isEmpty else { return }
        write {
            for key in gone { if let i = rowOfKey[key], alive[Int(i)] { alive[Int(i)] = false; dead += 1 } }
            generation += 1
        }
    }

    private struct Batch {
        let dimensions: Int?
        var dim = 0
        var codes: [Int8] = []
        var scales: [Float] = []
        var keys: [Int64] = [], owners: [Int64] = [], offsets: [Int32] = [], lengths: [Int32] = []
        private var scratch: [Float] = []

        init(dimensions: Int?) { self.dimensions = dimensions }

        /// Copies one stored vector, truncating (and re-quantizing) Matryoshka models.
        mutating func append(_ stmt: OpaquePointer, column: Int32, key: Int64, owner: Int64, offset: Int32, length: Int32) {
            let bytes = Int(sqlite3_column_bytes(stmt, column))
            guard bytes > 4, let blob = sqlite3_column_blob(stmt, column) else { return }
            let stored = bytes - 4
            let n = min(stored, dimensions ?? stored)
            if dim == 0 { dim = n }
            guard n == dim else { return }
            let raw = blob.assumingMemoryBound(to: UInt8.self)
            let scale = Float(bitPattern: UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24)
            let source = UnsafeRawPointer(raw.advanced(by: 4)).assumingMemoryBound(to: Int8.self)
            if n == stored {
                codes.append(contentsOf: UnsafeBufferPointer(start: source, count: n))
                scales.append(scale)
            } else {
                if scratch.count != n { scratch = [Float](repeating: 0, count: n) }
                vDSP_vflt8(source, 1, &scratch, 1, vDSP_Length(n))
                var norm: Float = 0
                vDSP_svesq(scratch, 1, &norm, vDSP_Length(n))
                norm = norm.squareRoot()
                guard norm > 0 else { return }
                var maxAbs: Float = 0
                vDSP_maxmgv(scratch, 1, &maxAbs, vDSP_Length(n))
                let q = maxAbs > 0 ? 127 / maxAbs : 1
                for x in scratch { codes.append(Int8(max(-127, min(127, (x * q).rounded())))) }
                // Re-normalized: value = code × maxAbs / 127 / norm.
                scales.append(maxAbs / 127 / norm)
            }
            keys.append(key); owners.append(owner); offsets.append(offset); lengths.append(length)
        }
    }

    private func append(_ b: Batch) {
        guard !b.keys.isEmpty else { return }
        if dim == 0 { dim = b.dim }
        guard b.dim == dim else { return }
        let base = keys.count
        codes.append(contentsOf: b.codes)
        scales.append(contentsOf: b.scales)
        keys.append(contentsOf: b.keys)
        owners.append(contentsOf: b.owners)
        offsets.append(contentsOf: b.offsets)
        lengths.append(contentsOf: b.lengths)
        alive.append(contentsOf: repeatElement(true, count: b.keys.count))
        for (i, key) in b.keys.enumerated() {
            if let old = rowOfKey[key], alive[Int(old)] { alive[Int(old)] = false; dead += 1 }
            rowOfKey[key] = Int32(base + i)
        }
        generation += 1
    }

    private func compactIfNeeded() {
        guard dead > 1024, dead * 4 > keys.count else { return }
        var c: [Int8] = [], s: [Float] = [], k: [Int64] = [], o: [Int64] = [], off: [Int32] = [], len: [Int32] = []
        let live = keys.count - dead
        c.reserveCapacity(live * dim); s.reserveCapacity(live); k.reserveCapacity(live)
        for i in keys.indices where alive[i] {
            c.append(contentsOf: codes[(i * dim)..<((i + 1) * dim)])
            s.append(scales[i]); k.append(keys[i]); o.append(owners[i]); off.append(offsets[i]); len.append(lengths[i])
        }
        codes = c; scales = s; keys = k; owners = o; offsets = off; lengths = len
        alive = [Bool](repeating: true, count: k.count)
        rowOfKey = Dictionary(uniqueKeysWithValues: k.enumerated().map { ($0.element, Int32($0.offset)) })
        dead = 0
        generation += 1
    }

    // MARK: Search

    /// The `k` rows most similar to `query` (unit length, any dimension ≥ `dim`), best first,
    /// at or above `floor`. `allow` filters by owner (section or comment rowid) before ranking.
    func nearest(_ query: [Float], k: Int, floor: Float = -1, allow: ((Row) -> Bool)? = nil) -> [(row: Int32, score: Float)] {
        read {
            let n = keys.count
            guard n > 0, k > 0, dim > 0, query.count >= dim else { return [] }
            let q = query.count == dim ? query : Embedder.normalized(Array(query.prefix(dim)))
            let block = 1024
            let blocks = (n + block - 1) / block
            let stripes = max(1, min(ProcessInfo.processInfo.activeProcessorCount, blocks / 4))
            var partial = [[(Int32, Float)]](repeating: [], count: stripes)
            partial.withUnsafeMutableBufferPointer { out in
                codes.withUnsafeBufferPointer { codes in
                    scales.withUnsafeBufferPointer { scales in
                        alive.withUnsafeBufferPointer { alive in
                            q.withUnsafeBufferPointer { q in
                                DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
                                    var floats = [Float](repeating: 0, count: block * dim)
                                    var scores = [Float](repeating: 0, count: block)
                                    var top = TopK(k: k, floor: floor)
                                    var b = stripe
                                    while b < blocks {
                                        let start = b * block, rows = min(block, n - start)
                                        vDSP_vflt8(codes.baseAddress! + start * dim, 1, &floats, 1, vDSP_Length(rows * dim))
                                        vDSP_mmul(floats, 1, q.baseAddress!, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dim))
                                        vDSP_vmul(scores, 1, scales.baseAddress! + start, 1, &scores, 1, vDSP_Length(rows))
                                        var best: Float = -2
                                        vDSP_maxv(scores, 1, &best, vDSP_Length(rows))
                                        if best >= top.threshold {
                                            for i in 0..<rows where scores[i] >= top.threshold && alive[start + i] {
                                                if let allow, !allow(Row(key: keys[start + i], owner: owners[start + i], offset: Int(offsets[start + i]), length: Int(lengths[start + i]))) { continue }
                                                top.insert(Int32(start + i), scores[i])
                                            }
                                        }
                                        b += stripes
                                    }
                                    out[stripe] = top.sorted()
                                }
                            }
                        }
                    }
                }
            }
            var merged = TopK(k: k, floor: floor)
            for list in partial { for (row, score) in list { merged.insert(row, score) } }
            return merged.sorted().map { (row: $0.0, score: $0.1) }
        }
    }

    /// The dequantized vector of one row, unit length.
    func vector(_ i: Int32) -> [Float] {
        read {
            var out = [Float](repeating: 0, count: dim)
            codes.withUnsafeBufferPointer { c in vDSP_vflt8(c.baseAddress! + Int(i) * dim, 1, &out, 1, vDSP_Length(dim)) }
            var s = scales[Int(i)]
            vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(dim))
            return out
        }
    }

    /// Calls `body` with every live row's index, key and owner, under the read lock.
    func forEachRow(_ body: (Int32, Int64, Int64) -> Void) {
        read { for i in keys.indices where alive[i] { body(Int32(i), keys[i], owners[i]) } }
    }

    /// Adds `weight` × row `i` into `sum` (length `dim`).
    func accumulate(_ i: Int32, weight: Float, into sum: inout [Float]) {
        read {
            var tmp = [Float](repeating: 0, count: dim)
            codes.withUnsafeBufferPointer { c in vDSP_vflt8(c.baseAddress! + Int(i) * dim, 1, &tmp, 1, vDSP_Length(dim)) }
            var s = scales[Int(i)] * weight
            vDSP_vsma(tmp, 1, &s, sum, 1, &sum, 1, vDSP_Length(dim))
        }
    }

    private func read<T>(_ body: () -> T) -> T {
        pthread_rwlock_rdlock(&lock); defer { pthread_rwlock_unlock(&lock) }
        return body()
    }

    private func write<T>(_ body: () -> T) -> T {
        pthread_rwlock_wrlock(&lock); defer { pthread_rwlock_unlock(&lock) }
        return body()
    }
}

/// A bounded best-k list: appends above the threshold, prunes to k when it doubles.
struct TopK {
    let k: Int
    private(set) var threshold: Float
    private var items: [(Int32, Float)] = []

    init(k: Int, floor: Float) { self.k = k; threshold = floor }

    mutating func insert(_ row: Int32, _ score: Float) {
        guard score >= threshold else { return }
        items.append((row, score))
        if items.count >= k * 2 + 16 { prune() }
    }

    private mutating func prune() {
        items.sort { $0.1 > $1.1 }
        if items.count > k { items.removeLast(items.count - k) }
        if items.count == k, let last = items.last { threshold = max(threshold, last.1) }
    }

    mutating func sorted() -> [(Int32, Float)] {
        prune()
        return items
    }
}

/// Process-wide state for semantic search: the shared vector indexes, recent query vectors,
/// and when the user last searched (background embedding yields to that).
final class SemanticRuntime: @unchecked Sendable {
    static let shared = SemanticRuntime()
    private let lock = NSLock()
    private var indexes: [String: Weak] = [:]
    private var queries: [String: [Float]] = [:]
    private var queryOrder: [String] = []
    private var inflight: [String: DispatchGroup] = [:]
    private var lastInteractive: UInt64 = 0
    static let queryCacheSize = 512

    private final class Weak { weak var value: VectorIndex?; init(_ v: VectorIndex) { value = v } }

    func index(file: String, model: String, dimensions: Int?) -> VectorIndex {
        let key = file + "\u{1}" + model
        return lock.withLock {
            if let existing = indexes[key]?.value { return existing }
            let made = VectorIndex(model: model, dimensions: dimensions)
            indexes = indexes.filter { $0.value.value != nil }
            indexes[key] = Weak(made)
            return made
        }
    }

    // MARK: Query vectors

    func cachedQuery(_ key: String) -> [Float]? { lock.withLock { queries[key] } }

    func storeQuery(_ key: String, _ vector: [Float]) {
        lock.withLock {
            if queries[key] == nil { queryOrder.append(key) }
            queries[key] = vector
            if queryOrder.count > Self.queryCacheSize {
                let drop = queryOrder.prefix(queryOrder.count - Self.queryCacheSize)
                for k in drop { queries[k] = nil }
                queryOrder.removeFirst(drop.count)
            }
        }
    }

    /// Runs `start` once per key at a time; other callers wait on the same request.
    /// `start` must call the provided `finish` exactly once.
    func embedOnce(_ key: String, wait timeout: TimeInterval, start: (@escaping @Sendable () -> Void) -> Void) {
        let (group, first) = lock.withLock { () -> (DispatchGroup, Bool) in
            if let g = inflight[key] { return (g, false) }
            let g = DispatchGroup()
            g.enter()
            inflight[key] = g
            return (g, true)
        }
        if first {
            start { [weak self] in
                self?.lock.withLock { self?.inflight[key] = nil }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    // MARK: Yielding to the user

    func noteInteractive() { lock.withLock { lastInteractive = DispatchTime.now().uptimeNanoseconds } }

    var secondsSinceInteractive: Double {
        let last = lock.withLock { lastInteractive }
        return last == 0 ? .infinity : Double(DispatchTime.now().uptimeNanoseconds - last) / 1e9
    }

    /// Background embedding calls this before each model request: while someone is
    /// searching, the model's queue stays free for their query.
    func waitForQuiet(quiet: Double = 1.5, maxWait: Double = 5, cancelled: () -> Bool) {
        let started = DispatchTime.now().uptimeNanoseconds
        while secondsSinceInteractive < quiet, !cancelled(),
              Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < maxWait {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
