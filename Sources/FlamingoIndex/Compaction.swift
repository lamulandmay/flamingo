import Foundation
import SQLite3

/// Keeps the full-text indexes in one b-tree each.
///
/// FTS5 writes every transaction as a new segment and only merges segments of the same
/// level. A reindex in 200-file batches leaves twenty or more, and every MATCH then walks
/// all of them: on a 35k-file vault a palette query took 1.2 s with 23 segments and 0.28 s
/// with one, and the graph's mention queries ran 27× faster. Compaction merges them with
/// FTS5's incremental `merge` command, 500 pages (2 MB, about 80 ms) per transaction, so a
/// comment write waits at most one step. It runs after the writes stop, never during a
/// reindex, and only when the index is fragmented enough to be worth rewriting.
extension IndexStore {
    /// Turned off by tests that need writes to leave the index exactly as they wrote it.
    public nonisolated(unsafe) static var autoCompact = NSClassFromString("XCTestCase") == nil

    /// Shrunk by tests so a small index takes many steps to merge.
    nonisolated(unsafe) static var compactionStepPages = 500
    /// Quiet time after the last write before compaction starts, so it never competes
    /// with a reindex that is still committing batches.
    static let compactionIdleDelay: TimeInterval = 3

    /// Segment sizes of one FTS5 table, in leaf pages, from its structure record.
    struct FTSLayout: Equatable {
        var segments: Int
        var largest: Int
        var rest: Int
        /// Segments that are inputs to a merge FTS5 started and hasn't finished; what it
        /// has merged so far sits in one more segment beside them.
        var merging = 0

        /// Worth a full rewrite: several segments, and either many of them (each costs a
        /// seek per query term) or enough new data beside the largest to amortise rewriting it.
        var wantsCompaction: Bool { segments >= 2 && (segments >= 8 || rest * 8 >= largest) }
    }

    struct UnreadableStructure: Error {}

    static let ftsTables = ["sections_fts", "comments_fts"]

    func ftsLayout(_ table: String, in db: Database) throws -> FTSLayout {
        guard let record = try db.query("SELECT block FROM \(table)_data WHERE id = 10", row: { $0.data(0) }).first else {
            return FTSLayout(segments: 0, largest: 0, rest: 0)
        }
        guard let layout = FTSLayout(structure: record) else { throw UnreadableStructure() }
        return layout
    }

    /// Whether either full-text index is fragmented enough to compact, or has a merge to finish.
    public func searchIndexNeedsCompaction() throws -> Bool {
        try read { db in
            try Self.ftsTables.contains { let layout = try ftsLayout($0, in: db); return layout.merging > 0 || layout.wantsCompaction }
        }
    }

    /// Merges each fragmented full-text index into a single segment, one bounded
    /// transaction at a time. `force` compacts any index with two or more segments.
    /// Returns false when cancelled (or when `yield` asked it to stop) before finishing;
    /// what was merged so far stays merged. Search results are unchanged; only speed is.
    @discardableResult
    public func compactSearchIndex(force: Bool = false, shouldCancel: () -> Bool = { false }) throws -> Bool {
        guard !readsOnly else { return true }
        for table in Self.ftsTables {
            while true {
                if shouldCancel() || embedding.lock.withLock({ embedding.cancelled }) { return false }
                let worked = try withWriter { db -> Bool in
                    let layout = try ftsLayout(table, in: db)
                    // Continue a merge already under way; never restart it. A negative step
                    // re-plans whenever segments have appeared since the merge began, turning
                    // its half-written output into one more input and starting over. A merge
                    // longer than one quiet spell then never finished, each write burst left
                    // a segment behind, and a home-folder index reached FTS5's 2,000-segment
                    // limit, after which every write failed with SQLITE_FULL.
                    if layout.merging > 0, try mergeStep(table, pages: Self.compactionStepPages, in: db) { return true }
                    // Re-plan only when there is no merge, or a positive step found nothing to
                    // do (a lower level holds as many segments as the merge has inputs, but
                    // fewer than FTS5's usermerge threshold).
                    guard layout.merging > 0 || (force ? layout.segments >= 2 : layout.wantsCompaction) else { return false }
                    return try mergeStep(table, pages: -Self.compactionStepPages, in: db)
                }
                if !worked { break }
            }
        }
        return true
    }

    /// One FTS5 `merge` of about `pages` leaf pages. A negative count first gathers every
    /// segment into one level, so it can merge them all; a positive one continues a merge
    /// in progress, or merges within a level. Returns whether anything was merged.
    private func mergeStep(_ table: String, pages: Int, in db: Database) throws -> Bool {
        let before = sqlite3_total_changes64(db.handle)
        try db.run("INSERT INTO \(table)(\(table), rank) VALUES('merge', ?)", pages)
        // FTS5 reports a no-op merge as fewer than two changes.
        return sqlite3_total_changes64(db.handle) - before >= 2
    }

    private func withWriter<T>(_ body: (Database) throws -> T) throws -> T {
        writeLock.lock(); defer { writeLock.unlock() }
        return try body(writer)
    }

    /// Called after every committed write. Schedules a compaction check once writes have
    /// been quiet for `compactionIdleDelay`; calls while one is pending just push it back.
    func noteWrite() {
        guard !readsOnly, Self.autoCompact else { return }
        let state = maintenance
        let first = state.lock.withLock { () -> Bool in
            state.lastWrite = Date()
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard first else { return }
        state.queue.asyncAfter(deadline: .now() + Self.compactionIdleDelay) { [weak self] in self?.compactWhenIdle() }
    }

    private func compactWhenIdle() {
        let state = maintenance
        let wait = state.lock.withLock { () -> TimeInterval in
            let quiet = Date().timeIntervalSince(state.lastWrite)
            if quiet < Self.compactionIdleDelay { return Self.compactionIdleDelay - quiet }
            state.scheduled = false
            return 0
        }
        if wait > 0 {
            state.queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.compactWhenIdle() }
            return
        }
        // Stop as soon as anyone writes again; the next quiet spell resumes the merge.
        let started = Date()
        let interrupted = { [state] in state.lock.withLock { state.lastWrite > started } }
        if (try? compactSearchIndex(shouldCancel: interrupted)) == true {
            _ = try? releaseFreeSpace(shouldCancel: interrupted)
        }
    }

    /// Free pages that make giving space back worthwhile: 64 MB, and a tenth of the file,
    /// so pages a merge is about to reuse aren't handed back and claimed again.
    static let releaseMinimumPages = 16_384
    /// Pages moved and truncated per transaction (100 MB at 4 KB), so a write waits at most one step.
    static let releaseStepPages = 25_600

    /// Hands the index's free pages back to the disk, a bounded step at a time. Merges and
    /// pruning free pages inside the file, which otherwise stays at its high-water mark. Only
    /// an index created with incremental auto-vacuum can do this; others keep the pages for
    /// reuse. Returns false when cancelled before finishing.
    @discardableResult
    public func releaseFreeSpace(force: Bool = false, shouldCancel: () -> Bool = { false }) throws -> Bool {
        guard !readsOnly else { return true }
        let worth = try withWriter { db -> Bool in
            guard try db.scalarInt("PRAGMA auto_vacuum") == 2 else { return false }
            let free = try db.scalarInt("PRAGMA freelist_count")
            if force { return free > 0 }
            return try free >= Self.releaseMinimumPages && free * 10 >= db.scalarInt("PRAGMA page_count")
        }
        guard worth else { return true }
        while try withWriter({ try $0.scalarInt("PRAGMA freelist_count") }) > 0 {
            if shouldCancel() { return false }
            try withWriter { try $0.exec("PRAGMA incremental_vacuum(\(Self.releaseStepPages))") }
        }
        return true
    }
}

/// Bookkeeping for `noteWrite`/`compactWhenIdle`.
final class MaintenanceState: @unchecked Sendable {
    let lock = NSLock()
    var lastWrite = Date.distantPast
    var scheduled = false
    let queue = DispatchQueue(label: "flamingo.index.maintenance", qos: .utility)
}

extension IndexStore.FTSLayout {
    /// Decodes FTS5's structure record (`_data` row 10): a 4-byte cookie, an optional
    /// 4-byte V2 marker, varints for the level count, segment count and write counter,
    /// then per level its merge-input and segment counts, and per segment its id and
    /// first and last leaf page (V2 adds five varints). Nil when the bytes don't add up.
    init?(structure record: Data) {
        let bytes = [UInt8](record)
        guard bytes.count >= 4 else { return nil }
        var at = bytes.count >= 8 && bytes[4..<8].elementsEqual([0xff, 0, 0, 1]) ? 8 : 4
        let v2 = at == 8
        func varint() -> Int? {
            var value: UInt64 = 0
            for i in 0..<9 {
                guard at < bytes.count else { return nil }
                let b = bytes[at]; at += 1
                if i == 8 { value = value << 8 | UInt64(b); break }
                value = value << 7 | UInt64(b & 0x7f)
                if b & 0x80 == 0 { break }
            }
            return Int(truncatingIfNeeded: value)
        }
        guard let levels = varint(), let total = varint(), varint() != nil,
              (0...Self.maxSegments).contains(levels), (0...Self.maxSegments).contains(total) else { return nil }
        var sizes: [Int] = []
        var merging = 0
        for _ in 0..<levels {
            guard let inputs = varint(), let count = varint(),
                  inputs >= 0, inputs <= count, sizes.count + count <= total else { return nil }
            merging += inputs
            for _ in 0..<count {
                // A merge input it has used up keeps its slot with pages 0...0.
                guard varint() != nil, let first = varint(), let last = varint(), last >= first else { return nil }
                if v2 { for _ in 0..<5 { guard varint() != nil else { return nil } } }
                sizes.append(last == 0 ? 0 : last - first + 1)
            }
        }
        guard sizes.count == total else { return nil }
        let largest = sizes.max() ?? 0
        self.init(segments: total, largest: largest, rest: sizes.reduce(0, +) - largest, merging: merging)
    }

    /// FTS5_MAX_SEGMENT: with this many segments FTS5 can't start a new one, and every
    /// write and every fresh merge fails with SQLITE_FULL ("database or disk is full").
    static let maxSegments = 2000
}
