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

public enum IndexStoreError: Error, CustomStringConvertible, Sendable {
    /// The vault folder was moved or deleted while open. Nothing was changed.
    case vaultMissing(String)
    public var description: String {
        switch self { case .vaultMissing(let p): "vault folder is gone: \(p)" }
    }
}

/// SQLite + FTS5 at `<vault>/.flamingo/index.sqlite`. Plan 05 owns.
///
/// Thread-safe. Writes (`reindex`, `update`, `remove`) are serialized on one connection;
/// reads use a second WAL connection, so search stays fast while a reindex runs.
/// Searching and the other reads are in Search.swift, the graph in GraphBuilder.swift.
public final class IndexStore: @unchecked Sendable {
    public let vault: Vault
    public var databaseURL: URL { vault.stateDir.appendingPathComponent("index.sqlite") }
    public var graphURL: URL { vault.stateDir.appendingPathComponent("graph.json") }

    static let schemaVersion = 2
    /// Changes whenever extraction output may differ, so files indexed by older extractors
    /// are re-extracted even though they haven't changed on disk.
    static var extractVersion: String { "\(Extract.version)" }
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
    private var generation = 0
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
        if force { try writer.exec("UPDATE files SET size = -1") }
        try reindex(progress: progress)
    }

    /// Full reindex. Reports progress 0...1 on the calling thread.
    /// Unchanged files (same mtime and size) are skipped, so re-running is cheap.
    public func reindex(progress: ((Double) -> Void)? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        let started = Date()
        progress?(0)
        let known = try stamps()
        var todo: [Pending] = []
        var seen = Set<String>()
        let scanned = VaultScanner.files(in: vault)
        for ref in scanned {
            seen.insert(ref.relativePath)
            let url = vault.url(for: ref)
            guard let stamp = Stamp(url: url) else { continue }
            let k = known[ref.relativePath]
            if let k, k.stamp == stamp, !(stamp.isDirectory && Self.packageChanged(url, since: k.indexedAt)) { continue }
            todo.append(Pending(ref: ref, stamp: stamp, id: k?.id))
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
        Thumbnails.pruneCache(in: vault, files: scanned)   // thumbnails of edited, renamed, deleted files
        cacheLock.lock()
        report = ReindexReport(scanned: seen.count, extracted: todo.count, removed: gone.count,
                               seconds: Date().timeIntervalSince(started))
        cacheLock.unlock()
        progress?(1)
    }

    /// Incremental: re-extract these files only (when their mtime or size changed; packages
    /// always), drop the ones that are gone, and re-ingest their sidecar comments. A folder
    /// means everything under it; `""` means the whole vault. Paths the scanner would skip
    /// (hidden, `.flamingoignore`d) are ignored. A new path carrying the `FileIdentity` of a
    /// vanished one is a rename: it keeps its rows and its sidecar follows it.
    public func update(_ refs: [FileRef]) throws {
        guard !refs.isEmpty else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        if refs.contains(where: { $0.relativePath.isEmpty }) { return try reindex() }

        let rules = PathRules(vault: vault)
        var present: [(ref: FileRef, stamp: Stamp, direct: Bool)] = []
        var missing: [String] = []
        var folders: [(dir: String, keep: Set<String>)] = []
        var commentTargets = Set<FileRef>()
        for ref in Set(refs) {
            let url = vault.url(for: ref)
            let stamp = Stamp(url: url)
            guard rules.admits(ref.relativePath, isDirectory: stamp?.isDirectory ?? false) else { continue }
            commentTargets.insert(ref)
            guard let stamp else { missing.append(ref.relativePath); continue }
            if stamp.isDirectory && !VaultScanner.isPackage(url) {
                let sub = files(under: ref.relativePath, rules: rules)
                folders.append((ref.relativePath, Set(sub)))
                for p in sub {
                    let r = FileRef(relativePath: p)
                    commentTargets.insert(r)
                    if let st = Stamp(url: vault.url(for: r)) { present.append((r, st, false)) }
                }
            } else {
                present.append((ref, stamp, true))
            }
        }

        // Renames: a new path whose identity belongs to a row whose file vanished.
        let known = try stamps(for: present.map(\.ref.relativePath))
        var reconcile = missing.contains(where: hasSidecars)
        try writer.transaction {
            for p in present {
                if let k = known[p.ref.relativePath] {
                    if k.id == nil { try recordIdentity(of: p.ref) }
                } else if let id = identity(of: p.ref) {
                    try adoptRow(carrying: id, to: p.ref)
                    if !hasSidecars(p.ref.relativePath) { reconcile = true }   // its note may be orphaned elsewhere
                }
            }
        }
        if reconcile, let moves = try? sidecars.reconcile() {
            for m in moves { commentTargets.insert(m.from); commentTargets.insert(m.to) }
        }

        let after = try stamps(for: present.map(\.ref.relativePath))
        let todo = present.compactMap { p -> Pending? in
            let k = after[p.ref.relativePath]
            // A package's own stat doesn't change when a file inside it is rewritten.
            let unchanged = k?.stamp == p.stamp && !(p.direct && p.stamp.isDirectory)
            return unchanged ? nil : Pending(ref: p.ref, stamp: p.stamp, id: k?.id)
        }
        try ingest(todo) { _ in }
        try writer.transaction {
            for p in missing { try deleteRows(path: p); try deleteRows(under: p) }
            for p in present where p.direct { try deleteRows(under: p.ref.relativePath) }   // was a folder
            for (dir, keep) in folders {
                try deleteRows(path: dir)   // was a file
                for p in try paths(under: dir) where !keep.contains(p) { try deleteRows(path: p) }
            }
            for ref in commentTargets { try replaceComments(for: ref) }
        }
        invalidateCaches()
    }

    /// Drops these files (and anything under them) from the index. Their comments keep
    /// mirroring the sidecars, which may outlive the file.
    public func remove(_ refs: [FileRef]) throws {
        guard !refs.isEmpty else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.transaction {
            for ref in refs where !ref.relativePath.isEmpty {
                try deleteRows(path: ref.relativePath)
                try deleteRows(under: ref.relativePath)
                try replaceComments(for: ref)
            }
        }
        invalidateCaches()
    }

    /// Replaces every indexed comment with these. `reindex` calls it with `SidecarStore.all()`.
    func replaceAllComments(_ all: [FileRef: [Comment]]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writer.transaction {
            try writer.exec("DELETE FROM comments")
            for (ref, comments) in all.sorted(by: { $0.key.relativePath < $1.key.relativePath }) {
                try insertComments(comments, for: ref)
            }
        }
    }

    // MARK: - Internals

    struct Stamp: Equatable {
        var mtime: Double
        var size: Int
        var isDirectory = false
        init(mtime: Double, size: Int) { self.mtime = mtime; self.size = size }
        /// `nil` unless a regular file or a folder: never a symlink (the scanner doesn't
        /// follow them), a pipe or a device (which would block extraction forever).
        init?(url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return nil }
            mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            size = Int(st.st_size)
            isDirectory = type == S_IFDIR
        }
        static func == (a: Stamp, b: Stamp) -> Bool { a.mtime == b.mtime && a.size == b.size }
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

    struct Known {
        var stamp: Stamp
        var id: String?
        var indexedAt: Double
    }

    /// Reads on the reader connection. `snapshot` keeps several queries on one commit.
    func read<T>(snapshot: Bool = false, _ body: (Database) throws -> T) throws -> T {
        readLock.lock(); defer { readLock.unlock() }
        return snapshot ? try reader.snapshot { try body(reader) } : try body(reader)
    }

    func indexedPaths() throws -> [String] {
        cacheLock.lock()
        if let p = pathCache { cacheLock.unlock(); return p }
        let gen = generation
        cacheLock.unlock()
        let paths = try read { db in try db.query("SELECT path FROM files ORDER BY path") { $0.string(0) } }
        cacheLock.lock()
        if generation == gen { pathCache = paths }   // a write landed meanwhile: don't cache what we read
        cacheLock.unlock()
        return paths
    }

    private func invalidateCaches() {
        cacheLock.lock(); generation += 1; pathCache = nil; cacheLock.unlock()
    }

    func requireVault() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.root.path, isDirectory: &isDir), isDir.boolValue else {
            throw IndexStoreError.vaultMissing(vault.root.path)
        }
    }

    private struct SchemaTooNew: Error {}

    private static func openWriter(_ path: String) throws -> Database {
        do {
            return try configureRetrying(path)
        } catch let e as IndexError where e.isCorrupt {
            recreate(path)
        } catch is SchemaTooNew {
            recreate(path)
        }
        return try configureRetrying(path)
    }

    /// Switching a fresh file to WAL can report BUSY without waiting on the busy handler
    /// when another connection is doing the same, so retry those briefly.
    private static func configureRetrying(_ path: String) throws -> Database {
        var attempt = 0
        while true {
            do {
                return try configure(Database(path: path))
            } catch let e as IndexError where e.isBusy && attempt < 100 {
                attempt += 1
                usleep(useconds_t(10_000 + Int.random(in: 0..<20_000)))
            }
        }
    }

    /// The index is a cache: if it is unreadable or from a newer Flamingo, start over.
    /// Only then; busy or I/O errors must never delete a file someone else has open.
    private static func recreate(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private static func configure(_ db: Database) throws -> Database {
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY;")
        // BEGIN IMMEDIATE serializes two processes opening a fresh index at once.
        try db.transaction {
            let v = try db.userVersion()
            if v > schemaVersion { throw SchemaTooNew() }
            if v < 1 { try db.exec(Schema.v1) }
            if v < 2 { try db.exec(Schema.v2) }
            let stored = try db.query("SELECT value FROM meta WHERE key = 'extract_version'") { $0.string(0) }.first
            if stored != extractVersion {
                try db.exec("UPDATE files SET size = -1")   // stale; keep serving old text until reindexed
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('extract_version', ?)", extractVersion)
            }
        }
        return db
    }

    private func stamps() throws -> [String: Known] {
        let rows = try writer.query("SELECT path, mtime, size, id, indexed_at FROM files") {
            ($0.string(0), Known(stamp: Stamp(mtime: $0.double(1), size: $0.int(2)), id: $0.optionalString(3), indexedAt: $0.double(4)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    private func stamps(for paths: [String]) throws -> [String: Known] {
        var out: [String: Known] = [:]
        for p in paths {
            let row = try writer.query("SELECT mtime, size, id, indexed_at FROM files WHERE path = ?", p) {
                Known(stamp: Stamp(mtime: $0.double(0), size: $0.int(1)), id: $0.optionalString(2), indexedAt: $0.double(3))
            }
            if let r = row.first { out[p] = r }
        }
        return out
    }

    /// Whether anything inside a package was modified after `time`. Huge packages (apps,
    /// libraries) aren't walked; their own stamp has to do.
    static func packageChanged(_ url: URL, since time: Double) -> Bool {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n > 2000 { return false }
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               d.timeIntervalSince1970 > time { return true }
        }
        return false
    }

    /// Ids are read, never assigned: a file has one once someone comments on it.
    private func identity(of ref: FileRef) -> UUID? {
        (try? FileIdentity.existingID(for: vault.url(for: ref))) ?? nil
    }

    private func recordIdentity(of ref: FileRef) throws {
        guard let id = identity(of: ref) else { return }
        try writer.run("UPDATE files SET id = ? WHERE path = ?", id.uuidString, ref.relativePath)
    }

    /// Moves the row of a vanished file carrying `id` to `ref`, keeping its extracted text.
    private func adoptRow(carrying id: UUID, to ref: FileRef) throws {
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

    /// What the scanner lists under a folder, judged by the vault's rules (not the folder's).
    private func files(under dir: String, rules: PathRules) -> [String] {
        let url = vault.url(for: FileRef(relativePath: dir))
        var out = VaultScanner.files(in: Vault(root: url), ignore: .empty).map { dir + "/" + $0.relativePath }
        // Scanning `dir` as a root skips its root-only names (`Library`); below the vault root they count.
        for name in VaultScanner.rootOnlyIgnoredNames {
            let sub = url.appendingPathComponent(name)
            if Stamp(url: sub)?.isDirectory == true, !VaultScanner.isPackage(sub) {
                out += files(under: dir + "/" + name, rules: rules)
            }
        }
        return out.filter { rules.admits($0, isDirectory: false) }
    }

    /// Indexed paths strictly inside `dir`: `dir/` ≤ path < `dir0` ('0' sorts right after '/').
    private func paths(under dir: String) throws -> [String] {
        try writer.query("SELECT path FROM files WHERE path >= ?1 AND path < ?2", dir + "/", dir + "0") { $0.string(0) }
    }

    private func ingest(_ todo: [Pending], progress: (Double) -> Void) throws {
        guard !todo.isEmpty else { progress(1); return }
        // Grouped by type: Spotlight-backed formats pay ~0.75s whenever the importer changes.
        let todo = todo.sorted { ($0.ref.ext, $0.ref.relativePath) < ($1.ref.ext, $1.ref.relativePath) }
        let queue = ExtractionQueue(todo, vault: vault, width: Self.extractionWidth, buffer: Self.batchSize * 2)
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
        try writer.run("DELETE FROM sections WHERE path >= ?1 AND path < ?2", dir + "/", dir + "0")
        try writer.run("DELETE FROM files WHERE path >= ?1 AND path < ?2", dir + "/", dir + "0")
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

    static func fileTitle(_ title: String?, _ ref: FileRef) -> String {
        guard let title, title != ref.name, title != (ref.name as NSString).deletingPathExtension else { return ref.name }
        return title + " · " + ref.name
    }

    static func capped(_ s: String, _ limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        return String(s.utf16.prefix(limit)) ?? String(s.prefix(limit / 2))
    }
}

/// Extracts files on a few background threads and hands back finished batches in
/// completion order, so one slow file never holds up writing the rest. Workers pause
/// when `buffer` results are waiting, so memory stays bounded if writing falls behind.
private final class ExtractionQueue: @unchecked Sendable {
    private let todo: [IndexStore.Pending]
    private let vault: Vault
    private let buffer: Int
    private let cond = NSCondition()
    private var nextIndex = 0
    private var done: [IndexStore.Extraction] = []
    private var delivered = 0
    private var cancelled = false

    init(_ todo: [IndexStore.Pending], vault: Vault, width: Int, buffer: Int) {
        self.todo = todo; self.vault = vault; self.buffer = buffer
        for _ in 0..<min(width, todo.count) {
            Thread.detachNewThread { [self] in work() }
        }
    }

    func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }

    /// Blocks until `batchSize` results are ready (or everything left is), `nil` when finished.
    func next(batchSize: Int) -> [IndexStore.Extraction]? {
        cond.lock(); defer { cond.unlock() }
        let remaining = todo.count - delivered
        guard remaining > 0 else { return nil }
        let want = min(batchSize, remaining)
        while done.count < want { cond.wait() }
        let batch = done
        done.removeAll(keepingCapacity: true)
        delivered += batch.count
        cond.broadcast()
        return batch
    }

    private func work() {
        while true {
            cond.lock()
            let i = nextIndex
            nextIndex += 1
            let stop = cancelled || i >= todo.count
            cond.unlock()
            if stop { return }
            let p = todo[i]
            let result: IndexStore.Extraction = autoreleasepool {
                let url = vault.url(for: p.ref)
                let id = ((try? FileIdentity.existingID(for: url)) ?? nil)?.uuidString ?? p.id
                return IndexStore.Extraction(ref: p.ref, stamp: p.stamp, id: id, extracted: try? Extract.extract(url))
            }
            cond.lock()
            while done.count >= buffer && !cancelled { cond.wait() }
            done.append(result)
            cond.broadcast()
            cond.unlock()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
