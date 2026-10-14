import Foundation

/// Reads and writes sidecar notes under `<vault>/.flamingo/notes/<relativePath>.md`.
///
/// Every write is atomic (temp file + rename) and goes through `SidecarDocument`, so
/// hand-written lines, extra frontmatter keys, and comment order survive. All methods
/// are safe to call from any thread; operations on the store are serialized.
///
/// The first time a note is written for a file, the store also stamps the file with a
/// `FileIdentity` (an xattr, never file content) and records it as `id:` in the note so
/// `reconcile()` can follow the file if it is renamed or moved.
public final class SidecarStore: @unchecked Sendable {
    public let vault: Vault
    private let lock = NSLock()

    public init(vault: Vault) { self.vault = vault }

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
        lock.lock(); defer { lock.unlock() }
        return try read(ref)
    }

    public func comments(for ref: FileRef) throws -> [Comment] {
        try document(for: ref)?.comments ?? []
    }

    /// Number of comments on `ref`, without building `Comment` values you don't need.
    public func commentCount(for ref: FileRef) throws -> Int {
        try document(for: ref)?.comments.count ?? 0
    }

    /// Every sidecar in the vault, keyed by target, including notes whose target file
    /// no longer exists (orphans). Notes that cannot be read are skipped.
    public func all() throws -> [FileRef: [Comment]] {
        try allDocuments().mapValues(\.comments)
    }

    /// Like `all()` but with full documents (frontmatter, ids, raw lines).
    public func allDocuments() throws -> [FileRef: SidecarDocument] {
        lock.lock(); defer { lock.unlock() }
        var out: [FileRef: SidecarDocument] = [:]
        for ref in try sidecarRefsLocked() {
            if let doc = try? read(ref) { out[ref] = doc }
        }
        return out
    }

    /// Targets of every note in the vault, in Finder order. Cheap: nothing is parsed.
    public func sidecarRefs() throws -> [FileRef] {
        lock.lock(); defer { lock.unlock() }
        return try sidecarRefsLocked()
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

    /// Removes a comment. When nothing is left in the body the note file is removed too,
    /// along with any folders under `notesDir` it leaves empty.
    public func delete(_ id: UUID, from ref: FileRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard var doc = try read(ref) else { throw SidecarError.commentNotFound(id) }
        guard doc.remove(id: id) != nil else { throw SidecarError.commentNotFound(id) }
        if doc.isEmpty {
            try removeLocked(ref)
        } else {
            try write(doc, for: ref)
        }
    }

    /// Writes a document as the note for `ref`, replacing whatever was there. The
    /// document's `target` is set to `ref`, and a missing `id` is filled from `FileIdentity`.
    public func save(_ document: SidecarDocument, for ref: FileRef) throws {
        lock.lock(); defer { lock.unlock() }
        try write(document, for: ref)
    }

    /// Deletes the note for `ref` (and folders it leaves empty). No error if absent.
    public func removeSidecar(for ref: FileRef) throws {
        lock.lock(); defer { lock.unlock() }
        try removeLocked(ref)
    }

    /// Moves the note for `old` to `new`, rewriting `target`. If `new` already has a note
    /// the two are merged, `new`'s comments first. No-op if `old` has no note.
    public func move(sidecarFor old: FileRef, to new: FileRef) throws {
        lock.lock(); defer { lock.unlock() }
        try moveLocked(from: old, to: new)
    }

    // MARK: Reconcile

    /// A note that followed its renamed file.
    public struct Move: Equatable, Sendable {
        public let from: FileRef
        public let to: FileRef
        public init(from: FileRef, to: FileRef) { self.from = from; self.to = to }
    }

    /// Heals renames: for every note whose target no longer exists but whose `id` is
    /// carried by some other file in the vault, moves the note to that file. Returns the
    /// moves made. Notes with no `id`, or whose id is nowhere, are left as orphans.
    @discardableResult
    public func reconcile() throws -> [Move] {
        lock.lock(); defer { lock.unlock() }
        var moves: [Move] = []
        var ids: [UUID: FileRef]? = nil
        for ref in try sidecarRefsLocked() where !vault.exists(ref) {
            guard let doc = try? read(ref), let id = doc.id else { continue }
            if ids == nil { ids = FileIdentity.ids(in: vault) }
            guard let found = ids?[id], found != ref else { continue }
            try moveLocked(from: ref, to: found)
            moves.append(Move(from: ref, to: found))
        }
        return moves
    }

    // MARK: - Private

    private func modify(_ ref: FileRef, _ body: (inout SidecarDocument) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try read(ref) ?? newDocument(for: ref)
        try body(&doc)
        try write(doc, for: ref)
    }

    private func newDocument(for ref: FileRef) -> SidecarDocument {
        SidecarDocument(target: ref, id: identity(of: ref), comments: [])
    }

    private func identity(of ref: FileRef) -> UUID? {
        guard vault.exists(ref) else { return nil }
        return try? FileIdentity.id(for: vault.url(for: ref))
    }

    private func read(_ ref: FileRef) throws -> SidecarDocument? {
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
        var doc = document
        if doc.target != ref { doc.target = ref }
        if doc.id == nil, let id = identity(of: ref) { doc.id = id }
        try AtomicFile.write(Data(SidecarFormat.render(doc).utf8), to: sidecarURL(for: ref))
    }

    private func removeLocked(_ ref: FileRef) throws {
        let url = sidecarURL(for: ref)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        pruneEmptyFolders(from: url.deletingLastPathComponent())
    }

    private func moveLocked(from old: FileRef, to new: FileRef) throws {
        guard old != new, var doc = try read(old) else { return }
        doc.target = new
        if var existing = try read(new) {
            existing.merge(doc)
            if existing.id == nil { existing.id = doc.id }
            try write(existing, for: new)
        } else {
            try write(doc, for: new)
        }
        try removeLocked(old)
    }

    private func sidecarRefsLocked() throws -> [FileRef] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vault.notesDir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let e = fm.enumerator(at: vault.notesDir, includingPropertiesForKeys: Array(keys),
                                    options: [.skipsHiddenFiles]) else { return [] }
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
