import AppKit
import FlamingoCore

/// Flamingo's half of the link to Capybara on another Mac (Capybara's Sources/CapybaraLink has
/// the protocol; the files in Shared/ are copies). Flamingo announces itself and answers:
/// its folder list for Capybara's `[[` picker, a folder's contents, opening a folder or a
/// thought here, and the state of thoughts sent to Capybara, which come back as decisions.
///
/// Thoughts leave this Mac only when you choose Send to Capybara, one at a time, and only to
/// the Capybara you paired with; the link is encrypted end to end (CONTRACT.md).
@MainActor
public final class CapybaraLink {
    public let node: LinkNode
    public let animator = LinkAnimator(side: .flamingo)
    public private(set) var vault: Vault?
    var catalog: FolderCatalog?
    /// Folder id (the `com.flamingo.id` xattr) → path, refreshed when asked to resolve.
    var folderIDs: [String: String] = [:]
    let storage: LinkStorage
    var waitingForCatalog: [(LinkBody) -> Void] = []

    /// What became of thoughts sent to Capybara.
    public struct Sent: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case sent, accepted, rejected }
        public var offer: String
        public var uid: String
        public var peer: String
        public var vaultRoot: String
        public var file: String
        public var title: String
        public var state: State
        public var task: String?
        public var at: Date
    }
    public private(set) var sent: [Sent] = []

    /// A Capybara task pointing at folders here, for the rail.
    public struct TaskRef: Equatable, Sendable {
        public var id: String
        public var title: String
        public var due: String?
        public var done: Bool
        public var folderPaths: [String]
        public var folderIDs: [String]
    }
    public private(set) var tasks: [TaskRef] = []

    // Hooks the app sets.
    /// Show a folder (relative to the vault) and bring Flamingo forward.
    public var revealFolder: ((String) -> Void)?
    /// Show a thought: its file and uid.
    public var revealThought: ((FileRef, String) -> Void)?
    /// Mark a thought done or open through the app (undo, the rail redraws). False: not open
    /// here, so the link writes the note itself.
    public var applyThoughtState: ((FileRef, String, ThoughtState) -> Bool)?
    /// A short line for the toast.
    public var notify: ((String) -> Void)?
    /// Pairing or status changed (the Capybara window and menu redraw).
    public var onChange: (() -> Void)?

    public init(name: String, directory: URL, keychainService: String?) {
        storage = LinkStorage(directory: directory, keychainService: keychainService)
        node = LinkNode(role: .responder, app: "flamingo", name: name, storage: storage)
        loadSent()
        node.onChange = { [weak self] in
            guard let self else { return }
            self.animator.update(self.node.primary)
            self.onChange?()
        }
        node.onRequest = { [weak self] peer, type, body, reply in self?.request(peer, type, body, reply) }
        node.onMessage = { [weak self] peer, type, body in self?.message(peer, type, body) }
        node.onSession = { [weak self] peer in self?.node.request("tasks.refs", [:], to: peer) { _ in } }
    }

    public func start() { node.start() }
    public func stop() { node.stop(); catalog?.stop() }

    /// The vault Flamingo has open: its folders are what Capybara sees.
    public func setVault(_ v: Vault?) {
        guard v != vault else { return }
        vault = v
        catalog?.stop()
        catalog = nil
        folderIDs = [:]
        guard let v else { return }
        let c = FolderCatalog(vault: v)
        c.onReady = { [weak self, weak c] in
            guard let self, let c, self.catalog === c else { return }
            let waiting = self.waitingForCatalog
            self.waitingForCatalog = []
            let full = self.catalogBody(c)
            waiting.forEach { $0(full) }
            // Capybaras already connected get the new vault's folders.
            for p in self.node.storage.peers where self.node.isConnected(p.id) { self.node.send("catalog.full", full, to: p.id) }
        }
        c.onChange = { [weak self, weak c] added, removed, base, hash in
            guard let self, let c, self.catalog === c else { return }
            for p in self.node.storage.peers where self.node.isConnected(p.id) {
                self.node.send("catalog.delta", ["vault": self.vaultID(c.vault), "base": base, "hash": hash, "added": added, "removed": removed], to: p.id)
            }
        }
        catalog = c
        c.start()
    }

    /// The vault's own id, kept on its folder like a file's.
    func vaultID(_ v: Vault) -> String { (try? FileIdentity.id(for: v.root))?.uuidString ?? v.root.path }

    func catalogBody(_ c: FolderCatalog) -> LinkBody {
        ["vault": vaultID(c.vault), "vaultName": c.vault.name, "hash": c.hash, "folders": c.folders]
    }

    // MARK: Requests from Capybara

    func request(_ peer: String, _ type: String, _ body: LinkBody, _ reply: @escaping (LinkBody) -> Void) {
        switch type {
        case "catalog.sync":
            guard let c = catalog else { return reply(["error": "No folder open in Flamingo"]) }
            guard c.ready else { return waitingForCatalog.append(reply) }
            if body.string("vault") == vaultID(c.vault), body.string("hash") == c.hash { return reply(["same": true]) }
            reply(catalogBody(c))
        case "folder.peek":
            guard let v = vault else { return reply(["error": "No folder open in Flamingo"]) }
            let path = resolve(body.string("id"), fallback: body.string("path") ?? "")
            Task.detached(priority: .userInitiated) {
                let out = Self.peek(v, path)
                await MainActor.run { reply(out) }
            }
        case "folder.open":
            guard vault != nil else { return reply(["error": "No folder open in Flamingo"]) }
            if let file = body.string("file"), !file.isEmpty, let uid = body.string("uid"), !uid.isEmpty {
                revealThought?(FileRef(relativePath: file), uid)
            } else {
                revealFolder?(resolve(body.string("id"), fallback: body.string("path") ?? ""))
            }
            NSApp.activate(ignoringOtherApps: true)
            reply(["ok": true])
        case "folder.pin":
            guard let v = vault else { return reply(["error": "No folder open in Flamingo"]) }
            var ids: [String: String] = [:]
            for path in body.strings("paths") {
                let url = path.isEmpty ? v.root : v.url(for: FileRef(relativePath: path))
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                      let id = try? FileIdentity.id(for: url) else { continue }
                ids[path] = id.uuidString
                folderIDs[id.uuidString] = path
            }
            reply(["vault": vaultID(v), "ids": ids])
        case "folder.resolve":
            guard let v = vault, let c = catalog else { return reply(["error": "No folder open in Flamingo"]) }
            let wanted = body.strings("ids")
            let folders = c.folders
            Task.detached(priority: .utility) {
                // Read each folder's id once; a renamed or moved folder keeps its id.
                var map: [String: String] = [:]
                if let root = try? FileIdentity.existingID(for: v.root) { map[root.uuidString] = "" }
                for f in folders {
                    if let id = try? FileIdentity.existingID(atPath: v.url(for: FileRef(relativePath: f)).path) { map[id.uuidString] = f }
                }
                let found = map
                await MainActor.run {
                    self.folderIDs = found
                    var paths: [String: Any] = [:]
                    for id in wanted { paths[id] = found[id] ?? NSNull() }
                    reply(["paths": paths])
                }
            }
        default:
            reply(["error": "Not understood"])
        }
    }

    func resolve(_ id: String?, fallback: String) -> String {
        guard let id, !id.isEmpty else { return fallback }
        if let path = folderIDs[id], vault.map({ path.isEmpty || FileManager.default.fileExists(atPath: $0.url(for: FileRef(relativePath: path)).path) }) == true { return path }
        return fallback
    }

    /// A folder's contents, folders first, and how many thoughts are on what's in it.
    nonisolated static func peek(_ v: Vault, _ path: String) -> LinkBody {
        let fm = FileManager.default
        let dir = path.isEmpty ? v.root : v.url(for: FileRef(relativePath: path))
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return ["error": "Flamingo can't find that folder any more"] }
        let rules = VaultScanner.ignoreRules(in: v)
        let sidecar = SidecarStore(vault: v)
        let withThoughts = Set((try? sidecar.sidecarRefs())?.filter { $0.directory == path || $0.relativePath == path } ?? [])
        var entries: [LinkBody] = []
        var total = 0
        for name in names where !name.hasPrefix(".") && !VaultScanner.isIgnoredName(name) {
            let rel = path.isEmpty ? name : path + "/" + name
            let url = dir.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory == true && values?.isPackage != true && !VaultScanner.isPackage(url)
            guard !rules.isIgnored(rel, isDirectory: isDir) else { continue }
            var e: LinkBody = ["name": name, "dir": isDir]
            if let size = values?.fileSize { e["size"] = size }
            if let m = values?.contentModificationDate { e["modified"] = (m.timeIntervalSince1970 * 1000).rounded() }
            let ref = FileRef(relativePath: rel)
            if withThoughts.contains(ref), let n = try? sidecar.commentCount(for: ref), n > 0 { e["thoughts"] = n; total += n }
            entries.append(e)
        }
        if withThoughts.contains(FileRef(relativePath: path)), let n = try? sidecar.commentCount(for: FileRef(relativePath: path)) { total += n }
        entries.sort { a, b in
            let da = a.bool("dir") == true, db = b.bool("dir") == true
            if da != db { return da }
            return (a.string("name") ?? "").localizedStandardCompare(b.string("name") ?? "") == .orderedAscending
        }
        return ["path": path, "name": path.isEmpty ? v.name : (path as NSString).lastPathComponent, "entries": entries, "thoughts": total]
    }

    // MARK: Messages from Capybara

    func message(_ peer: String, _ type: String, _ body: LinkBody) {
        switch type {
        case "offer.decision":
            guard let id = body.string("offer"), let i = sent.firstIndex(where: { $0.offer == id }) else { return }
            switch body.string("decision") {
            case "accepted":
                sent[i].state = .accepted; sent[i].task = body.string("task")
                notify?("Capybara: “\(Self.short(body.string("title") ?? sent[i].title))” is a task")
            case "rejected":
                sent[i].state = .rejected
                notify?("Capybara rejected “\(Self.short(sent[i].title))”")
            default:
                sent[i].state = .sent; sent[i].task = nil
            }
            saveSent()
            onChange?()
        case "thought.state":
            guard let uid = body.string("uid"), let file = body.string("file"), let s = body.string("state").flatMap(ThoughtState.init(rawValue:)) else { return }
            let record = sent.first { $0.uid == uid }
            let ref = FileRef(relativePath: file)
            if record.map({ URL(fileURLWithPath: $0.vaultRoot).standardizedFileURL }) == vault?.root, applyThoughtState?(ref, uid, s) == true { return }
            // Not open here: write the note directly, the same way the app would.
            guard let root = record?.vaultRoot ?? vault?.root.path else { return }
            let store = SidecarStore(vault: Vault(root: URL(fileURLWithPath: root)))
            _ = try? store.update(uid: uid, in: ref) { c in
                var meta = c.meta ?? ThoughtMeta()
                meta.state = s == .open ? nil : s
                meta.stateAt = ThoughtDates.stamp(Date())
                meta.snoozeUntil = nil
                c.meta = meta
            }
        case "tasks.refs":
            tasks = body.bodies("tasks").map { t in
                let folders = t.bodies("folders")
                return TaskRef(id: t.string("id") ?? "", title: t.string("title") ?? "", due: t.string("due"), done: t.bool("done") ?? false,
                               folderPaths: folders.compactMap { $0.string("path") }, folderIDs: folders.compactMap { $0.string("id") }.filter { !$0.isEmpty })
            }
            onChange?()
        case "catalog.need":
            if let c = catalog, c.ready { node.send("catalog.full", catalogBody(c), to: peer) }
        default:
            break
        }
    }

    // MARK: Sending thoughts

    public enum SendResult { case sent, queued, notPaired }

    /// Sends one thought to the paired Capybara: `file` is the file it's on (or the folder, for a
    /// folder's thought), `folder` where a task made from it should point.
    @discardableResult
    public func send(text: String, uid: String, file: FileRef, folder: String, anchor: String?, due: String?) -> SendResult {
        guard let v = vault, let peer = node.storage.peers.first(where: { $0.app == "capybara" }) else { return .notPaired }
        let offer = LinkWire.newID()
        let title = Self.title(of: text)
        var body: LinkBody = ["offer": offer, "uid": uid, "text": text, "title": title, "file": file.relativePath,
                              "fileName": file.relativePath == folder ? (folder.isEmpty ? v.name : file.name) : file.name,
                              "vault": vaultID(v), "folder": folder, "sent": LinkWire.now()]
        if let anchor { body["anchor"] = anchor }
        if let due { body["due"] = due }
        node.post("offer", body, to: peer.id, id: offer)
        sent.removeAll { $0.uid == uid && $0.state == .sent }
        sent.append(Sent(offer: offer, uid: uid, peer: peer.id, vaultRoot: v.root.path, file: file.relativePath, title: title, state: .sent, at: Date()))
        if sent.count > 500 { sent.removeFirst(sent.count - 500) }
        saveSent()
        onChange?()
        return node.isConnected(peer.id) ? .sent : .queued
    }

    /// What became of the thought with `uid`, if it was sent.
    public func sentState(of uid: String) -> Sent? { sent.last { $0.uid == uid } }

    public var pairedCapybara: LinkPairedPeer? { node.storage.peers.first { $0.app == "capybara" } }

    /// Capybara tasks pointing at `folder` (relative to the vault).
    public func tasks(in folder: String) -> [TaskRef] {
        let id = folderIDs.first { $0.value == folder }?.key
        return tasks.filter { t in t.folderPaths.contains(folder) || id.map { t.folderIDs.contains($0) } == true }
    }

    /// The first line, with `[[links]]` read as their names, at most 120 characters.
    static func title(of text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let out = first.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        return String(out.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    static func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }

    var sentFile: URL { storage.directory.appendingPathComponent("capybara-sent.json") }

    func loadSent() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        sent = (try? Data(contentsOf: sentFile)).flatMap { try? d.decode([Sent].self, from: $0) } ?? []
    }

    func saveSent() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(sent) else { return }
        try? data.write(to: sentFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentFile.path)
    }
}
