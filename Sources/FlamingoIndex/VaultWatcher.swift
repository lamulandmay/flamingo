import Foundation
import CoreServices
import FlamingoCore

/// FSEvents-backed watcher. Coalesces bursts: flushes after 0.55s of quiet, never later than
/// 3s after the first pending event. Callbacks run on the watcher's private background queue;
/// hop to main for UI. Plan 05 owns.
public final class VaultWatcher: @unchecked Sendable {
    public let vault: Vault
    /// Changed files (sidecar targets included), de-duplicated and sorted. An empty
    /// `relativePath` means "rescan everything". Called on a private background queue.
    public var onChange: (([FileRef]) -> Void)?
    /// Targets whose `.flamingo/notes/<target>.md` sidecar changed. Called right after `onChange`
    /// returns, in the same flush, on the same private queue, so an index updated in `onChange`
    /// already holds the new comments (rebuild the graph here).
    public var onSidecarChange: (([FileRef]) -> Void)?

    private let queue = DispatchQueue(label: "com.flamingo.vaultwatcher")
    private static let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
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
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }
        let box = Box(self)
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in _ = Unmanaged<Box>.fromOpaque(info!).retain(); return info },
            release: { info in Unmanaged<Box>.fromOpaque(info!).release() },
            copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            let fl = Array(UnsafeBufferPointer(start: flags, count: count))
            box.watcher?.handle(Array(list.prefix(count)), fl)
        }
        let opts = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [vault.root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, opts) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        lock.unlock()
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// Synchronously delivers anything pending, on the watcher's queue.
    public func flush() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { deliver() } else { queue.sync { deliver() } }
    }

    // MARK: - Event handling (private queue)

    private final class Box {
        weak var watcher: VaultWatcher?
        init(_ w: VaultWatcher) { watcher = w }
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let roots = Self.rootPaths(vault.root)
        var added = false
        for (p, f) in zip(paths, flags) {
            guard let c = classifyAbsolute(p, f, roots: roots) else { continue }
            pending.insert(c.ref.relativePath)
            if c.sidecar { pendingSidecar.insert(c.ref.relativePath) }
            added = true
        }
        if added { schedule() }
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
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            return Classified(ref: FileRef(relativePath: ""), sidecar: false)
        }
        var rel: String?
        for r in roots {
            if path == r || path == r + "/" { rel = ""; break }
            if path.hasPrefix(r + "/") { rel = String(path.dropFirst(r.count + 1)); break }
        }
        guard var rel else { return nil }
        while rel.hasSuffix("/") { rel.removeLast() }
        return Self.classify(relativePath: rel, flags: flags) { [vault, weak self] sub in
            if let hit = self?.packageCache[sub] { return hit }
            let isPkg = (try? vault.root.appendingPathComponent(sub).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            self?.packageCache[sub] = isPkg
            return isPkg
        }
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

    private func deliver() {
        timer?.cancel(); timer = nil
        firstPending = nil
        packageCache.removeAll()
        guard !pending.isEmpty else { return }
        let all = pending.sorted().map { FileRef(relativePath: $0) }
        let side = pendingSidecar.sorted().map { FileRef(relativePath: $0) }
        pending.removeAll(); pendingSidecar.removeAll()
        onChange?(all)
        if !side.isEmpty { onSidecarChange?(side) }
    }

    // MARK: - Pure classification

    struct Classified: Equatable {
        var ref: FileRef
        var sidecar: Bool
    }

    static let packageExtensions: Set<String> = ["key", "numbers", "pages", "app", "bundle", "rtfd", "photoslibrary",
                                                 "logicx", "band", "sparsebundle", "xcodeproj", "playground"]

    /// Maps one event (path relative to the vault root, "" for the root) to the file it affects.
    /// `isPackage` receives the relative path of an ancestor with a path extension.
    static func classify(relativePath: String, flags: FSEventStreamEventFlags,
                         isPackage: (String) -> Bool = { _ in false }) -> Classified? {
        func has(_ f: Int) -> Bool { flags & FSEventStreamEventFlags(f) != 0 }
        let comps = relativePath.split(separator: "/").map(String.init)
        let lost = has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped)
        if has(kFSEventStreamEventFlagRootChanged) { return Classified(ref: FileRef(relativePath: ""), sidecar: false) }

        if comps.first == ".flamingo" {
            guard !lost, comps.count >= 3, comps[1] == "notes", !has(kFSEventStreamEventFlagItemIsDir),
                  !comps.dropFirst(2).contains(where: { $0.hasPrefix(".") }),
                  comps.last!.hasSuffix(".md"), !metadataOnly(flags) else { return nil }
            let target = comps.dropFirst(2).joined(separator: "/").dropLast(3)
            return target.isEmpty ? nil : Classified(ref: FileRef(relativePath: String(target)), sidecar: true)
        }
        if comps.contains(where: { $0.hasPrefix(".") || VaultScanner.ignoredNames.contains($0) }) { return nil }
        if lost { return Classified(ref: FileRef(relativePath: comps.joined(separator: "/")), sidecar: false) }
        if metadataOnly(flags) { return nil }

        for i in comps.indices where (comps[i] as NSString).pathExtension.isEmpty == false {
            let sub = comps[0...i].joined(separator: "/")
            guard packageExtensions.contains((comps[i] as NSString).pathExtension.lowercased()) || isPackage(sub) else { continue }
            if i == comps.count - 1, has(kFSEventStreamEventFlagItemIsDir),
               !(has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)) {
                return nil
            }
            return Classified(ref: FileRef(relativePath: sub), sidecar: false)
        }
        if has(kFSEventStreamEventFlagItemIsDir),
           !(has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)) {
            return nil
        }
        if comps.isEmpty { return nil }
        return Classified(ref: FileRef(relativePath: comps.joined(separator: "/")), sidecar: false)
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
