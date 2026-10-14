import Foundation

/// Reads and writes sidecar notes under `<vault>/.flamingo/notes/<relativePath>.md`.
///
/// Every write is atomic (temp file + rename) and goes through `SidecarDocument`, so
/// hand-written lines, extra frontmatter keys, and comment order survive. All methods
/// are safe to call from any thread; operations are serialized within a process by a
/// lock and across processes (the app and `flamingo-index`) by an advisory file lock.
///
/// The first time a note is written for a file, the store also stamps the file with a
/// `FileIdentity` (an xattr, never file content) and records it as `id:` in the note so
/// `reconcile()` can follow the file if it is renamed or moved. On every write the note's
/// `id:` is brought in line with what the file actually carries.
public final class SidecarStore: @unchecked Sendable {
    public let vault: Vault
    private let lock = NSLock()
    private let processLock: ProcessLock

    public init(vault: Vault) {
        self.vault = vault
        self.processLock = ProcessLock(path: vault.stateDir.appendingPathComponent(".notes.lock").path)
    }

    /// `<vault>/.flamingo/notes/<relativePath>.md`
    public func sidecarURL(for ref: FileRef) -> URL {
        vault.notesDir.appendingPathComponent(ref.relativePath + ".md")
    }

    /// The inverse of `sidecarURL(for:)`: which user file a note under `notesDir` is about.
    /// Nil for anything outside `notesDir` or not ending in `.md`.
    public func target(ofSidecar url: URL) -> FileRef? {
        let notes = vault.notesDir.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(notes), path.hasSuffix(".md") else { return nil }
        let rel = String(path.dropFirst(notes.count).dropLast(3))
        guard !rel.isEmpty, !rel.hasSuffix("/") else { return nil }
        return FileRef(relativePath: rel)
    }

    /// True if a note exists for `ref`.
    public func hasSidecar(for ref: FileRef) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: ref).path)
    }

    // MARK: Reading

    /// The whole note for `ref`, or nil if there is none.
    public func document(for ref: FileRef) throws -> SidecarDocument? {
        try locked { try read(ref) }
    }

    public func comments(for ref: FileRef) throws -> [Comment] {
        try document(for: ref)?.comments ?? []
    }

    /// Number of comments on `ref`. Convenience over `comments(for:)`.
    public func commentCount(for ref: FileRef) throws -> Int {
        try document(for: ref)?.comments.count ?? 0
    }

    /// Every sidecar in the vault, keyed by target, including notes whose target file
    /// no longer exists (orphans) and notes on hidden files. Notes that cannot be read are skipped.
    public func all() throws -> [FileRef: [Comment]] {
        try allDocuments().mapValues(\.comments)
    }

    /// Like `all()` but with full documents (frontmatter, ids, raw lines).
    public func allDocuments() throws -> [FileRef: SidecarDocument] {
        try locked {
            var out: [FileRef: SidecarDocument] = [:]
            for ref in try sidecarRefsLocked() {
                if let doc = try? read(ref) { out[ref] = doc }
            }
            return out
        }
    }

    /// Targets of every note in the vault, in Finder order. Cheap: nothing is parsed.
    public func sidecarRefs() throws -> [FileRef] {
        try locked { try sidecarRefsLocked() }
    }

    // MARK: Writing

    public func append(_ comment: Comment, to ref: FileRef) throws {
        try modify(ref) { $0.append(comment) }
    }

    /// Inserts so the comment becomes `comments(for:)[index]`; `index == count` appends.
    /// Lets an undo put a deleted comment back where it was.
    public func insert(_ comment: Comment, at index: Int, in ref: FileRef) throws {
        try modify(ref) { try $0.insert(comment, at: index) }
    }

    /// Replaces the comment with `comment.id`. Throws `SidecarError.commentNotFound`.
    public func update(_ comment: Comment, in ref: FileRef) throws {
        try modify(ref) { doc in
            guard doc.update(comment) else { throw SidecarError.commentNotFound(comment.id) }
        }
    }

    /// Removes a comment. When nothing is left in the body and the frontmatter holds
    /// nothing but `target` and `id`, the note file is removed too, along with any folders
    /// under `notesDir` it leaves empty. Hand-added frontmatter keys keep the note alive.
    public func delete(_ id: UUID, from ref: FileRef) throws {
        try locked {
            guard var doc = try read(ref) else { throw SidecarError.commentNotFound(id) }
            guard doc.remove(id: id) != nil else { throw SidecarError.commentNotFound(id) }
            if doc.isEmpty, doc.frontmatterKeys.allSatisfy({ $0 == "target" || $0 == "id" }) {
                try removeLocked(ref)
            } else {
                try write(doc, for: ref)
            }
        }
    }

    /// Writes a document as the note for `ref`, replacing whatever was there. The
    /// document's `target` is set to `ref`, and its `id` is synced with the file's identity.
    public func save(_ document: SidecarDocument, for ref: FileRef) throws {
        try locked { try write(document, for: ref) }
    }

    /// Deletes the note for `ref` (and folders it leaves empty). No error if absent.
    public func removeSidecar(for ref: FileRef) throws {
        try locked { try removeLocked(ref) }
    }

    /// Moves the note for `old` to `new`, rewriting `target`. If `new` already has a note
    /// the two are merged, `new`'s comments first. No-op if `old` has no note.
    public func move(sidecarFor old: FileRef, to new: FileRef) throws {
        try locked { try moveLocked(from: old, to: new) }
    }

    // MARK: Reconcile

    /// A note that followed its renamed file.
    public struct Move: Equatable, Sendable {
        public let from: FileRef
        public let to: FileRef
        public init(from: FileRef, to: FileRef) { self.from = from; self.to = to }
    }

    /// Heals renames: for every note whose target no longer exists (exact case) but whose
    /// `id` is carried by some other file in the vault, moves the note to that file. When
    /// several files carry the id (copies), the one without a note of its own wins; if that
    /// is still ambiguous the note is left alone. Returns the moves made. Notes with no
    /// `id`, or whose id is nowhere, stay as orphans.
    @discardableResult
    public func reconcile() throws -> [Move] {
        try locked {
            var moves: [Move] = []
            var carriers: [UUID: [FileRef]]? = nil
            for ref in try sidecarRefsLocked() where !vault.existsExactly(ref) {
                guard let doc = try? read(ref), let id = doc.id else { continue }
                if carriers == nil { carriers = FileIdentity.carriers(in: vault) }
                var candidates = (carriers?[id] ?? []).filter { $0 != ref }
                if candidates.count > 1 { candidates = candidates.filter { !hasSidecar(for: $0) } }
                guard candidates.count == 1, let found = candidates.first else { continue }
                try moveLocked(from: ref, to: found)
                moves.append(Move(from: ref, to: found))
            }
            return moves
        }
    }

    // MARK: - Private

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try processLock.withLock(body)
    }

    private func modify(_ ref: FileRef, _ body: (inout SidecarDocument) throws -> Void) throws {
        try locked {
            var doc = try read(ref) ?? newDocument(for: ref)
            try body(&doc)
            try write(doc, for: ref)
        }
    }

    /// The document to start from when `ref` has no note yet. If the file already carries
    /// an id that another note claims, either that note's file is gone (the file was renamed:
    /// adopt the note now) or it still exists (the file was duplicated: give this one a
    /// fresh id so the two never merge).
    private func newDocument(for ref: FileRef) throws -> SidecarDocument {
        try validate(ref)
        guard vault.exists(ref) else { return SidecarDocument(target: ref, id: nil, comments: []) }
        let url = vault.url(for: ref)
        if let carried = try? FileIdentity.existingID(for: url) {
            for other in try sidecarRefsLocked() where other != ref {
                guard let doc = try? read(other), doc.id == carried else { continue }
                if !vault.existsExactly(other) {
                    try moveLocked(from: other, to: ref)
                    if let adopted = try read(ref) { return adopted }
                } else if (try? FileIdentity.existingID(for: vault.url(for: other))) == carried {
                    let fresh = UUID()
                    try FileIdentity.assign(fresh, to: url)
                    return SidecarDocument(target: ref, id: fresh, comments: [])
                }
            }
        }
        return SidecarDocument(target: ref, id: identity(of: ref), comments: [])
    }

    /// The file's identity, stamping it if needed. Nil when the file is missing or
    /// cannot take an xattr (read-only, locked, or a volume without xattrs).
    private func identity(of ref: FileRef) -> UUID? {
        guard vault.exists(ref) else { return nil }
        return try? FileIdentity.id(for: vault.url(for: ref))
    }

    /// Refuses refs that would land outside `notesDir`.
    private func validate(_ ref: FileRef) throws {
        let components = ref.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !ref.relativePath.isEmpty, !ref.relativePath.hasPrefix("/"), !ref.relativePath.hasSuffix("/"),
              !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw SidecarError.notASidecar(ref.relativePath)
        }
    }

    private func read(_ ref: FileRef) throws -> SidecarDocument? {
        try validate(ref)
        let url = sidecarURL(for: ref)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return nil
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SidecarError.notUTF8(path: url.path) }
        return SidecarFormat.parseDocument(text)
    }

    private func write(_ document: SidecarDocument, for ref: FileRef) throws {
        try validate(ref)
        var doc = document
        if doc.target != ref { doc.target = ref }
        if let actual = identity(of: ref), doc.id != actual { doc.id = actual }
        try AtomicFile.write(Data(SidecarFormat.render(doc).utf8), to: sidecarURL(for: ref))
    }

    private func removeLocked(_ ref: FileRef) throws {
        try validate(ref)
        let url = sidecarURL(for: ref)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        pruneEmptyFolders(from: url.deletingLastPathComponent())
    }

    private func moveLocked(from old: FileRef, to new: FileRef) throws {
        guard old != new, var doc = try read(old) else { return }
        try validate(new)
        doc.target = new
        let oldURL = sidecarURL(for: old), newURL = sidecarURL(for: new)
        if isSameFile(oldURL, newURL) {
            // A case-only rename on a case-insensitive volume: rename in place, then rewrite.
            try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rename(oldURL.path, newURL.path) != 0 { throw SidecarError.writeFailed(path: newURL.path, errno: errno) }
            try write(doc, for: new)
            return
        }
        if var existing = try read(new) {
            existing.merge(doc)
            if existing.id == nil { existing.id = doc.id }
            try write(existing, for: new)
        } else {
            try write(doc, for: new)
        }
        try removeLocked(old)
    }

    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ia = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let ib = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return ia.isEqual(ib)
    }

    private func sidecarRefsLocked() throws -> [FileRef] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vault.notesDir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let e = fm.enumerator(at: vault.notesDir, includingPropertiesForKeys: Array(keys), options: []) else { return [] }
        var refs: [FileRef] = []
        for case let url as URL in e {
            guard url.pathExtension == "md",
                  (try? url.resourceValues(forKeys: keys))?.isRegularFile == true,
                  let ref = target(ofSidecar: url) else { continue }
            refs.append(ref)
        }
        return refs.sorted()
    }

    /// Removes `dir` and its parents while they are empty, stopping at `notesDir`.
    private func pruneEmptyFolders(from dir: URL) {
        let fm = FileManager.default
        let stop = vault.notesDir.standardizedFileURL.path
        var d = dir.standardizedFileURL
        while d.path != stop, d.path.hasPrefix(stop + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: d.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            guard (try? fm.removeItem(at: d)) != nil else { return }
            d = d.deletingLastPathComponent()
        }
    }
}

/// An advisory `flock` so two processes (the app and `flamingo-index --watch`) never
/// interleave a read-modify-write on the same note. Best effort: if the lock file cannot
/// be created (read-only volume) operations proceed unlocked.
final class ProcessLock: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    deinit { if fd >= 0 { close(fd) } }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        if fd < 0 {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fd = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else { return try body() }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
