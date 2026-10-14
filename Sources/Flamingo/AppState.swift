import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoIndex
import FlamingoTrail
import FlamingoAsk
import FlamingoExtract

/// A request for the preview to move to an anchor once the file is showing.
struct JumpRequest: Equatable {
    let id = UUID()
    let file: FileRef
    let anchor: FileAnchor
}

/// A request for the sidebar to select and scroll to a file it didn't pick itself.
struct RevealRequest: Equatable {
    let id = UUID()
    let file: FileRef
}

/// The active preview, if it can move between anchors (PDF pages, media time).
@MainActor
protocol AnchorNavigator: AnyObject {
    var anchorKind: FileAnchor.Kind { get }
    func step(_ delta: Int)
    func jump(to anchor: FileAnchor)
}

/// One entry in the command palette. Files are matched separately.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let keys: String?
    let symbol: String
    var enabled: Bool = true
    let run: @MainActor () -> Void
}

enum PaletteMode { case commands, search }

/// Single source of truth for the shell. Plan 01 owns.
///
/// `vault`, `files`, `selected`, `anchor`, `mode` are the names CONTRACT.md promises
/// to other sessions; everything else is the shell's own.
@MainActor
final class AppState: ObservableObject {
    // MARK: Contract

    @Published private(set) var vault: Vault?
    @Published private(set) var files: [FileRef] = []
    @Published var selected: FileRef? { didSet { if selected != oldValue { selectionChanged() } } }
    @Published var anchor: FileAnchor? { didSet { if anchor != oldValue { history.updateAnchor(anchor) } } }
    /// Files, Graph, Trail, Ask. The design module's enum, so `SegmentedModes` binds directly.
    typealias Mode = FlamingoMode
    @Published var mode: Mode = .files { didSet { if mode != oldValue { modeChanged() } } }

    // MARK: Shell state

    @Published private(set) var tree = FileTree.empty
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentCounts: [FileRef: Int] = [:]
    @Published private(set) var graph = Graph()
    @Published private(set) var sections: [FlamingoExtract.Section] = []
    /// `nil` when no reindex is running.
    @Published private(set) var indexProgress: Double?
    @Published var railVisible = Defaults.railVisible { didSet { Defaults.railVisible = railVisible } }
    @Published var sidebarWidth = Defaults.sidebarWidth { didSet { Defaults.sidebarWidth = sidebarWidth } }
    @Published private(set) var jumpRequest: JumpRequest?
    @Published private(set) var revealRequest: RevealRequest?
    @Published private(set) var history = History()
    @Published var trailEnabled = TrailStore.isEnabled { didSet { TrailStore.isEnabled = trailEnabled } }

    private(set) var session: VaultSession?
    var askEngine: AskEngine? { session?.ask }
    var trailStore: TrailStore? { session?.trail }

    /// Set by the active preview while it is on screen.
    weak var navigator: AnchorNavigator?
    /// Set by the sidebar so panels can hand keyboard focus back.
    var focusSidebar: (() -> Void)?
    /// The main window. Floating panels parent to it.
    weak var hostWindow: NSWindow?

    private var selectionFromSidebar = false
    private var recordInHistory = true
    private var pendingAnchor: FileAnchor?
    private var openedTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?
    private var graphStale = true
    private var trailObserver: NSObjectProtocol?

    init() {
        trailObserver = NotificationCenter.default.addObserver(
            forName: TrailStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trailChanged() }
        }
    }

    // MARK: Vault

    func open(_ url: URL) {
        let v = Vault(root: url)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: v.root.path, isDirectory: &isDir), isDir.boolValue else {
            Defaults.forgetRecent(url.path)
            MainMenu.refreshRecents()
            return
        }
        if v == vault { rescan(); return }

        session?.stop()
        let s = VaultSession(vault: v)
        session = s
        vault = v
        files = []; tree = .empty
        selected = nil; anchor = nil
        comments = []; commentCounts = [:]; graph = Graph(); sections = []
        history = History()
        graphStale = true
        Defaults.noteRecent(v.root)
        MainMenu.refreshRecents()
        hostWindow?.title = v.name
        hostWindow?.representedURL = v.root
        wireCapture()

        let index = s.index
        s.watcher.onChange = { [weak self] refs in
            // Watcher queue. The index is thread-safe; update it here, then refresh the UI.
            let user = refs.filter { !$0.relativePath.hasPrefix(".flamingo") }
            if !user.isEmpty { try? index?.update(user) }
            Task { @MainActor in self?.filesChanged(user, in: s) }
        }
        s.watcher.onSidecarChange = { [weak self] targets in
            Task { @MainActor in self?.sidecarsChanged(targets, in: s) }
        }

        Task { [weak self] in
            guard let self else { return }
            let (files, tree) = await s.scan()
            guard self.session === s else { return }
            self.tree = tree
            self.files = files
            if let last = Defaults.lastSelected(in: v), files.contains(last) {
                select(last, source: .other)
            } else if let first = files.first {
                select(first, source: .other)
            }
            s.watcher.start()
            await refreshCounts()
            reindex()
        }
    }

    func restoreLastVault() {
        guard vault == nil, let p = Defaults.lastVault else { return }
        open(URL(fileURLWithPath: p))
    }

    func openVaultDialog() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.prompt = "Open"
        if let v = vault { p.directoryURL = v.root.deletingLastPathComponent() }
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url)
    }

    /// Opens a dropped folder as a vault, or selects a dropped file that lives in the vault.
    @discardableResult
    func handleDropped(_ urls: [URL]) -> Bool {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, !VaultScanner.isPackage(url) {
                open(url); return true
            }
            if let v = vault, let ref = v.ref(for: url), files.contains(ref) {
                jump(to: ref, anchor: nil); return true
            }
        }
        return false
    }

    private func rescan() {
        guard let s = session else { return }
        Task {
            let (files, tree) = await s.scan()
            guard self.session === s else { return }
            self.tree = tree
            self.files = files
            if let sel = selected, !files.contains(sel) { selected = nil }
            history.prune(keeping: Set(files))
        }
    }

    private func filesChanged(_ refs: [FileRef], in s: VaultSession) {
        guard session === s else { return }
        rescan()
        let all = refs.contains { $0.relativePath.isEmpty }
        if let sel = selected, all || refs.contains(sel) {
            Task { await refreshSections() }
        }
        Task { await refreshCounts() }
        markGraphStale()
    }

    private func sidecarsChanged(_ targets: [FileRef], in s: VaultSession) {
        guard session === s else { return }
        if let sel = selected, targets.contains(sel) { Task { await refreshComments() } }
        Task { await refreshCounts() }
        markGraphStale()
    }

    private func wireCapture() {
        let cc = CaptureController.shared
        cc.vaults = { [weak self] in [self?.vault].compactMap { $0 } }
        cc.currentTarget = { [weak self] in
            guard let self, let f = self.selected else { return nil }
            return (f, self.anchor)
        }
        cc.onComment = { [weak self] file, comment in
            self?.addComment(comment, to: file)
        }
    }

    // MARK: Selection

    enum SelectionSource { case sidebar, other }

    /// The one way to change what is showing. `anchor` moves the preview once it loads.
    func select(_ ref: FileRef?, anchor: FileAnchor? = nil, source: SelectionSource, record: Bool = true) {
        selectionFromSidebar = source == .sidebar
        recordInHistory = record
        pendingAnchor = anchor
        if ref == selected {
            // Same file: only the anchor moves.
            if let anchor { jumpToAnchor(anchor) }
            if source == .other, let ref { revealRequest = RevealRequest(file: ref) }
        } else {
            selected = ref
        }
        selectionFromSidebar = false
        recordInHistory = true
        pendingAnchor = nil
    }

    private func selectionChanged() {
        anchor = nil
        sections = []
        comments = []
        jumpRequest = nil
        if let v = vault { Defaults.setLastSelected(selected, in: v) }
        guard let ref = selected else {
            openedTask?.cancel()
            return
        }
        if recordInHistory { history.push(History.Entry(file: ref, anchor: pendingAnchor)) }
        if let a = pendingAnchor { jumpToAnchor(a) }
        if !selectionFromSidebar { revealRequest = RevealRequest(file: ref) }
        Task { await refreshComments() }
        Task { await refreshSections() }
        scheduleOpenedEvent(for: ref)
    }

    /// Moves the preview (if it can) and the current anchor. Comment chips land here.
    func jumpToAnchor(_ a: FileAnchor) {
        guard let ref = selected else { return }
        anchor = a
        jumpRequest = JumpRequest(file: ref, anchor: a)
        navigator?.jump(to: a)
    }

    /// From graph, trail, ask, search, or a wikilink: show this file here.
    func jump(to ref: FileRef, anchor: FileAnchor?) {
        mode = .files
        select(ref, anchor: anchor, source: .other)
    }

    /// A clicked wikilink from the rail: `q3.pptx#slide 2` → that file at that anchor.
    func openLink(_ raw: String) {
        guard let v = vault else { return }
        let target = Wikilink.components(of: raw).target
        let anchor = Wikilink.anchor(in: raw)
        let file = selected.flatMap { Wikilink.resolve(target, from: $0, in: v, candidates: files) }
            ?? Wikilink.resolve(target, in: v, candidates: files)
        guard let file else { NSSound.beep(); return }
        jump(to: file, anchor: anchor)
    }

    private func scheduleOpenedEvent(for ref: FileRef) {
        openedTask?.cancel()
        guard let s = session else { return }
        openedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.selected == ref, self.session === s else { return }
            s.trail.recordOpened(ref, anchor: self.anchor)
        }
    }

    // MARK: History

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func goBack() {
        guard let e = history.goBack() else { return }
        mode = .files
        select(e.file, anchor: e.anchor, source: .other, record: false)
    }

    func goForward() {
        guard let e = history.goForward() else { return }
        mode = .files
        select(e.file, anchor: e.anchor, source: .other, record: false)
    }

    /// Trail "resume": the files of a session become the history, oldest first.
    func resume(_ files: [FileRef]) {
        let present = files.filter { self.files.contains($0) }
        guard !present.isEmpty else { return }
        history.replace(with: present)
        mode = .files
        select(present.last, source: .other, record: false)
    }

    // MARK: Anchors

    /// ⌘↑ ⌘↓. The preview moves if it can; otherwise the anchor steps through the
    /// file's indexed sections so a thought can still be left on slide 7.
    func stepAnchor(_ delta: Int) {
        if let navigator {
            navigator.step(delta)
            return
        }
        let anchors = sections.map(\.anchor)
        guard !anchors.isEmpty else { return }
        let i = anchor.flatMap { anchors.firstIndex(of: $0) }
        let next: Int
        if let i { next = min(max(i + delta, 0), anchors.count - 1) } else { next = delta > 0 ? 0 : anchors.count - 1 }
        anchor = anchors[next]
    }

    var hasAnchors: Bool { navigator != nil || !sections.isEmpty }

    // MARK: Modes

    private func modeChanged() {
        if mode == .graph, graphStale { Task { await refreshGraph() } }
    }

    func toggleRail() {
        withAnimation(Theme.Motion.normal) { railVisible.toggle() }
    }

    // MARK: Comments

    func addComment(_ comment: Comment, to file: FileRef) {
        guard let s = session else { return }
        Task {
            do { try await s.append(comment, to: file) } catch { report(error) }
            s.trail.recordComment(comment, on: file)
            await commentsDidChange(for: file, in: s)
        }
    }

    /// Undo of a delete: the same comment comes back with its id and timestamp.
    func restoreComment(_ comment: Comment, to file: FileRef? = nil) {
        guard let s = session, let file = file ?? selected else { return }
        Task {
            do { try await s.append(comment, to: file) } catch { report(error) }
            await commentsDidChange(for: file, in: s)
        }
    }

    func updateComment(_ comment: Comment, in file: FileRef) {
        guard let s = session else { return }
        Task {
            do { try await s.update(comment, in: file) } catch { report(error) }
            await commentsDidChange(for: file, in: s)
        }
    }

    func deleteComment(_ comment: Comment, from file: FileRef) {
        guard let s = session else { return }
        Task {
            do { try await s.delete(comment.id, from: file) } catch { report(error) }
            await commentsDidChange(for: file, in: s)
        }
    }

    private func commentsDidChange(for file: FileRef, in s: VaultSession) async {
        guard session === s else { return }
        if file == selected { await refreshComments() }
        await s.update([file])          // re-ingests the sidecar into the index
        guard session === s else { return }
        await refreshCounts()
        markGraphStale()
    }

    func refreshComments() async {
        guard let s = session, let ref = selected else { comments = []; return }
        let c = await s.comments(for: ref)
        guard session === s, selected == ref else { return }
        comments = c
    }

    private func refreshCounts() async {
        guard let s = session else { return }
        let counts = await s.commentCounts()
        guard session === s else { return }
        commentCounts = counts
    }

    private func refreshSections() async {
        guard let s = session, let ref = selected else { return }
        let secs = await s.sections(of: ref)
        guard session === s, selected == ref else { return }
        sections = secs
    }

    // MARK: Index, graph, trail

    func reindex() {
        guard let s = session, indexProgress == nil else { return }
        indexProgress = 0
        Task { [weak self] in
            await s.reindex { [weak self] p in
                guard let self, self.session === s else { return }
                self.indexProgress = p
            }
            guard let self, self.session === s else { return }
            self.indexProgress = 1
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard self.session === s else { return }
            self.indexProgress = nil
            await self.refreshSections()
            await self.refreshCounts()
            self.markGraphStale()
        }
    }

    /// The graph is rebuilt lazily: now if it is on screen, otherwise next time it is.
    private func markGraphStale() {
        graphStale = true
        guard mode == .graph else { return }
        graphTask?.cancel()
        graphTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshGraph()
        }
    }

    private func trailChanged() {
        markGraphStale()
    }

    func refreshGraph() async {
        guard let s = session else { graph = Graph(); return }
        let g = await s.buildGraph()
        guard session === s else { return }
        graph = g
        graphStale = false
    }

    func search(_ query: String) async -> [SearchHit] {
        guard let s = session else { return [] }
        return await s.search(query)
    }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        session?.trail.recordSearch(q)
    }

    // MARK: File actions

    func url(for ref: FileRef) -> URL? { vault?.url(for: ref) }

    func openExternally(_ ref: FileRef? = nil) {
        guard let url = (ref ?? selected).flatMap(url(for:)) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ ref: FileRef? = nil) {
        guard let url = (ref ?? selected).flatMap(url(for:)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ ref: FileRef? = nil) {
        guard let url = (ref ?? selected).flatMap(url(for:)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// The app that would open this file, for menu titles like "Open in Keynote".
    func defaultAppName(for ref: FileRef?) -> String? {
        guard let url = ref.flatMap(url(for:)), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return (try? app.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? app.deletingPathExtension().lastPathComponent
    }

    func leaveThought() {
        guard vault != nil else { return }
        CaptureController.shared.show()
    }

    func showPalette(_ mode: PaletteMode) {
        PaletteController.shared.show(mode: mode, state: self)
    }

    var captureGlobal: Bool {
        get { CaptureController.shared.isGlobalCaptureEnabled }
        set { CaptureController.shared.isGlobalCaptureEnabled = newValue }
    }

    var captureGlobalKeys: String { CaptureController.shared.globalShortcuts.first ?? "⌃⌥Space" }

    private func report(_ error: Error) {
        FileHandle.standardError.write("flamingo: \(error)\n".data(using: .utf8)!)
    }

    // MARK: Commands (palette)

    var commands: [PaletteCommand] {
        let hasVault = vault != nil
        let hasFile = selected != nil
        var list: [PaletteCommand] = [
            PaletteCommand(id: "open", title: "Open Vault…", keys: "⌘O", symbol: "folder") { [weak self] in self?.openVaultDialog() },
            PaletteCommand(id: "search", title: "Search", keys: "⌘F", symbol: "magnifyingglass", enabled: hasVault) { [weak self] in self?.showPalette(.search) },
            PaletteCommand(id: "thought", title: "Leave a Thought", keys: "⌘⇧C", symbol: "text.bubble", enabled: hasVault) { [weak self] in self?.leaveThought() },
        ]
        for m in Mode.allCases {
            list.append(PaletteCommand(id: m.title.lowercased(), title: m.title, keys: "⌘\(m.rawValue + 1)", symbol: m.symbol, enabled: hasVault) { [weak self] in self?.mode = m })
        }
        list += [
            PaletteCommand(id: "rail", title: railVisible ? "Hide Comments" : "Show Comments", keys: "⌘⌥I", symbol: "sidebar.right") { [weak self] in self?.toggleRail() },
            PaletteCommand(id: "back", title: "Back", keys: "⌘[", symbol: "chevron.left", enabled: canGoBack) { [weak self] in self?.goBack() },
            PaletteCommand(id: "forward", title: "Forward", keys: "⌘]", symbol: "chevron.right", enabled: canGoForward) { [weak self] in self?.goForward() },
            PaletteCommand(id: "prev", title: "Previous Page", keys: "⌘↑", symbol: "arrow.up", enabled: hasAnchors) { [weak self] in self?.stepAnchor(-1) },
            PaletteCommand(id: "next", title: "Next Page", keys: "⌘↓", symbol: "arrow.down", enabled: hasAnchors) { [weak self] in self?.stepAnchor(1) },
            PaletteCommand(id: "openwith", title: "Open in " + (defaultAppName(for: selected) ?? "Default App"), keys: "⌘↩", symbol: "arrow.up.forward.app", enabled: hasFile) { [weak self] in self?.openExternally() },
            PaletteCommand(id: "reveal", title: "Reveal in Finder", keys: "⌘⇧R", symbol: "finder", enabled: hasFile) { [weak self] in self?.revealInFinder() },
            PaletteCommand(id: "copypath", title: "Copy Path", keys: nil, symbol: "doc.on.doc", enabled: hasFile) { [weak self] in self?.copyPath() },
            PaletteCommand(id: "reindex", title: "Reindex Vault", keys: nil, symbol: "arrow.clockwise", enabled: hasVault && indexProgress == nil) { [weak self] in self?.reindex() },
            PaletteCommand(id: "global", title: captureGlobal ? "Stop Capturing From Other Apps" : "Capture From Other Apps", keys: captureGlobalKeys, symbol: "keyboard") { [weak self] in
                self?.captureGlobal.toggle()
            },
            PaletteCommand(id: "trailrec", title: trailEnabled ? "Pause Trail Recording" : "Resume Trail Recording", keys: nil, symbol: "record.circle") { [weak self] in
                self?.trailEnabled.toggle()
            },
        ]
        for path in Defaults.recentVaults where path != vault?.root.path {
            let url = URL(fileURLWithPath: path)
            list.append(PaletteCommand(id: "recent:" + path, title: "Open " + url.lastPathComponent, keys: nil, symbol: "clock") { [weak self] in self?.open(url) })
        }
        return list
    }
}
