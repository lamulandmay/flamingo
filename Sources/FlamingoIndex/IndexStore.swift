import Foundation
import Darwin
import FlamingoCore
import FlamingoExtract

public struct SearchHit: Identifiable, Sendable, Equatable {
    public var id: String { file.relativePath + (commentID.map { "#comment:" + $0.uuidString } ?? (anchor?.rendered ?? "")) }
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

/// A move confirmed by the source file's persistent identity, for other workspace stores.
public struct IndexedRename: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var from: FileRef
    public var to: FileRef
    /// Present on every new journal entry. Older records with no proof stay guarded.
    public var fileIdentity: UUID?
}

public struct IndexStats: Sendable, Equatable {
    public var files: Int
    public var sections: Int
    public var comments: Int
}

public enum IndexStoreError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public var errorDescription: String? { description }
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

    static let schemaVersion = 9
    /// Changes whenever extraction output may differ, so files indexed by older extractors
    /// are re-extracted even though they haven't changed on disk.
    static var extractVersion: String { "\(Extract.version)" }
    static let batchSize = 200
    static let extractionWidth = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    static let commentBoost = 1.5
    static let maxFileText = 2_000_000
    static let maxSectionText = 500_000
    /// Logs and machine-written data get a smaller budget: the start says what the file
    /// is, and the rest only grows the index (and a log is re-read on every append).
    static let maxDataFileText = 256_000
    static let dataExtensions: Set<String> = ["json", "jsonl", "ndjson", "geojson", "log", "csv", "tsv", "xml", "map", "har"]

    static func textBudget(ext: String) -> Int {
        dataExtensions.contains(ext.lowercased()) ? maxDataFileText : maxFileText
    }

    let sidecars: SidecarStore
    /// `<root>/` and `<root>/.flamingo/notes/`, for per-file syscalls without building URLs.
    let rootPrefix: String
    let notesPrefix: String
    let writer: Database
    private let reader: Database
    let writeLock = NSRecursiveLock()
    let embedding = EmbeddingState()
    let maintenance = MaintenanceState()
    let mentions = MentionMemo()
    private let readLock = NSLock()
    private let cacheLock = NSLock()
    private var pathCache: [String]?
    private var directoryCache: [String]?
    /// `indexedPaths(inFolder:)` for the last folder asked about, valid for one generation.
    private var folderPathCache: (folder: String, generation: Int, paths: [String])?
    let readsOnly: Bool
    private var readerDataVersion: Int?
    private var generation = 0
    private var report: ReindexReport?

    public convenience init(vault: Vault) throws { try self.init(vault: vault, readOnly: false) }

    /// Read-only diagnostics never migrate the database, refresh extraction versions, or
    /// create workspace state. A missing/incompatible index fails instead of being rebuilt.
    public init(vault: Vault, readOnly: Bool) throws {
        self.readsOnly = readOnly
        self.vault = vault
        sidecars = SidecarStore(vault: vault)
        let root = vault.root.path
        rootPrefix = root.hasSuffix("/") ? root : root + "/"
        notesPrefix = vault.notesDir.path + "/"
        let path = vault.stateDir.appendingPathComponent("index.sqlite").path
        if readOnly {
            writer = try Database(path: path, readOnly: true)
            reader = try Database(path: path, readOnly: true)
            let version = try reader.userVersion()
            guard version == Self.schemaVersion else { throw IndexError(code: 1, message: "index schema \(version) requires a normal app open before read-only queries") }
        } else {
            try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
            writer = try Self.openWriter(path)
            reader = try Database(path: path)
        }
        try reader.exec("PRAGMA query_only = 1")
        // Searches read tens of thousands of FTS and docsize pages; memory-mapping the file
        // instead of copying each page through SQLite's cache halves a palette query on a
        // 35k-file index (127 → 75 ms). Only on an internal, non-removable disk: a mapped
        // file that disappears (an unplugged drive) faults instead of returning an error.
        if Self.allowsMemoryMapping(vault.stateDir) { try? reader.exec("PRAGMA mmap_size = \(Self.readerMapSize)") }
        // Finish a merge an earlier run left half done, even if this run writes nothing.
        noteWrite()
        if !readOnly { reloadCommentsIfNeeded() }
    }

    /// After a schema step that added comment columns (`comments_reload`), or a change to
    /// `ThoughtRules` (`ThoughtRules.version`), read every note again once. Rows whose text did
    /// not change are updated in place, so their vectors stay and nothing is embedded again.
    private func reloadCommentsIfNeeded() {
        let flagged = metaValue("comments_reload") == "1"
        let rules = String(ThoughtRules.version)
        guard flagged || metaValue("thought_rules") != rules else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        do {
            try replaceAllComments(sidecars.all())
            try writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('comments_reload', '0')")
            try writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('thought_rules', ?)", rules)
            invalidateCaches()
        } catch {
            // Leave the flag set: the next open tries again, and reindex reads the notes anyway.
        }
    }

    static let readerMapSize = 1 << 30

    static func allowsMemoryMapping(_ dir: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        guard let v = try? dir.resourceValues(forKeys: keys) else { return false }
        return v.volumeIsInternal == true && v.volumeIsLocal == true && v.volumeIsRemovable != true
    }

    /// `nil` until a `reindex` finishes.
    public var lastReindex: ReindexReport? { cacheLock.lock(); defer { cacheLock.unlock() }; return report }

    // MARK: - Writing

    public func reindex(force: Bool, progress: ((Double) -> Void)? = nil) throws {
        try reindex(force: force, progress: progress, shouldCancel: { false })
    }

    public func reindex(progress: ((Double) -> Void)? = nil) throws {
        try reindex(force: false, progress: progress, shouldCancel: { false })
    }

    /// Streams bounded batches. Cancellation never interprets an incomplete scan as deletion.
    /// A caller may cancel between files/batches; a native extraction already in flight finishes.
    public func reindex(force: Bool, progress: ((Double) -> Void)? = nil, shouldCancel: () -> Bool) throws {
        try requireVault()
        let started = Date()
        let previousCount = try stats().files
        var seen = Set<String>(), batch: [FileRef] = [], extracted = 0
        var failure: Error?
        progress?(0)
        VaultScanner.scan(in: vault, ignore: VaultScanner.ignoreRules(in: vault)) { ref in
            guard !shouldCancel(), failure == nil else { return false }
            seen.insert(ref.relativePath); batch.append(ref)
            if batch.count >= Self.batchSize {
                do { extracted += try updateImpl(batch, force: force, shouldCancel: shouldCancel); batch.removeAll(keepingCapacity: true) }
                catch { failure = error; return false }
                progress?(min(0.9, Double(seen.count) / Double(max(previousCount, seen.count) + Self.batchSize)))
            }
            return true
        }
        if let failure { throw failure }
        guard !shouldCancel() else { return }
        if !batch.isEmpty { extracted += try updateImpl(batch, force: force, shouldCancel: shouldCancel) }
        guard !shouldCancel() else { return }
        let removed: Int
        do {
            writeLock.lock(); defer { writeLock.unlock() }
            let gone = try writer.query("SELECT path FROM files") { $0.string(0) }.filter { !seen.contains($0) }
            removed = try pruneUnseen(gone.map(FileRef.init(relativePath:)))
            _ = try sidecars.reconcile()
            // Read first: a failed note read preserves the last known comment index.
            try replaceAllComments(sidecars.all())
            invalidateCaches()
        }
        Thumbnails.pruneCache(in: vault, files: seen.map(FileRef.init(relativePath:)))
        // A full pass leaves many FTS segments; merge them now, a step at a time, so the
        // searches and the graph build that follow don't walk all of them.
        _ = try? compactSearchIndex(shouldCancel: shouldCancel)
        cacheLock.lock()
        report = ReindexReport(scanned: seen.count, extracted: extracted, removed: removed,
                               seconds: Date().timeIntervalSince(started))
        cacheLock.unlock()
        if Self.autoEmbed { scheduleEmbedding() }
        progress?(1)
    }

    /// Incremental: re-extract these files only (when their mtime or size changed; packages
    /// always), drop the ones that are gone, and re-ingest their sidecar comments. A folder
    /// means everything under it; `""` means the whole vault. Paths the scanner would skip
    /// (generated folders, Office lock files, or ignore-rule matches) are ignored. A new path carrying the `FileIdentity` of a
    /// vanished one is a rename: it keeps its rows and its sidecar follows it.
    public func update(_ refs: [FileRef]) throws { _ = try updateImpl(refs, force: false) }

    /// Re-attempt selected files even when their filesystem stamp is unchanged.
    public func update(_ refs: [FileRef], force: Bool) throws { _ = try updateImpl(refs, force: force) }

    /// Returns how many files were read (extracted) rather than found unchanged. `onRead`
    /// hears each committed batch of reads with the last file in it, for progress.
    /// `deferStale` leaves rows an extractor update made stale (`staleFiles`) for a later
    /// pass when the file itself is unchanged, so a walk only compares stamps and finishes.
    @discardableResult
    public func update(_ refs: [FileRef], force: Bool, shouldCancel: () -> Bool, deferStale: Bool = false,
                       onRead: ((_ count: Int, _ last: FileRef) -> Void)? = nil) throws -> Int {
        try updateImpl(refs, force: force, shouldCancel: shouldCancel, deferStale: deferStale, onRead: onRead)
    }

    private func updateImpl(_ refs: [FileRef], force: Bool, shouldCancel: () -> Bool = { false },
                            deferStale: Bool = false, onRead: ((Int, FileRef) -> Void)? = nil) throws -> Int {
        guard !refs.isEmpty else { return 0 }
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        if refs.contains(where: { $0.relativePath.isEmpty }) { try reindex(force: force, shouldCancel: shouldCancel); return lastReindex?.extracted ?? 0 }

        let rules = PathRules(vault: vault)
        var present: [(ref: FileRef, stamp: Stamp, direct: Bool)] = []
        var missing: [String] = []
        var excluded: [String] = []
        var folders: [(dir: String, keep: Set<String>)] = []
        var commentTargets = Set<FileRef>()
        for ref in Set(refs) {
            let stamp = Stamp(path: filePath(ref))
            guard rules.admits(ref.relativePath, isDirectory: stamp?.isDirectory ?? false) else {
                excluded.append(ref.relativePath); continue
            }
            commentTargets.insert(ref)
            guard let stamp else { missing.append(ref.relativePath); continue }
            if stamp.isDirectory && !VaultScanner.isPackage(vault.url(for: ref)) {
                let sub = files(under: ref.relativePath, rules: rules)
                folders.append((ref.relativePath, Set(sub)))
                for p in sub {
                    let r = FileRef(relativePath: p)
                    commentTargets.insert(r)
                    if let st = Stamp(path: filePath(r)) { present.append((r, st.isDirectory ? Stamp(package: filePath(r), own: st) : st, false)) }
                }
            } else {
                present.append((ref, stamp.isDirectory ? Stamp(package: filePath(ref), own: stamp) : stamp, true))
            }
        }

        // Renames: a new path whose identity belongs to a row whose file vanished.
        let known = try stamps(for: present.map(\.ref.relativePath))
        var reconcile = missing.contains(where: hasSidecars)
        var adopted = false
        try writer.transaction {
            for p in present {
                if let k = known[p.ref.relativePath] {
                    if let current = identity(of: p.ref), k.id != current.uuidString {
                        try writer.run("UPDATE files SET id = ? WHERE path = ?", current.uuidString, p.ref.relativePath)
                    }
                } else if let id = identity(of: p.ref) {
                    try adoptRow(carrying: id, to: p.ref)
                    adopted = true
                    if !hasSidecars(p.ref.relativePath) { reconcile = true }   // its note may be orphaned elsewhere
                }
            }
        }
        if reconcile {
            for m in try sidecars.reconcile() { commentTargets.insert(m.from); commentTargets.insert(m.to) }
        }

        // A walk passes hundreds of thousands of unchanged files: look each up once.
        let after = adopted ? try stamps(for: present.map(\.ref.relativePath)) : known
        let todo = present.compactMap { p -> Pending? in
            let k = after[p.ref.relativePath]
            let eligible = VaultScanner.limits.allowsExtraction(atPath: filePath(p.ref))
            let retryDue = k?.retryAfter.map { $0 <= Date().timeIntervalSince1970 } ?? false
            let becameAvailable = k?.state == "metadataOnly" && eligible
            // A package's stamp covers what's inside it (`Stamp(package:own:)`), so an unchanged
            // Keynote or Pixelmator file is no longer re-read on every pass.
            let stale = deferStale && k?.stamp.size == -1 && k?.stamp.mtime == p.stamp.mtime
            let unchanged = (k?.stamp == p.stamp || stale) && !force && !retryDue && !becameAvailable
            guard !unchanged else { return nil }
            let resume = k?.stamp == p.stamp && k?.state == "partial" && p.ref.ext == "pdf" ? (try? sections(of: p.ref)) ?? [] : []
            return Pending(ref: p.ref, stamp: p.stamp, id: k?.id, resume: resume,
                           processedUnits: resume.isEmpty ? 0 : (k?.processedUnits ?? 0))
        }
        let written = try ingest(todo, shouldCancel: shouldCancel, onRead: onRead)
        guard !shouldCancel() else { invalidateCaches(); return written }
        try writer.transaction {
            for p in excluded {
                try deleteRows(path: p); try deleteRows(under: p)
                try writer.run("DELETE FROM comments WHERE path = ?1 OR (path >= ?2 AND path < ?3)", p, p + "/", p + "0")
            }
            for p in missing {
                for candidate in [p] + (try paths(under: p)) { _ = try pruneUnseenPath(candidate, rules: rules) }
            }
            // Was a folder. A path that already had a file row never was, so skip the range delete.
            for p in present where p.direct && known[p.ref.relativePath] == nil { try deleteRows(under: p.ref.relativePath) }
            for (dir, keep) in folders {
                try deleteRows(path: dir)   // was a file
                for p in try paths(under: dir) where !keep.contains(p) { _ = try pruneUnseenPath(p, rules: rules) }
            }
            for ref in commentTargets { try replaceComments(for: ref) }
        }
        invalidateCaches()
        if Self.autoEmbed, !todo.isEmpty { scheduleEmbedding() }
        return written
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

    /// Removes scan omissions only when deletion or exclusion can be confirmed now. A
    /// permission failure, interrupted enumeration, or concurrent new file preserves the
    /// last good content. Call only after a complete, uncancelled scan.
    @discardableResult
    public func pruneUnseen(_ refs: [FileRef]) throws -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        let rules = PathRules(vault: vault)
        let paths = Set(refs.map(\.relativePath)).subtracting([""])
        var removed = 0
        // Rules that newly exclude a big tree (an environment, an app's data) remove most of
        // the index at once. FTS5 deletes a row by re-tokenizing its old text into delete
        // markers that merges must later rewrite; rebuilding the full-text index from the
        // rows that stay costs a fraction of that when they are the minority.
        let bulk = try paths.count >= Self.bulkPruneMinimum && paths.count * 2 >= writer.scalarInt("SELECT count(*) FROM files")
        try writer.transaction {
            let trigger = bulk ? try writer.query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'sections_ad'") { $0.string(0) }.first : nil
            if trigger != nil { try writer.exec("DROP TRIGGER sections_ad") }
            for path in paths {
                if try pruneUnseenPath(path, rules: rules) { removed += 1 }
            }
            if let trigger {
                try writer.exec(trigger)
                try writer.run("INSERT INTO sections_fts(sections_fts) VALUES('rebuild')")
            }
        }
        invalidateCaches()
        return removed
    }

    /// Shrunk by tests.
    nonisolated(unsafe) static var bulkPruneMinimum = 5_000

    private func pruneUnseenPath(_ path: String, rules: PathRules) throws -> Bool {
        let url = vault.url(for: FileRef(relativePath: path))
        var st = stat()
        let result = lstat(url.path, &st)
        let code = errno
        let directory = result == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        let excluded = !rules.admits(path, isDirectory: directory)
        let missing = result != 0 && (code == ENOENT || code == ENOTDIR)
        let noLongerFile = result == 0 && (st.st_mode & S_IFMT) != S_IFREG && !(directory && VaultScanner.isPackage(url))
        if excluded || missing || noLongerFile {
            if excluded { try writer.run("DELETE FROM comments WHERE path = ?", path) }
            try deleteRows(path: path)
            return true
        }
        if result != 0 {
            let reason = "Source unavailable during scan: " + String(cString: strerror(code))
            try recordCoverage(ExtractionCoverage(.failed, reason: reason), path: path, priorAttempts: 0)
        }
        return false
    }

    /// Durable identity-confirmed moves awaiting reconciliation by the workspace. Reads
    /// do not consume records: acknowledge only after all dependent stores commit.
    public func pendingRenames() throws -> [IndexedRename] {
        try restoreLegacyRenameIdentities()
        return try read { db in
            try db.query("SELECT id, from_path, to_path, file_identity FROM pending_renames ORDER BY id") {
                IndexedRename(id: Int64($0.int(0)), from: FileRef(relativePath: $0.string(1)), to: FileRef(relativePath: $0.string(2)),
                              fileIdentity: $0.optionalString(3).flatMap(UUID.init(uuidString:)))
            }
        }
    }

    /// v6 recorded paths before identity became part of the outbox. Recover only when
    /// the indexed destination and its actual xattr still agree; otherwise retain the
    /// unresolved record for a visible retry instead of guessing from the pathname.
    private func restoreLegacyRenameIdentities() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let candidates = try writer.query("""
            SELECT r.id, r.from_path, r.to_path, f.id FROM pending_renames r
            JOIN files f ON f.path = r.to_path
            WHERE r.file_identity IS NULL AND f.id IS NOT NULL
            """) { ($0.int(0), $0.string(1), $0.string(2), $0.string(3)) }
        for (event, from, to, rawID) in candidates {
            guard let id = UUID(uuidString: rawID),
                  (try? FileIdentity.existingID(for: vault.url(for: FileRef(relativePath: to)))) == id,
                  (try? FileIdentity.existingID(for: vault.url(for: FileRef(relativePath: from)))) != id else { continue }
            try writer.run("UPDATE pending_renames SET file_identity = ? WHERE id = ? AND file_identity IS NULL", id.uuidString, event)
        }
    }

    public func acknowledgeRename(_ move: IndexedRename) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        // A later rename may have advanced this destination while the shell worked.
        // Never acknowledge that newer record using an older snapshot.
        try writer.run("DELETE FROM pending_renames WHERE id = ? AND from_path = ? AND to_path = ?",
                       Int(move.id), move.from.relativePath, move.to.relativePath)
    }

    /// Journals a deliberate filesystem move even if its source was never indexed.
    /// Call after the move and before reconciling dependent workspace stores. A retry
    /// of the same identity/path pair is harmless. The filesystem move and journal are
    /// separate commits; this does not claim crash atomicity across those operations.
    public func recordRename(from old: FileRef, to new: FileRef, identity: UUID) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        guard try FileIdentity.existingID(for: vault.url(for: new)) == identity else {
            throw SidecarError.identityMismatch(path: new.relativePath)
        }
        try writer.transaction { try journalRename(from: old, to: new, identity: identity) }
    }

    private func journalRename(from old: FileRef, to new: FileRef, identity: UUID) throws {
        let id = identity.uuidString
        // A reused intermediate pathname can belong to a different file. Only advance
        // records carrying the same identity through a later rename in the chain.
        try writer.run("UPDATE pending_renames SET to_path = ? WHERE to_path = ? AND file_identity = ?", new.relativePath, old.relativePath, id)
        try writer.run("""
            INSERT INTO pending_renames(from_path, to_path, file_identity)
            SELECT ?1, ?2, ?3 WHERE NOT EXISTS (
                SELECT 1 FROM pending_renames WHERE from_path = ?1 AND to_path = ?2 AND file_identity = ?3
            )
            """, old.relativePath, new.relativePath, id)
        try writer.run("DELETE FROM pending_renames WHERE from_path = to_path AND file_identity = ?", id)
    }

    /// Re-reads every note, for when FSEvents lost events under `.flamingo/notes`. A few
    /// hundred small files, where a walk would be the whole vault.
    public func reloadComments() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireVault()
        _ = try sidecars.reconcile()
        try replaceAllComments(sidecars.all())
        invalidateCaches()
    }

    /// Makes the indexed comments these. `reindex` calls it with `SidecarStore.all()`. A thought
    /// whose text is unchanged keeps its row (and so its vector); only its metadata is updated.
    func replaceAllComments(_ all: [FileRef: [Comment]]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let rules = PathRules(vault: vault)
        try writer.transaction {
            let existing = Set(try writer.query("SELECT DISTINCT path FROM comments") { $0.string(0) })
            var kept = Set<String>()
            for (ref, comments) in all.sorted(by: { $0.key.relativePath < $1.key.relativePath })
                where rules.admits(ref.relativePath, isDirectory: false) {
                kept.insert(ref.relativePath)
                try syncComments(comments, path: ref.relativePath)
            }
            for path in existing.subtracting(kept) { try writer.run("DELETE FROM comments WHERE path = ?", path) }
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
        init?(url: URL) { self.init(path: url.path) }

        init?(path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return nil }
            mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            size = Int(st.st_size)
            isDirectory = type == S_IFDIR
        }
        static func == (a: Stamp, b: Stamp) -> Bool { a.mtime == b.mtime && a.size == b.size }

        /// A package's stamp reaches inside it: the newest modification and the total size of
        /// what it holds, since saving a Keynote or Pixelmator file rewrites its insides and
        /// leaves the package folder's own stat alone. Huge packages (apps, libraries) keep
        /// `own`, so a walk never descends into thousands of files to stamp one row.
        init(package path: String, own: Stamp) {
            self = own
            guard let names = FileManager.default.enumerator(atPath: path) else { return }
            var newest = own.mtime, total = 0, count = 0
            var st = stat()
            let prefix = path.hasSuffix("/") ? path : path + "/"
            while let name = names.nextObject() as? String {
                count += 1
                if count > Self.packageEntryLimit { return }
                guard lstat(prefix + name, &st) == 0 else { continue }
                newest = max(newest, Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
                if st.st_mode & S_IFMT == S_IFREG { total += Int(st.st_size) }
            }
            mtime = newest
            size = total
        }

        static let packageEntryLimit = 2000
    }

    struct Pending {
        var ref: FileRef
        var stamp: Stamp
        var id: String?
        var resume: [Section] = []
        var processedUnits: Int = 0
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
        var state: String = "complete"
        var retryAfter: Double? = nil
        var processedUnits: Int? = nil
    }

    /// Reads on the reader connection. `snapshot` keeps several queries on one commit.
    func read<T>(snapshot: Bool = false, _ body: (Database) throws -> T) throws -> T {
        readLock.lock(); defer { readLock.unlock() }
        return snapshot ? try reader.snapshot { try body(reader) } : try body(reader)
    }

    func indexedPaths() throws -> [String] {
        try refreshReadOnlyCaches()
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

    /// `indexedPaths()` under one folder, sorted by path. Kept for the last folder asked about
    /// until the next write, so typing in a folder-scoped quick open filters the cached list
    /// once instead of refetching the folder from SQLite per keystroke.
    func indexedPaths(inFolder folder: String) throws -> [String] {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return try indexedPaths() }
        let prefix = trimmed + "/"
        cacheLock.lock()
        if let cached = folderPathCache, cached.folder == prefix, cached.generation == generation {
            cacheLock.unlock(); return cached.paths
        }
        let gen = generation
        cacheLock.unlock()
        // A byte-wise prefix: the same bounds as `folderPredicate` ("folder/" up to "folder0").
        let paths = try indexedPaths().filter { $0.utf8.starts(with: prefix.utf8) }
        cacheLock.lock()
        if generation == gen { folderPathCache = (prefix, gen, paths) }
        cacheLock.unlock()
        return paths
    }

    /// Ordinary folders inferred once per index generation, shared by both search passes.
    /// Stop walking as soon as a known parent is reached; a large directory needs one
    /// path operation per file, not one operation per ancestor per keystroke.
    func indexedDirectories(shouldCancel: @Sendable () -> Bool = { false }) throws -> [String] {
        try refreshReadOnlyCaches()
        cacheLock.lock()
        if let cached = directoryCache { cacheLock.unlock(); return cached }
        let gen = generation
        cacheLock.unlock()
        var directories = Set<String>()
        for (offset, path) in try indexedPaths().enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() { throw CancellationError() }
            var parent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
            while !parent.isEmpty, parent != ".", directories.insert(parent).inserted {
                parent = parent.lastIndex(of: "/").map { String(parent[..<$0]) } ?? ""
            }
        }
        let result = directories.sorted()
        cacheLock.lock()
        if generation == gen { directoryCache = result }
        cacheLock.unlock()
        return result
    }

    /// A dedicated interactive reader has its own connection and lock, independent of
    /// graph construction and indexing. Observe external WAL commits before reusing its
    /// filename/folder cache so a session-cached reader keeps seeing newly indexed files.
    func refreshReadOnlyCaches() throws {
        guard readsOnly else { return }
        let version = try read { try $0.scalarInt("PRAGMA data_version") }
        cacheLock.lock()
        let changed = readerDataVersion.map { $0 != version } ?? false
        if changed {
            generation += 1
            pathCache = nil
            directoryCache = nil
        }
        readerDataVersion = version
        cacheLock.unlock()
        if changed { embedding.lock.withLock { embedding.matrix = nil } }
    }

    func invalidateCaches() {
        cacheLock.lock(); generation += 1; pathCache = nil; directoryCache = nil; cacheLock.unlock()
        embedding.lock.withLock { embedding.matrix = nil }
        noteWrite()
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
        // A reindex or compaction can push the WAL to hundreds of MB; give that back after
        // each checkpoint instead of keeping the file at its high-water mark.
        // Incremental auto-vacuum lets idle maintenance hand freed pages back to the disk
        // (`releaseFreeSpace`). It only takes effect on a database with no tables yet;
        // an older index keeps its free pages for reuse.
        try db.exec("PRAGMA auto_vacuum = INCREMENTAL")
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY; PRAGMA journal_size_limit = 67108864;")
        // BEGIN IMMEDIATE serializes two processes opening a fresh index at once.
        try db.transaction {
            let v = try db.userVersion()
            if v > schemaVersion { throw SchemaTooNew() }
            if v < 1 { try db.exec(Schema.v1) }
            if v < 2 { try db.exec(Schema.v2) }
            if v < 3 { try db.exec(Schema.v3) }
            if v < 4 { try db.exec(Schema.v4) }
            if v < 5 { try db.exec(Schema.v5) }
            if v < 6 { try db.exec(Schema.v6) }
            if v < 7 { try db.exec(Schema.v7) }
            if v < 8 {
                // Semantic search (`Schema.semantic`): the idempotent DDL the writer used to
                // apply lazily, now a numbered step so read-only stores can rely on it.
                let columns = try db.query("PRAGMA table_info(embedding_spans)") { $0.string(1) }
                for c in Schema.semanticColumns where !columns.contains(c.column) { try db.exec(c.ddl) }
                try db.exec(Schema.semantic)
                let applied = try db.query("SELECT value FROM meta WHERE key = 'semantic_schema'") { $0.string(0) }.first
                if applied != semanticSchemaVersion {
                    // Vectors from before passages had hashes are another format: drop them.
                    try db.exec("DELETE FROM embedding_spans WHERE hash IS NULL AND offset >= 0; DELETE FROM embeddings;")
                    try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('semantic_schema', ?)", semanticSchemaVersion)
                }
                try db.exec("PRAGMA user_version = 8;")
            }
            if v < 9 {
                let columns = Set(try db.query("PRAGMA table_info(comments)") { $0.string(1) })
                for c in Schema.v9Columns where !columns.contains(c.column) { try db.exec(c.ddl) }
                try db.exec(Schema.v9)
            }
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
            let row = try writer.query("SELECT mtime, size, id, indexed_at, extraction_state, retry_after, processed_units FROM files WHERE path = ?", p) {
                Known(stamp: Stamp(mtime: $0.double(0), size: $0.int(1)), id: $0.optionalString(2), indexedAt: $0.double(3), state: $0.string(4), retryAfter: $0.isNull(5) ? nil : $0.double(5), processedUnits: $0.isNull(6) ? nil : $0.int(6))
            }
            if let r = row.first { out[p] = r }
        }
        return out
    }

    /// Ids are read, never assigned: a file has one once someone comments on it.
    private func identity(of ref: FileRef) -> UUID? {
        (try? FileIdentity.existingID(atPath: filePath(ref))) ?? nil
    }

    /// The file's absolute path, without building a URL.
    func filePath(_ ref: FileRef) -> String { rootPrefix + ref.relativePath }

    private func recordIdentity(of ref: FileRef) throws {
        guard let id = identity(of: ref) else { return }
        try writer.run("UPDATE files SET id = ? WHERE path = ?", id.uuidString, ref.relativePath)
    }

    /// Moves the row of a vanished file carrying `id` to `ref`, keeping its extracted text.
    private func adoptRow(carrying id: UUID, to ref: FileRef) throws {
        let candidates = try writer.query("SELECT path, title, tags FROM files WHERE id = ? AND path != ?",
                                          id.uuidString, ref.relativePath) { ($0.string(0), $0.optionalString(1), $0.optionalString(2)) }
        guard let (old, title, tags) = candidates.first(where: {
            var st = stat()
            let result = lstat(vault.url(for: FileRef(relativePath: $0.0)).path, &st)
            return result != 0 && (errno == ENOENT || errno == ENOTDIR)
        }) else { return }
        try deleteRows(path: ref.relativePath)
        try writer.run("UPDATE files SET path = ?, ext = ? WHERE path = ?", ref.relativePath, ref.ext, old)
        try writer.run("UPDATE sections SET path = ? WHERE path = ?", ref.relativePath, old)
        try writer.run("UPDATE sections SET title = ? WHERE path = ? AND ord = 0", Self.fileTitle(title, ref, tags: tags), ref.relativePath)
        try journalRename(from: FileRef(relativePath: old), to: ref, identity: id)
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

    private func ingest(_ todo: [Pending], shouldCancel: () -> Bool, onRead: ((Int, FileRef) -> Void)?) throws -> Int {
        guard !todo.isEmpty else { return 0 }
        // Grouped by type: Spotlight-backed formats pay ~0.75s whenever the importer changes.
        let todo = todo.sorted { ($0.ref.ext, $0.ref.relativePath) < ($1.ref.ext, $1.ref.relativePath) }
        let queue = ExtractionQueue(todo, vault: vault, width: Self.extractionWidth, buffer: Self.batchSize * 2)
        var written = 0
        defer { queue.cancel() }
        while let batch = queue.next(batchSize: Self.batchSize, shouldCancel: shouldCancel) {
            try writer.transaction { for e in batch { try write(e) } }
            written += batch.count
            if let last = batch.last { onRead?(batch.count, last.ref) }
        }
        return written
    }

    func write(_ e: Extraction) throws {
        let path = e.ref.relativePath
        let x = e.extracted ?? Extracted(text: "")
        let title = x.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let priorAttempts = try writer.scalarInt("SELECT attempt_count FROM files WHERE path = ?", path)
        let hadPrevious = try writer.scalarInt("SELECT count(*) FROM files WHERE path = ?", path) > 0
        let preserve = (x.coverage.state == .failed || x.coverage.state == .metadataOnly) && hadPrevious
        if preserve {
            try writer.run("UPDATE files SET id = coalesce(?, id), mtime = ?, size = ? WHERE path = ?", e.id, e.stamp.mtime, e.stamp.size, path)
            try recordCoverage(x.coverage, path: path, priorAttempts: priorAttempts)
            return
        }

        // Row 0 is the file itself: its name and title, plus the full text when the
        // sections don't already cover it (or there are none).
        let joined = x.sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let wholeText = x.sections.isEmpty || x.text.trimmingCharacters(in: .whitespacesAndNewlines) != joined.trimmingCharacters(in: .whitespacesAndNewlines)
        var budget = Self.textBudget(ext: e.ref.ext)
        let fileText = wholeText ? Self.capped(x.text, budget) : ""
        budget -= fileText.utf16.count
        var texts = [fileText]
        for s in x.sections {
            let text = Self.capped(s.text, max(0, min(Self.maxSectionText, budget)))
            budget -= text.utf16.count
            texts.append(text)
        }
        // A model's title and tags took seconds of a local LLM each. Re-reading a file whose
        // text didn't change (a new extractor version, a retry, a touched mtime) keeps them.
        let carried = hadPrevious && title == nil ? try carriedTitle(path: path, texts: texts) : nil

        try deleteRows(path: path)
        try writer.run("""
            INSERT INTO files(path, id, mtime, size, ext, title, indexed_at, tags, titled_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, path, e.id, e.stamp.mtime, e.stamp.size, e.ref.ext, title ?? carried?.title, Date().timeIntervalSince1970,
            carried?.tags, carried?.model)
        try recordCoverage(x.coverage, path: path, priorAttempts: priorAttempts)

        let insert = "INSERT INTO sections(path, ord, anchor_kind, anchor_value, title, text) VALUES (?, ?, ?, ?, ?, ?)"
        try writer.run(insert, path, 0, nil, nil, Self.fileTitle(title ?? carried?.title, e.ref, tags: carried?.tags), texts[0])
        for (i, s) in x.sections.enumerated() {
            try writer.run(insert, path, i + 1, s.anchor.kind.rawValue, s.anchor.value, s.title, texts[i + 1])
        }
        let extracted = x.sections.reduce(wholeText ? x.text.utf16.count : 0) { $0 + $1.text.utf16.count }
        if x.coverage.state == .complete, texts.reduce(0, { $0 + $1.utf16.count }) < extracted {
            try recordCoverage(ExtractionCoverage(.partial, reason: "Indexed text exceeded the per-file or per-section budget."), path: path, priorAttempts: priorAttempts)
        }
    }

    /// The model's title and tags for `path` (`titled_by` set) when the text it was given,
    /// the start of each section as `untitled` reads it, is the same in `texts`.
    private func carriedTitle(path: String, texts: [String]) throws -> (title: String?, tags: String?, model: String)? {
        guard let row = try writer.query("SELECT title, tags, titled_by FROM files WHERE path = ? AND titled_by IS NOT NULL", path, row: {
            (title: $0.optionalString(0), tags: $0.optionalString(1), model: $0.string(2))
        }).first else { return nil }
        let before = try writer.query("SELECT substr(text, 1, ?2) FROM sections WHERE path = ?1 ORDER BY ord", path, Titler.maxChars) { $0.string(0) }
        return Self.titlerInput(before) == Self.titlerInput(texts) ? row : nil
    }

    /// What `Titler.describe` reads from a file's sections. Counts code points, like SQLite's `substr`.
    static func titlerInput(_ texts: [String]) -> String {
        let joined = texts.map { String($0.unicodeScalars.prefix(Titler.maxChars)) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return String(joined.prefix(Titler.maxChars))
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
        var info = stat()
        if lstat(notesPrefix + ref.relativePath + ".md", &info) != 0 {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            comments = []
        } else {
            // Propagate a read failure; the transaction keeps the last good comments.
            comments = try sidecars.comments(for: ref)
        }
        try syncComments(comments, path: ref.relativePath)
    }

    /// A `comments` row as `syncComments` writes it.
    struct StoredComment: Equatable {
        var id: String, ts: Double, anchorKind: String?, anchorValue: String?, text: String, provenance: String?
        var uid: String?, parent: String?, kind: String?, kindBy: String?, state: String
        var due: Double?, snoozeUntil: Double?, modified: Double?
        var origin: String, action: String?, meta: String?

        static let columns = "id, ts, anchor_kind, anchor_value, text, provenance, uid, parent, kind, kind_by, state, due, snooze_until, modified, origin, action, meta"

        init(row r: Row, at i: Int32 = 0) {
            id = r.string(i); ts = r.double(i + 1); anchorKind = r.optionalString(i + 2); anchorValue = r.optionalString(i + 3)
            text = r.string(i + 4); provenance = r.optionalString(i + 5); uid = r.optionalString(i + 6); parent = r.optionalString(i + 7)
            kind = r.optionalString(i + 8); kindBy = r.optionalString(i + 9); state = r.string(i + 10)
            due = r.isNull(i + 11) ? nil : r.double(i + 11); snoozeUntil = r.isNull(i + 12) ? nil : r.double(i + 12)
            modified = r.isNull(i + 13) ? nil : r.double(i + 13)
            origin = r.string(i + 14); action = r.optionalString(i + 15); meta = r.optionalString(i + 16)
        }

        init(_ c: Comment) {
            id = c.id.uuidString; ts = c.timestamp.timeIntervalSince1970; anchorKind = c.anchor?.kind.rawValue; anchorValue = c.anchor?.value
            text = c.text; provenance = IndexStore.provenanceJSON(c)
            let meta = c.meta
            uid = meta?.uid; parent = meta?.parent
            let reading = ThoughtRules.read(c.text, at: c.timestamp)
            kind = (meta?.kind ?? reading.kind).rawValue
            kindBy = (meta?.kindBy ?? (meta?.kind != nil ? .model : .rules)).rawValue
            state = (meta?.state ?? .open).rawValue
            // The person's or a model's due date wins over the one read from the words.
            due = meta?.due.flatMap { ThoughtDates.parse($0)?.date.timeIntervalSince1970 } ?? reading.due?.date.timeIntervalSince1970
            snoozeUntil = meta?.snoozeUntil.flatMap { ThoughtDates.parse($0)?.date.timeIntervalSince1970 }
            modified = meta?.modified.flatMap { ThoughtDates.parse($0)?.date.timeIntervalSince1970 }
            origin = (c.provenance?.origin ?? .human).rawValue
            action = meta?.intent?.action
            self.meta = SidecarFormat.metadataJSON(of: c)
        }
    }

    static func provenanceJSON(_ c: Comment) -> String? {
        c.provenance.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
    }

    /// Makes the rows for `path` these comments. Every pass re-reads every target's note, so
    /// rows that did not change are left alone (rewriting them would churn the comment FTS
    /// index and the WAL on each launch). A thought with the same derived id (same words,
    /// time and anchor) is updated in place, without touching `text`: its rowid and vector
    /// survive a done, a snooze, a new kind or a reply elsewhere in the thread.
    func syncComments(_ comments: [Comment], path: String) throws {
        let stored = try writer.query("SELECT rowid, \(StoredComment.columns) FROM comments WHERE path = ? ORDER BY rowid", path) {
            ($0.int(0), StoredComment(row: $0, at: 1))
        }
        let wanted = comments.map(StoredComment.init)
        if stored.count == wanted.count, zip(stored, wanted).allSatisfy({ $0.1 == $1 }) { return }
        let wantedIDs = Set(wanted.map(\.id))
        var byID: [String: (rowid: Int, row: StoredComment)] = [:]
        for (rowid, row) in stored {
            if wantedIDs.contains(row.id), byID[row.id] == nil { byID[row.id] = (rowid, row) }
            else { try writer.run("DELETE FROM comments WHERE rowid = ?", rowid) }
        }
        for w in wanted {
            if let existing = byID.removeValue(forKey: w.id) {
                guard existing.row != w else { continue }
                // `text` is not in the SET list, so the text triggers (and the vector) stay out of it.
                try writer.run("""
                    UPDATE comments SET provenance = ?, uid = ?, parent = ?, kind = ?, kind_by = ?, state = ?, due = ?,
                        snooze_until = ?, modified = ?, origin = ?, action = ?, meta = ? WHERE rowid = ?
                    """, w.provenance, w.uid, w.parent, w.kind, w.kindBy, w.state, w.due, w.snoozeUntil, w.modified, w.origin, w.action, w.meta, existing.rowid)
            } else {
                try writer.run("""
                    INSERT INTO comments(path, \(StoredComment.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, path, w.id, w.ts, w.anchorKind, w.anchorValue, w.text, w.provenance, w.uid, w.parent, w.kind, w.kindBy, w.state,
                    w.due, w.snoozeUntil, w.modified, w.origin, w.action, w.meta)
            }
        }
    }

    /// The file row's searchable title: `Title · name.ext`, then any model-given tags.
    static func fileTitle(_ title: String?, _ ref: FileRef, tags: String? = nil) -> String {
        var s = ref.name
        if let title, title != ref.name, title != (ref.name as NSString).deletingPathExtension { s = title + " · " + ref.name }
        if let tags, !tags.isEmpty { s += " · " + tags }
        let parent = (ref.relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty { s += " · " + parent }
        return s
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
        // Threads don't inherit QoS: detached ones ran at default priority even under the
        // app's utility reindex queue, competing with the UI for performance cores. Run
        // them at the caller's QoS instead.
        let qos = Self.qualityOfService(qos_class_self())
        for _ in 0..<min(width, todo.count) {
            let thread = Thread { [self] in work() }
            thread.qualityOfService = qos
            thread.start()
        }
    }

    static func qualityOfService(_ c: qos_class_t) -> QualityOfService {
        switch c {
        case QOS_CLASS_USER_INTERACTIVE: .userInteractive
        case QOS_CLASS_USER_INITIATED: .userInitiated
        case QOS_CLASS_UTILITY: .utility
        case QOS_CLASS_BACKGROUND: .background
        default: .default
        }
    }

    func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }

    /// Blocks until `batchSize` results are ready (or everything left is), `nil` when finished.
    func next(batchSize: Int, shouldCancel: () -> Bool) -> [IndexStore.Extraction]? {
        cond.lock(); defer { cond.unlock() }
        let remaining = todo.count - delivered
        guard remaining > 0 else { return nil }
        let want = min(batchSize, remaining)
        while done.count < want && !cancelled {
            if shouldCancel() { cancelled = true; cond.broadcast(); return nil }
            _ = cond.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard !cancelled, !shouldCancel() else { cancelled = true; cond.broadcast(); return nil }
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
                var result: Extracted
                if !VaultScanner.limits.allowsExtraction(of: url) {
                    result = .empty
                    result.coverage = ExtractionCoverage(.metadataOnly, reason: p.stamp.size > VaultScanner.limits.maxExtractableBytes
                        ? "File exceeds the 50 MB extraction limit." : "Cloud file is not downloaded; indexed by filename.")
                } else {
                    do {
                        result = p.ref.ext == "pdf" && !p.resume.isEmpty
                            ? try PDFExtractor().extract(url, resuming: p.resume, processedPages: p.processedUnits)
                            : try Extract.extract(url)
                    } catch {
                        result = .empty
                        result.coverage = ExtractionCoverage(.failed, reason: "\(error)")
                    }
                }
                return IndexStore.Extraction(ref: p.ref, stamp: p.stamp, id: id, extracted: result)
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
