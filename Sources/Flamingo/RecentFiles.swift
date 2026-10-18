import AppKit
import FlamingoCore
import FlamingoTrail
import FlamingoExtract
import FlamingoDesign

/// One file in the recents ring.
struct RecentItem: Identifiable, Equatable {
    var file: FileRef
    /// When the trail last saw the file (or the disk did, for an outside edit). `nil` for
    /// fallback entries, whose times are unknown.
    var lastTouched: Date?
    /// Changed on disk after the user last opened it.
    var edited: Bool
    var lastAnchor: FileAnchor?
    var score: Double
    /// The file's disk mtime, for thumbnail freshness.
    var modified: Date?
    var id: String { file.relativePath }
}

/// The ranked recents behind the ⌥⇧ ring and Go → Recent Files. Everything is computed off the
/// main thread, 400 ms after the session's own trail changes; the ring only reads `items`.
/// Held as `state.recents`, not published on `AppState`, so only the ring and the menu observe it.
@MainActor
final class RecentFilesModel: ObservableObject {
    @Published private(set) var items: [RecentItem] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    /// Files to show when the trail has fewer than the ring needs: open tabs, then history,
    /// newest first, with no times. Set by `AppState`.
    var fallback: () -> [FileRef] = { [] }
    var debounce: TimeInterval = 0.4
    /// How many refreshes have completed; tests wait on it.
    private(set) var refreshCount = 0

    nonisolated static let capacity = 24
    nonisolated static let thumbnailCount = 9
    nonisolated static let thumbnailSide: CGFloat = 48

    private var trail: TrailStore?
    private var vault: Vault?
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var thumbnailStamps: [String: Date] = [:]
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    init() {
        observer = NotificationCenter.default.addObserver(forName: TrailStore.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            // Every live store posts, including capture's temporary ones: only our own counts.
            let store = note.object as? TrailStore
            MainActor.assumeIsolated { self?.trailChanged(store) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Binds the model to a session's trail (or detaches it with `nil`) and refreshes.
    func attach(trail: TrailStore?, vault: Vault?) {
        self.trail = trail
        self.vault = vault
        pending?.cancel()
        generation += 1
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks = [:]; thumbnailStamps = [:]
        items = []; thumbnails = [:]
        if trail != nil { refreshSoon(after: 0) }
    }

    private func trailChanged(_ store: TrailStore?) {
        guard let trail, let store, store === trail else { return }
        refreshSoon()
    }

    func refreshSoon(after delay: TimeInterval? = nil) {
        pending?.cancel()
        let wait = delay ?? debounce
        pending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reads the trail and stats files off the main thread, then publishes.
    func refresh() async {
        guard let vault else { return }
        let trail = trail, extra = fallback()
        let mine = generation
        let enabled = TrailStore.isEnabled
        let computed = await Task.detached(priority: .utility) {
            RecentFilesModel.compute(trail: enabled ? trail : nil, vault: vault, fallback: extra, now: Date())
        }.value
        guard mine == generation, !Task.isCancelled else { return }
        refreshCount += 1
        if computed != items { items = computed }
        warmThumbnails(vault: vault)
    }

    /// The ring's files: the best `limit` recents without `excluding`.
    func ring(excluding: FileRef?, limit: Int = 8) -> [RecentItem] {
        Array(items.filter { $0.file != excluding }.prefix(limit))
    }

    /// Pure of model state, so a test can call it directly.
    nonisolated static func compute(trail: TrailStore?, vault: Vault, fallback: [FileRef], now: Date) -> [RecentItem] {
        var out: [RecentItem] = []
        var seen = Set<String>()
        let tuning = RecentsTuning()
        let ranked = (try? trail?.recentFiles(now: now, limit: 40, tuning: tuning)) ?? []
        for r in ranked {
            guard let mtime = modificationDate(vault.url(for: r.file)) else { continue }   // gone
            var touched = r.lastTouched, score = r.score
            var edited = false
            // The only use of disk mtime: a file the user opened, changed since. System churn
            // in files never opened here doesn't count.
            if let opened = r.lastOpened, mtime > opened.addingTimeInterval(2) {
                edited = true
                if mtime > touched {
                    let age = { (d: Date) in max(0, now.timeIntervalSince(d)) }
                    score += tuning.recencyWeight * (pow(2, -age(mtime) / tuning.recencyHalfLife) - pow(2, -age(touched) / tuning.recencyHalfLife))
                    touched = min(mtime, now)
                }
            }
            seen.insert(r.id)
            out.append(RecentItem(file: r.file, lastTouched: touched, edited: edited, lastAnchor: r.lastAnchor, score: score, modified: mtime))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        for file in fallback where out.count < capacity && seen.insert(file.relativePath).inserted {
            guard let mtime = modificationDate(vault.url(for: file)) else { continue }
            out.append(RecentItem(file: file, lastTouched: nil, edited: false, lastAnchor: nil, score: 0, modified: mtime))
        }
        return Array(out.prefix(capacity))
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
              values.isDirectory != true else { return nil }
        return values.contentModificationDate ?? Date.distantPast
    }

    private func warmThumbnails(vault: Vault) {
        for item in items.prefix(Self.thumbnailCount) {
            let path = item.id
            let stamp = item.modified ?? .distantPast
            guard thumbnailStamps[path] != stamp else { continue }
            thumbnailStamps[path] = stamp
            thumbnailTasks[path]?.cancel()
            let mine = generation
            thumbnailTasks[path] = Task { [weak self] in
                let side = Self.thumbnailSide
                let image = await Thumbnails.thumbnail(for: vault.url(for: item.file), in: vault, size: CGSize(width: side, height: side), scale: 2)
                guard let self, mine == self.generation, let image else { return }
                self.thumbnails[path] = image
            }
        }
    }
}

/// Go → Recent Files: the same ranking as the ring, as a menu, so VoiceOver and the keyboard
/// have a route to it and headless QA can run `menu <file name>`. Filled each time it opens.
@MainActor
final class RecentFilesMenu: NSObject, NSMenuDelegate {
    static let title = "Recent Files"
    private weak var state: AppState?

    func install(state: AppState) {
        self.state = state
        let go = NSApp.mainMenu?.items.first { $0.submenu?.title == "Go" }?.submenu
        go?.items.first { $0.title == Self.title }?.submenu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let state else { return }
        for item in state.recents.ring(excluding: state.activePane.file, limit: RecentFilesModel.capacity) {
            let entry = menu.addItem(withTitle: item.file.name, action: #selector(open(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.file.relativePath
            entry.toolTip = item.file.relativePath
            entry.image = FileGlyph.nsImage(ext: item.file.ext, size: 14)
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let state, let path = sender.representedObject as? String else { return }
        let file = FileRef(relativePath: path)
        state.reveal(file, anchor: state.recents.items.first { $0.file == file }?.lastAnchor)
    }
}
