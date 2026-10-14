import Foundation
import AppKit
import CryptoKit
import FlamingoCore

/// One thing that happened. Appended to `<vault>/.flamingo/trail.jsonl`, one JSON object per line:
///
/// ```
/// {"at":"2026-10-14T20:05:12.345Z","file":"decks/q3.pptx","id":"…","kind":"opened"}
/// {"anchor":"slide 7","at":"2026-10-14T20:06:40.000Z","file":"decks/q3.pptx","id":"…","kind":"commented","text":"Pricing contradicts [[q3-model.xlsx]]"}
/// {"at":"2026-10-14T20:07:02.000Z","id":"…","kind":"searched","text":"churn"}
/// {"at":"2026-10-14T20:07:30.000Z","file":"notes/a.md","id":"…","kind":"linked","text":"q3-model.xlsx"}
/// ```
///
/// `at` is ISO 8601. `file` is the vault-relative path. `anchor` is `kind value` as in sidecars.
/// `text` is the comment (commented), the query (searched) or the link target as typed (linked).
/// `id` is optional when hand-writing a file. Decoding also accepts the synthesized forms
/// (`{"relativePath":…}`, `{"kind":…,"value":…}`, numeric dates).
public struct TrailEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case opened, commented, searched, linked }
    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var file: FileRef?
    public var anchor: FileAnchor?
    public var text: String?       // comment text or search query
    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind, file: FileRef? = nil, anchor: FileAnchor? = nil, text: String? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.file = file; self.anchor = anchor; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case id, at, kind, file, anchor, text }
    private struct LegacyFile: Decodable { var relativePath: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        at = try TrailDate.decode(c, forKey: .at)
        if let path = try? c.decodeIfPresent(String.self, forKey: .file) {
            file = path.isEmpty ? nil : FileRef(relativePath: path)
        } else {
            file = try c.decodeIfPresent(LegacyFile.self, forKey: .file).map { FileRef(relativePath: $0.relativePath) }
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: .anchor) {
            anchor = TrailEvent.parseAnchor(s)
        } else {
            anchor = try c.decodeIfPresent(FileAnchor.self, forKey: .anchor)
        }
        text = try c.decodeIfPresent(String.self, forKey: .text)
        if let s = try? c.decodeIfPresent(String.self, forKey: .id), let u = UUID(uuidString: s) {
            id = u
        } else {
            // Hand-written lines may omit the id. Derive one from the content so it is
            // stable across reloads (session ids and names depend on it).
            id = TrailEvent.derivedID([kind.rawValue, TrailDate.string(at), file?.relativePath ?? "",
                                       anchor?.rendered ?? "", text ?? ""].joined(separator: "\u{1F}"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(TrailDate.string(at), forKey: .at)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(file?.relativePath, forKey: .file)
        try c.encodeIfPresent(anchor?.label, forKey: .anchor)
        try c.encodeIfPresent(text, forKey: .text)
    }

    /// `slide 7`, `Slide 7` or `(slide 7)` → `FileAnchor`, with Core's rules.
    static func parseAnchor(_ s: String) -> FileAnchor? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("("), t.hasSuffix(")") { t = String(t.dropFirst().dropLast()) }
        return FileAnchor(parsing: t)
    }

    static func derivedID(_ seed: String) -> UUID {
        var b = Array(Insecure.MD5.hash(data: Data(seed.utf8)))
        b[6] = (b[6] & 0x0F) | 0x30   // version 3 (name-based, MD5)
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

enum TrailDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func string(_ d: Date) -> String { d.formatted(fractional) }

    static func parse(_ s: String) -> Date? {
        if let d = try? fractional.parse(s) { return d }
        if let d = try? whole.parse(s) { return d }
        // Sidecar-style local time, handy when writing fixtures by hand.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
        if let s = try? c.decode(String.self, forKey: key) {
            guard let d = parse(s) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unreadable date \(s)")
            }
            return d
        }
        let n = try c.decode(Double.self, forKey: key)
        if n > 1e11 { return Date(timeIntervalSince1970: n / 1000) }       // unix milliseconds
        if n > 1.2e9 { return Date(timeIntervalSince1970: n) }             // unix seconds
        return Date(timeIntervalSinceReferenceDate: n)                     // JSONEncoder default
    }
}

/// A chain of events that belong together in time. Plan 07 defines the clustering.
public struct TrailSession: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var events: [TrailEvent]
    public var files: [FileRef]
    /// The name the user gave this chain, from `.flamingo/trail-names.json`.
    public var title: String?
    public init(id: UUID = UUID(), start: Date, end: Date, events: [TrailEvent], files: [FileRef]) {
        self.id = id; self.start = start; self.end = end; self.events = events; self.files = files
    }

    /// The files to push onto the shell's history for Resume, oldest first. Each file sits at
    /// its last visit, so the final element is where the user left off: open it, and ⌘[
    /// walks back through the rest.
    public var filesToReopen: [FileRef] {
        var seen = Set<FileRef>()
        var out: [FileRef] = []
        for e in events.reversed() where e.kind != .searched {
            if let f = e.file, seen.insert(f).inserted { out.append(f) }
        }
        return out.reversed()
    }

    /// Comments made during the session, in order.
    public var comments: [TrailEvent] { events.filter { $0.kind == .commented } }

    /// Search queries made during the session, in order.
    public var searches: [String] { events.filter { $0.kind == .searched }.compactMap(\.text) }
}

/// Thresholds for clustering and edges. Tune on real usage.
public struct TrailTuning: Sendable, Equatable {
    /// A pause longer than this starts a new session.
    public var sessionGap: TimeInterval = 25 * 60
    /// An `opened` file the user moved off within this long is treated as passing through.
    public var minDwell: TimeInterval = 3
    /// Consecutive searches where one extends the other within this window are one search.
    public var searchMerge: TimeInterval = 15
    /// Edge weight from one session is `1 / (1 + ageDays / decayDays)`.
    public var decayDays: Double = 30
    /// Sessions with this many files or fewer connect every pair.
    public var cliqueLimit: Int = 6
    /// In larger sessions, at most this many commented files are connected pairwise.
    public var maxCommentedFiles: Int = 5
    /// After aggregation, an edge is kept only if it is among the strongest this-many edges of
    /// at least one of its two files. A hub can keep more; a file is never cut off entirely.
    public var maxEdgesPerFile: Int = 12
    public init() {}
}


/// Records and reads the trail. Plan 07 owns.
///
/// Thread-safe. `record` never blocks on disk: events are buffered and appended within
/// `flushDelay`. Reads include events that haven't reached the disk yet. Every store on the
/// same vault in this process shares one buffer and cache, so a store made just to record one
/// event (as capture does) is seen at once by the long-lived ones, and dropping it flushes.
public final class TrailStore: @unchecked Sendable {
    public let vault: Vault

    /// Posted on the main queue after an event is recorded or a session renamed, once for every
    /// live store on that vault, with `object` = that store.
    public static let didChangeNotification = Notification.Name("FlamingoTrailStoreDidChange")
    /// UserDefaults key for the privacy switch. Default on.
    public static let enabledDefaultsKey = "trailEnabled"
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    public var fileURL: URL { backend.fileURL }
    public var namesURL: URL { vault.stateDir.appendingPathComponent("trail-names.json") }

    /// How long an event recorded through this store may sit in memory before it is appended.
    public var flushDelay: TimeInterval = 0.5
    public var tuning = TrailTuning()

    private let backend: TrailBackend

    public init(vault: Vault) {
        self.vault = vault
        backend = TrailBackend.shared(for: vault)
        backend.attach(self)
    }

    /// Dropping a store flushes what it recorded, off the caller's thread. The queued write
    /// keeps the backend alive until it lands.
    deinit {
        backend.flushSoon()
    }

    // MARK: Recording

    public func record(_ event: TrailEvent) {
        guard TrailStore.isEnabled, let e = TrailStore.sanitized(event) else { return }
        backend.record(e, flushDelay: flushDelay)
    }

    public func recordOpened(_ file: FileRef, anchor: FileAnchor? = nil) {
        record(TrailEvent(kind: .opened, file: file, anchor: anchor))
    }

    /// Uses the comment's id as the event id, so recording the same comment twice is harmless.
    public func recordComment(_ comment: Comment, on file: FileRef) {
        record(TrailEvent(id: comment.id, at: comment.timestamp, kind: .commented, file: file,
                          anchor: comment.anchor, text: comment.text))
    }

    public func recordSearch(_ query: String) {
        record(TrailEvent(kind: .searched, text: query))
    }

    public func recordLink(from file: FileRef, to target: String) {
        record(TrailEvent(kind: .linked, file: file, text: target))
    }

    /// Appends everything buffered. Safe from any thread; called on `willTerminate` automatically.
    public func flush() {
        backend.flush()
    }

    /// Paths that are absolute, climb out of the vault, or point into `.flamingo` are not
    /// part of the user's work and are never recorded.
    static func sanitized(_ event: TrailEvent) -> TrailEvent? {
        var e = event
        if let path = e.file?.relativePath {
            let parts = path.split(separator: "/")
            if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~")
                || parts.contains("..") || parts.first == ".flamingo" { return nil }
        }
        switch e.kind {
        case .opened, .commented, .linked: if e.file == nil { return nil }
        case .searched: break
        }
        if e.kind == .opened { e.text = nil }
        if let t = e.text {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            // Comments keep their own whitespace; queries and link targets don't need it.
            let kept = e.kind == .commented ? t : trimmed
            e.text = kept.count > 4000 ? String(kept.prefix(4000)) : kept
        } else if e.kind != .opened {
            return nil
        }
        return e
    }

    static func isDuplicate(_ e: TrailEvent, of last: TrailEvent) -> Bool {
        if e.id == last.id { return true }
        guard e.kind == last.kind, e.file == last.file, e.text == last.text else { return false }
        let dt = abs(e.at.timeIntervalSince(last.at))
        switch e.kind {
        case .opened: return e.anchor == last.anchor && dt < 2
        case .commented: return e.anchor == last.anchor && dt < 10
        case .searched, .linked: return dt < 2
        }
    }

    /// O_APPEND write. If a previous run died mid-line, start on a fresh line so the
    /// damage stays confined to the one corrupted line.
    static func append(_ data: Data, to url: URL) throws {
        // Read-write, not write-only: the last-byte check below needs `pread`, which fails
        // with EBADF on an O_WRONLY descriptor. O_APPEND still sends every write to the end.
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var payload = data
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, st.st_size - 1) == 1, last != 0x0A { payload.insert(0x0A, at: 0) }
        }
        try payload.withUnsafeBytes { raw in
            var p = raw.baseAddress!
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                p += n; left -= n
            }
        }
    }

    // MARK: Reading

    /// Every event at or after `since`, oldest first, including ones not yet flushed.
    /// Unreadable lines (a torn last line after a crash, hand edits) are skipped.
    public func events(since: Date? = nil) throws -> [TrailEvent] {
        var all = try backend.events()
        // Stable sort: the file is append-only, so equal timestamps keep their order.
        all = all.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map(\.element)
        if let since { all.removeAll { $0.at < since } }
        return all
    }

    /// Clustered sessions, oldest first, with their names applied.
    public func sessions() throws -> [TrailSession] {
        let names = self.names()
        var out = TrailClustering.sessions(from: try events(), tuning: tuning)
        for i in out.indices { out[i].title = names[out[i].id.uuidString] }
        return out
    }

    /// Edges to merge into the graph: files touched within the same session.
    public func edges() throws -> [Graph.Edge] {
        var exists: [String: Bool] = [:]
        let fm = FileManager.default
        return TrailClustering.edges(from: try sessions(), now: Date(), tuning: tuning).filter { e in
            for p in [e.source, e.target] {
                if exists[p] == nil { exists[p] = fm.fileExists(atPath: vault.url(for: FileRef(relativePath: p)).path) }
                if exists[p] == false { return false }
            }
            return true
        }
    }

    // MARK: Names

    /// Session titles keyed by session id.
    public func names() -> [String: String] {
        guard let data = try? Data(contentsOf: namesURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func title(for session: TrailSession) -> String? { names()[session.id.uuidString] }

    /// Names a session, turning it into a thought chain. `nil` or blank removes the name.
    public func setTitle(_ title: String?, for session: TrailSession) throws {
        try backend.io.sync {
            var map = names()
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            map[session.id.uuidString] = t.isEmpty ? nil : t
            try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(map).write(to: namesURL, options: .atomic)
        }
        backend.notifyChange()
    }
}

/// What every `TrailStore` on one vault shares: the write buffer, the io queue, the
/// incremental read cache, and the list of stores to notify.
final class TrailBackend: @unchecked Sendable {
    let vault: Vault
    let fileURL: URL
    let io = DispatchQueue(label: "com.flamingo.trail.io", qos: .utility)

    private let lock = NSLock()
    private var pending: [TrailEvent] = []
    private var lastRecorded: TrailEvent?
    private var recentIDs: [UUID] = []
    private var recentIDSet = Set<UUID>()
    /// When the scheduled flush will run, if one is scheduled.
    private var flushDeadline: DispatchTime?
    private let stores = NSHashTable<TrailStore>.weakObjects()
    private var terminationObserver: NSObjectProtocol?

    // Incremental read cache, touched only on `io`.
    private var cached: [TrailEvent] = []
    private var cachedIDs = Set<UUID>()
    private var cachedOffset: UInt64 = 0
    private var cachedInode: UInt64 = 0
    /// The bytes just before `cachedOffset`. If they change, the file was rewritten in place.
    private var cachedTail = Data()
    /// Ids on the last line when it has no newline yet: on disk, though not committed.
    private var tailIDs = Set<UUID>()

    private struct Weak { weak var backend: TrailBackend? }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Weak] = [:]

    static func shared(for vault: Vault) -> TrailBackend {
        let key = vault.root.resolvingSymlinksInPath().path
        registryLock.lock(); defer { registryLock.unlock() }
        if let b = registry[key]?.backend { return b }
        let b = TrailBackend(vault: vault)
        registry = registry.filter { $0.value.backend != nil }
        registry[key] = Weak(backend: b)
        return b
    }

    private init(vault: Vault) {
        self.vault = vault
        fileURL = vault.stateDir.appendingPathComponent("trail.jsonl")
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        // Nothing else can hold `self` here, so writing directly cannot race a scheduled flush.
        writePending()
    }

    func attach(_ store: TrailStore) {
        lock.lock(); stores.add(store); lock.unlock()
    }

    func record(_ e: TrailEvent, flushDelay: TimeInterval) {
        lock.lock()
        if recentIDSet.contains(e.id) || lastRecorded.map({ TrailStore.isDuplicate(e, of: $0) }) == true {
            lock.unlock(); return
        }
        lastRecorded = e
        recentIDs.append(e.id); recentIDSet.insert(e.id)
        if recentIDs.count > 512 { recentIDSet.remove(recentIDs.removeFirst()) }
        pending.append(e)
        // Stores may ask for different delays; the earliest deadline wins.
        let deadline = DispatchTime.now() + flushDelay
        let schedule = flushDeadline.map { deadline < $0 } ?? true
        if schedule { flushDeadline = deadline }
        lock.unlock()
        if schedule {
            io.asyncAfter(deadline: deadline) { [weak self] in self?.writePending() }
        }
        notifyChange()
    }

    func flush() {
        io.sync { writePending() }
    }

    func flushSoon() {
        io.async { self.writePending() }
    }

    func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.stores.allObjects
            self.lock.unlock()
            for s in live { NotificationCenter.default.post(name: TrailStore.didChangeNotification, object: s) }
        }
    }

    /// File events plus buffered ones, in file-then-buffer order.
    func events() throws -> [TrailEvent] {
        try io.sync {
            let onDisk = try readDisk()
            lock.lock(); defer { lock.unlock() }
            return onDisk + pending.filter { !cachedIDs.contains($0.id) && !tailIDs.contains($0.id) }
        }
    }

    /// Runs on `io` (or in deinit).
    private func writePending() {
        lock.lock()
        let isEmpty = pending.isEmpty
        lock.unlock()
        guard !isEmpty else { return }
        // Bring the cache up to date so an event already on disk (the same comment recorded
        // again after a relaunch) isn't written twice.
        _ = try? readDisk()
        lock.lock()
        let batch = pending.filter { !cachedIDs.contains($0.id) && !tailIDs.contains($0.id) }
        pending.removeAll()
        flushDeadline = nil
        lock.unlock()
        guard !batch.isEmpty else { return }

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for e in batch {
            guard let line = try? enc.encode(e) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
            try TrailStore.append(data, to: fileURL)
        } catch {
            // Keep the events; the next record or flush retries.
            lock.lock()
            pending.insert(contentsOf: batch, at: 0)
            lock.unlock()
        }
    }

    /// Runs on `io`. Reads only what was appended since the last call.
    private func readDisk() throws -> [TrailEvent] {
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { resetCache(inode: 0); return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(.EIO) }
        let inode = UInt64(st.st_ino)
        let size = UInt64(st.st_size)
        if inode != cachedInode || size < cachedOffset || !tailMatches(fd) { resetCache(inode: inode) }

        let decoder = JSONDecoder()
        var offset = cachedOffset
        var carry = Data()
        var tail: [TrailEvent] = []
        let chunk = 1 << 18
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = pread(fd, &buffer, chunk, off_t(offset + UInt64(carry.count)))
            if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            carry.append(contentsOf: buffer[0..<n])
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                if let e = decodeLine(carry[start..<nl], decoder: decoder) { commit(e) }
                offset += UInt64(nl - start + 1)
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        // A last line without a newline is either still being written or torn. Use it if it
        // parses, but don't advance past it: it will be read again once it's complete.
        if !carry.isEmpty, let e = decodeLine(carry[...], decoder: decoder), !cachedIDs.contains(e.id) {
            tail.append(e)
        }
        tailIDs = Set(tail.map(\.id))
        if offset != cachedOffset {
            cachedOffset = offset
            cachedTail = bytes(fd, before: offset)
        }
        return cached + tail
    }

    private func bytes(_ fd: Int32, before offset: UInt64) -> Data {
        let n = Int(min(offset, 64))
        guard n > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: n)
        let got = pread(fd, &buf, n, off_t(offset) - off_t(n))
        return got == n ? Data(buf) : Data()
    }

    private func tailMatches(_ fd: Int32) -> Bool {
        cachedOffset == 0 || bytes(fd, before: cachedOffset) == cachedTail
    }

    private func decodeLine(_ line: Data, decoder: JSONDecoder) -> TrailEvent? {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return nil }
        return try? decoder.decode(TrailEvent.self, from: line)
    }

    private func commit(_ e: TrailEvent) {
        var e = e
        // Hand-written duplicates of an id would break SwiftUI identity.
        while cachedIDs.contains(e.id) { e.id = TrailEvent.derivedID(e.id.uuidString + "+") }
        cachedIDs.insert(e.id)
        cached.append(e)
    }

    private func resetCache(inode: UInt64) {
        cached = []; cachedIDs = []; cachedOffset = 0; cachedInode = inode; cachedTail = Data(); tailIDs = []
    }
}
