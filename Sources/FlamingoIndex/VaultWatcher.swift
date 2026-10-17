import Foundation
import CoreServices
import FlamingoCore

/// FSEvents-backed watcher. Coalesces bursts: flushes after 0.55s of quiet, never later than
/// 3s after the first pending event. Callbacks run on the watcher's private background queue;
/// hop to main for UI. Plan 05 owns.
public final class VaultWatcher: @unchecked Sendable {
    public let vault: Vault
    /// Changed files (sidecar targets included), de-duplicated and sorted. An empty
    /// `relativePath` means "rescan everything" (the vault moved, events were dropped, or
    /// `.flamingoignore` changed). Called on a private background queue.
    public var onChange: (([FileRef]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }
    /// Targets whose `.flamingo/notes/<target>.md` sidecar changed. Called right after `onChange`
    /// returns, in the same flush, on the same private queue, so an index updated in `onChange`
    /// already holds the new comments (rebuild the graph here).
    public var onSidecarChange: (([FileRef]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sidecarHandler }
        set { lock.lock(); sidecarHandler = newValue; lock.unlock() }
    }
    /// After `start(since:)`: called once, on the private queue, when `onChange` has been
    /// handed every change recorded before the stream started. Never called by `start()`.
    public var onHistoryDone: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return historyHandler }
        set { lock.lock(); historyHandler = newValue; lock.unlock() }
    }
    /// Read inside `onChange`: the FSEvents id that batch reaches. Every event up to it is in
    /// this batch or an earlier one, so once the batch is applied, a later `start(since:)`
    /// may resume from it. Nil while history replays, since replayed events come in path
    /// order rather than id order.
    public var deliveredThrough: UInt64? { lock.lock(); defer { lock.unlock() }; return through }

    /// Stands in for every note in `onChange` and `onSidecarChange` when FSEvents lost events
    /// under `.flamingo/notes`: re-read the notes, not the whole vault.
    public static let allNotes = FileRef(relativePath: ".flamingo/notes")

    /// The newest event FSEvents has recorded on any volume.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the FSEvents history of the volume holding `url`. Event ids from a
    /// different history (a reformatted volume, a reset log) mean nothing here.
    public static func historyID(for url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private let queue = DispatchQueue(label: "com.flamingo.vaultwatcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var changeHandler: (([FileRef]) -> Void)?
    private var sidecarHandler: (([FileRef]) -> Void)?
    private var historyHandler: (() -> Void)?
    private var through: UInt64?
    /// Newest event id seen, and whether replayed history is still arriving (private queue).
    private var newestEvent: UInt64 = 0
    private var replaying = false
    private var historyFinished = false
    private var rules: PathRules
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var pendingSidecar = Set<String>()
    private var firstPending: Date?
    private var timer: DispatchWorkItem?
    private var packageCache: [String: Bool] = [:]

    static let quiet: TimeInterval = 0.55
    static let maxDelay: TimeInterval = 3

    public init(vault: Vault) {
        self.vault = vault
        rules = PathRules(vault: vault)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil }

    /// Watches from now on, or replays every change since the event id `since` first (then
    /// keeps watching). A replay ends with `onHistoryDone`.
    public func start(since: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }
        let box = Box(self)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in _ = Unmanaged<Box>.fromOpaque(info!).retain(); return info },
            release: { info in Unmanaged<Box>.fromOpaque(info!).release() },
            copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            let fl = Array(UnsafeBufferPointer(start: flags, count: count))
            box.watcher?.handle(Array(list.prefix(count)), fl, Array(UnsafeBufferPointer(start: ids, count: count)))
        }
        let opts = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [vault.root.path] as CFArray,
                                          since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, opts) else { return }
        // Set before the stream can call back on `queue`; `through` stays nil until history is done.
        let replay = since != nil
        through = nil
        queue.async { [weak self] in
            self?.replaying = replay; self?.historyFinished = false
            self?.newestEvent = replay ? since! : FSEventsGetCurrentEventId()
        }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    /// Stops the stream and drops anything not yet delivered: no new callback starts after this.
    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        queue.async { [weak self] in self?.discardPending() }
    }

    /// Synchronously delivers anything pending, on the watcher's queue.
    public func flush() { onQueue { deliver() } }

    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    // MARK: - Event handling (private queue)

    private final class Box {
        weak var watcher: VaultWatcher?
        init(_ w: VaultWatcher) { watcher = w }
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags], _ ids: [FSEventStreamEventId] = []) {
        let roots = Self.rootPaths(vault.root)
        if paths.contains(where: { $0.hasSuffix("/" + IgnoreRules.fileName) || $0.hasSuffix("/.flamingo/ignore") }) { rules = PathRules(vault: vault) }
        var added = false
        for (i, (p, f)) in zip(paths, flags).enumerated() {
            if i < ids.count { newestEvent = max(newestEvent, ids[i]) }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                replaying = false; historyFinished = true; added = true
                continue
            }
            guard let c = classifyAbsolute(p, f, roots: roots) else { continue }
            if c.sidecar, c.ref != Self.allNotes, isFolder(c.ref) {
                // A thought on a folder: re-read the notes, not the folder (which could be most of the vault).
                pending.insert(Self.allNotes.relativePath)
            } else {
                pending.insert(c.ref.relativePath)
            }
            if c.sidecar { pendingSidecar.insert(c.ref.relativePath) }
            added = true
        }
        if added { schedule() }
    }

    private func isFolder(_ ref: FileRef) -> Bool {
        let url = vault.url(for: ref)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue && !VaultScanner.isPackage(url)
    }

    /// Spellings of the root FSEvents may report: as given, symlink-resolved (`/private/var`), and the
    /// `/private`-stripped form Foundation prefers.
    static func rootPaths(_ root: URL) -> Set<String> {
        var out: Set<String> = [root.path, root.resolvingSymlinksInPath().path]
        if let r = realpath(root.path, nil) { out.insert(String(cString: r)); free(r) }
        for p in out where p.hasPrefix("/private/") { out.insert(String(p.dropFirst(8))) }
        return out
    }

    private func classifyAbsolute(_ path: String, _ flags: FSEventStreamEventFlags, roots: Set<String>) -> Classified? {
        // Ids wrapped: nothing before this point can be told apart any more.
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            return Classified(ref: FileRef(relativePath: ""), sidecar: false)
        }
        guard let rel = Self.relativePath(path, roots: roots) else { return nil }
        return Self.classify(relativePath: rel, flags: flags, isPackage: { [vault, weak self] sub in
            if let hit = self?.packageCache[sub] { return hit }
            let isPkg = (try? vault.root.appendingPathComponent(sub).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            self?.packageCache[sub] = isPkg
            return isPkg
        }, rules: rules)
    }

    static func relativePath(_ path: String, roots: Set<String>) -> String? {
        for root in roots.sorted(by: { $0.count > $1.count }) {
            if path == root || path == root + "/" { return "" }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        }
        return nil
    }

    private func schedule() {
        let now = Date()
        if firstPending == nil { firstPending = now }
        let delay = max(0, min(Self.quiet, firstPending!.addingTimeInterval(Self.maxDelay).timeIntervalSince(now)))
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.deliver() }
        timer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func discardPending() {
        timer?.cancel(); timer = nil
        firstPending = nil
        pending.removeAll(); pendingSidecar.removeAll()
        historyFinished = false
    }

    private func deliver() {
        guard isRunning else { return discardPending() }
        timer?.cancel(); timer = nil
        firstPending = nil
        packageCache.removeAll()
        let finished = historyFinished
        historyFinished = false
        guard !pending.isEmpty || finished else { return }
        let all = pending.sorted().map { FileRef(relativePath: $0) }
        let side = pendingSidecar.sorted().map { FileRef(relativePath: $0) }
        pending.removeAll(); pendingSidecar.removeAll()
        lock.lock()
        let (change, sidecar, history) = (changeHandler, sidecarHandler, historyHandler)
        through = replaying ? nil : newestEvent
        lock.unlock()
        if !all.isEmpty {
            change?(all)
            if !side.isEmpty { sidecar?(side) }
        }
        if finished { history?() }
    }

    // MARK: - Pure classification

    struct Classified: Equatable {
        var ref: FileRef
        var sidecar: Bool
    }

    static var packageExtensions: Set<String> { VaultScanner.packageExtensions }

    /// Maps one event (path relative to the vault root, "" for the root) to the file it affects,
    /// or `nil` when `VaultScanner` wouldn't list it. `isPackage` receives the relative path of
    /// an ancestor with a path extension.
    static func classify(relativePath: String, flags: FSEventStreamEventFlags,
                         isPackage: (String) -> Bool = { _ in false },
                         rules: PathRules = PathRules(ignore: .empty)) -> Classified? {
        func has(_ f: Int) -> Bool { flags & FSEventStreamEventFlags(f) != 0 }
        let comps = relativePath.split(separator: "/").map(String.init)
        let lost = has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped)
        let everything = Classified(ref: FileRef(relativePath: ""), sidecar: false)
        if has(kFSEventStreamEventFlagRootChanged) { return everything }

        if comps == [".flamingo", "ignore"] { return metadataOnly(flags) ? nil : everything }
        if comps.first == ".flamingo" {
            // Sidecar edits may be lost: re-read the notes. Never the whole vault, which on a
            // home folder is an hour of work for a few lost writes to our own state folder.
            if lost { return comps.count == 1 || comps[1] == "notes" ? Classified(ref: allNotes, sidecar: true) : nil }
            guard comps.count >= 3, comps[1] == "notes", !has(kFSEventStreamEventFlagItemIsDir),
                  comps.last!.hasSuffix(".md"), !metadataOnly(flags) else { return nil }
            let target = comps.dropFirst(2).joined(separator: "/").dropLast(3)
            return target.isEmpty ? nil : Classified(ref: FileRef(relativePath: String(target)), sidecar: true)
        }
        if comps == [IgnoreRules.fileName] { return metadataOnly(flags) ? nil : everything }   // new rules: rescan
        if comps.contains(where: { VaultScanner.isIgnoredName($0) }) { return nil }
        if let first = comps.first, VaultScanner.rootOnlyIgnoredNames.contains(first) { return nil }
        if lost { return Classified(ref: FileRef(relativePath: comps.joined(separator: "/")), sidecar: false) }
        if metadataOnly(flags) { return nil }

        for i in comps.indices where (comps[i] as NSString).pathExtension.isEmpty == false {
            let sub = comps[0...i].joined(separator: "/")
            guard packageExtensions.contains((comps[i] as NSString).pathExtension.lowercased()) || isPackage(sub) else { continue }
            if i == comps.count - 1, has(kFSEventStreamEventFlagItemIsDir),
               !(has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)) {
                return nil
            }
            return rules.ignore.isIgnored(sub, isDirectory: false) ? nil : Classified(ref: FileRef(relativePath: sub), sidecar: false)
        }
        if has(kFSEventStreamEventFlagItemIsDir),
           !(has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)) {
            return nil
        }
        if comps.isEmpty { return nil }
        let path = comps.joined(separator: "/")
        if rules.ignore.isIgnored(path, isDirectory: has(kFSEventStreamEventFlagItemIsDir)) { return nil }
        return Classified(ref: FileRef(relativePath: path), sidecar: false)
    }

    private static func metadataOnly(_ flags: FSEventStreamEventFlags) -> Bool {
        func has(_ f: Int) -> Bool { flags & FSEventStreamEventFlags(f) != 0 }
        let noise = has(kFSEventStreamEventFlagItemXattrMod) || has(kFSEventStreamEventFlagItemFinderInfoMod)
            || has(kFSEventStreamEventFlagItemChangeOwner)
        let real = has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
            || has(kFSEventStreamEventFlagItemRenamed) || has(kFSEventStreamEventFlagItemModified)
            || has(kFSEventStreamEventFlagItemInodeMetaMod)
        return noise && !real
    }
}
