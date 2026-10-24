import Foundation
import CoreServices
import FlamingoCore

/// Every folder in the vault, kept current as folders come and go, so Capybara can hold a copy
/// and find one as fast as you type. Walks once in the background, then follows FSEvents.
/// Folders only: no files, no packages, nothing the vault's ignore rules leave out.
final class FolderCatalog: @unchecked Sendable {
    let vault: Vault
    /// Sorted, relative to the vault. Read on the main queue.
    private(set) var folders: [String] = []
    private(set) var hash = ""
    private(set) var ready = false
    /// Changes after the first walk, on the main queue: what was added and removed, and the
    /// hash before and after.
    var onChange: ((_ added: [String], _ removed: [String], _ base: String, _ hash: String) -> Void)?
    var onReady: (() -> Void)?

    static let limit = 400_000
    private var set: Set<String> = []
    private var rules: IgnoreRules
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "flamingo.link.catalog", qos: .utility)
    private var pending: Set<String> = []
    private var flushScheduled = false

    init(vault: Vault) {
        self.vault = vault
        rules = VaultScanner.ignoreRules(in: vault)
    }

    deinit { stop() }

    static func hash(_ folders: [String]) -> String { LinkIdentity.fingerprint(Data(folders.joined(separator: "\n").utf8)) }

    func start() {
        let root = vault.root, rules = rules
        queue.async { [weak self] in
            let found = Self.walk(root, under: "", rules: rules, limit: Self.limit)
            DispatchQueue.main.async {
                guard let self else { return }
                self.set = Set(found)
                self.folders = found.sorted()
                self.hash = Self.hash(self.folders)
                self.ready = true
                self.watch()
                self.onReady?()
            }
        }
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    /// Folders under `relative` (itself excluded), breadth first, at most `limit`.
    static func walk(_ root: URL, under relative: String, rules: IgnoreRules, limit: Int) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var queue = [relative]
        var i = 0
        while i < queue.count, out.count < limit {
            let rel = queue[i]; i += 1
            let dir = rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where out.count < limit {
                guard !name.hasPrefix("."), !VaultScanner.isIgnoredName(name) else { continue }
                let child = rel.isEmpty ? name : rel + "/" + name
                if allowed(root.appendingPathComponent(child), child, rules: rules) {
                    out.append(child)
                    queue.append(child)
                }
            }
        }
        return out
    }

    /// A real folder (not a file, a symlink or a package) the rules don't exclude.
    static func allowed(_ url: URL, _ relative: String, rules: IgnoreRules) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
              v.isDirectory == true, v.isSymbolicLink != true, v.isPackage != true, !VaultScanner.isPackage(url) else { return false }
        return !rules.isIgnored(relative, isDirectory: true)
    }

    // MARK: Following changes

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderCatalog>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changed: [String] = []
            for i in 0..<min(count, list.count) {
                let f = flags[i]
                let dirEvent = f & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let rescan = f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                if dirEvent || rescan { changed.append(list[i]) }
            }
            if !changed.isEmpty { me.noted(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [vault.root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// On the catalog queue: paths that changed. Gathered, then settled a moment later.
    static let debug = ProcessInfo.processInfo.environment["FLAMINGO_LINK_DEBUG"] != nil

    private func noted(_ paths: [String]) {
        if Self.debug { print("catalog: noted \(paths)") }
        for p in paths { pending.insert(p) }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.settle() }
    }

    private func settle() {
        flushScheduled = false
        let paths = pending
        pending = []
        // FSEvents reports real paths (/private/var/…); the vault may have been opened through a
        // symlink (/var/…), and Foundation drops /private when it tidies a URL, so every
        // spelling of the root counts.
        var roots: Set<String> = [vault.root.path, vault.root.resolvingSymlinksInPath().path]
        if let real = realpath(vault.root.path, nil) { roots.insert(String(cString: real)); free(real) }
        var present: [String: Bool] = [:]
        var subtrees: [String: [String]] = [:]
        for p in paths {
            guard let rootPath = roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { continue }
            var rel = String(p.dropFirst(rootPath.count))
            while rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty, !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") || VaultScanner.isIgnoredName(String($0)) }) else { continue }
            let here = Self.allowed(vault.root.appendingPathComponent(rel), rel, rules: rules)
            present[rel] = here
            // A folder moved or copied in brings its own folders with it.
            if here { subtrees[rel] = Self.walk(vault.root, under: rel, rules: rules, limit: 20_000) }
        }
        DispatchQueue.main.async { [weak self] in self?.apply(present, subtrees) }
    }

    private func apply(_ present: [String: Bool], _ subtrees: [String: [String]]) {
        var added: [String] = [], removed: [String] = []
        for (rel, here) in present {
            if here {
                for f in [rel] + (subtrees[rel] ?? []) where set.count < Self.limit && set.insert(f).inserted { added.append(f) }
            } else if set.contains(rel) {
                let prefix = rel + "/"
                let gone = set.filter { $0 == rel || $0.hasPrefix(prefix) }
                set.subtract(gone)
                removed += gone
            }
        }
        if Self.debug { print("catalog: added \(added) removed \(removed)") }
        guard !added.isEmpty || !removed.isEmpty else { return }
        let base = hash
        folders = set.sorted()
        hash = Self.hash(folders)
        onChange?(added, removed, base, hash)
    }

    func contains(_ relative: String) -> Bool { set.contains(relative) }
}
