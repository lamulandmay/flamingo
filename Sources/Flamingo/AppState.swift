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
    /// The sidebar's folder, or the selected file's parent. The graph scopes to it.
    @Published var selectedFolder: String?
    /// Two-finger swipe progress: +1 is a completed back swipe, -1 forward, 0 at rest.
    @Published var swipeAmount: CGFloat = 0
    private var restoringHistory = false
    @Published var anchor: FileAnchor? { didSet { if anchor != oldValue { history.updateAnchor(anchor) } } }
    /// Files, Graph, Trail, Ask. The design module's enum, so `SegmentedModes` binds directly.
    typealias Mode = FlamingoMode
    @Published var mode: Mode = .files { didSet { if mode != oldValue { modeChanged() } } }

    // MARK: Shell state

    @Published private(set) var tree = FileTree.empty
    /// Folders (relative paths) whose listing changed on disk; `""` among them means all.
    /// The sidebar re-lists the ones it has loaded when `treeRevision` moves.
    @Published private(set) var treeRevision = 0
    private(set) var changedFolders: Set<String> = []
    @Published private(set) var pins = Pins()
    /// `files` as a set, for membership on a whole-disk vault.
    private(set) var fileSet: Set<FileRef> = []
    /// Bumped whenever `files` is replaced, so the palette rebuilds its table only then.
    private(set) var filesVersion = 0
    /// `false` until the first full walk of the vault lands; `files` is partial until then.
    private var listed = false
    /// One line over the content with at most one action, such as Undo after an unpin.
    @Published private(set) var toast: ToastMessage?
    private var toastTask: Task<Void, Never>?
    /// `true` when `~/Library/Mail` or `~/Library/Messages` exists but can't be read.
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentCounts: [FileRef: Int] = [:]
    @Published private(set) var graph = Graph()
    @Published private(set) var sections: [FlamingoExtract.Section] = []
    /// `nil` when no reindex is running. The palette shows it; nothing else on screen does,
    /// so it lives outside this object's `objectWillChange` and ticks don't redraw the window.
    let indexing = IndexingModel()
    var indexStatus: VaultSession.IndexStatus? { indexing.status }
    @Published var railVisible = Defaults.railVisible { didSet { Defaults.railVisible = railVisible } }
    /// Set when the user shows the rail on a window too narrow to show it by itself.
    @Published private(set) var railPinned = false
    /// Tracked by the app delegate; the rail hides itself below `narrowWindow` unless pinned.
    @Published var windowWidth: CGFloat = 1200
    static let narrowWindow: CGFloat = 1100

    /// What the layout actually shows: the user's choice, unless the window is too narrow.
    var railShown: Bool { railVisible && (windowWidth >= AppState.narrowWindow || railPinned) }
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
        indexing.status = nil
        let s = VaultSession(vault: v)
        session = s
        vault = v
        VaultScanner.writeDefaultIgnoreFile(in: v)
        pins = Pins.loadOrCreate(in: v)
        listed = false
        setFiles([])
        tree = FileTree(vault: v, pins: pins)
        selected = nil; anchor = nil
        comments = []; commentCounts = [:]; graph = Graph(); sections = []
        history = History()
        graphStale = true
        graphTask?.cancel()
        graphTask = nil
        Defaults.noteRecent(v.root)
        MainMenu.refreshRecents()
        hostWindow?.title = v.name
        hostWindow?.representedURL = v.root
        wireCapture()

        let index = s.index
        s.watcher.onChange = { [weak self] refs in
            // Watcher queue. The index is thread-safe; update it here, then refresh the UI.
            let user = refs.filter { !$0.relativePath.hasPrefix(".flamingo") }
            let fresh = VaultSession.extractable(user, in: v)
            if !fresh.isEmpty { try? index?.update(fresh) }
            Task { @MainActor in self?.filesChanged(user, in: s) }
        }
        s.watcher.onSidecarChange = { [weak self] targets in
            Task { @MainActor in self?.sidecarsChanged(targets, in: s) }
        }

        if let last = Defaults.lastSelected(in: v), v.exists(last) {
            select(last, source: .other)
        }
        s.watcher.start()
        checkFullDiskAccess()
        Task { [weak self] in
            await self?.refreshCounts()
            self?.reindex()
        }
        Task { [weak self] in
            let (files, set) = await s.listFiles { [weak self] partial, members in
                guard let self, self.session === s, !self.listed else { return }
                self.setFiles(partial, set: members)
            }
            guard let self, self.session === s else { return }
            self.listed = true
            self.setFiles(files, set: set)
            if self.selected == nil, let first = self.tree.root.children.lazy.compactMap({ self.firstFile(in: $0) }).first {
                self.select(first, source: .other)
            }
        }
    }

    private func setFiles(_ list: [FileRef], set: Set<FileRef>? = nil) {
        // Freeing a whole disk's worth of paths takes a few hundred ms; not on this thread.
        let old = (files, fileSet)
        files = list
        fileSet = set ?? Set(list)
        filesVersion &+= 1
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(old) {} }
        Log.debug("files: \(list.count)\(listed ? "" : " so far")")
    }

    /// The first file in the sidebar's order under `node`, without listing deeper than needed.
    private func firstFile(in node: FileNode, depth: Int = 0) -> FileRef? {
        guard depth < 4 else { return nil }
        let kids = tree.load(node)
        if let f = kids.first(where: { !$0.isFolder })?.ref { return f }
        for k in kids where k.isFolder { if let f = firstFile(in: k, depth: depth + 1) { return f } }
        return nil
    }

    private func checkFullDiskAccess() {
        Task { [weak self] in
            let blocked = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                return ["Library/Mail", "Library/Messages"].contains { sub in
                    let url = home.appendingPathComponent(sub)
                    guard FileManager.default.fileExists(atPath: url.path) else { return false }
                    return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil
                }
            }.value
            self?.needsFullDiskAccess = blocked
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The last vault, or on first launch the home folder.
    func restoreLastVault() {
        guard vault == nil else { return }
        open(Defaults.lastVault.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func openVaultDialog() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.showsHiddenFiles = true
        p.prompt = "Open"
        // At the top of the disk, so `/` itself is one click and the home folder is two.
        p.directoryURL = URL(fileURLWithPath: "/")
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url)
    }

    // MARK: Pins

    /// "Pin Folder…": any folder inside the vault, hidden ones included.
    func pinFolderDialog() {
        guard let v = vault else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.showsHiddenFiles = true
        p.prompt = "Pin"
        p.directoryURL = v.root
        guard p.runModal() == .OK else { return }
        var pinned = false
        for url in p.urls { pinned = pin(url) || pinned }
        if !pinned { NSSound.beep() }
    }

    /// Pins a folder given by URL. `false` when it is outside the vault or not a folder.
    @discardableResult
    func pin(_ url: URL, at index: Int? = nil) -> Bool {
        guard let v = vault, let rel = v.relativePath(of: url) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              !VaultScanner.isPackage(url), !v.isState(url) else { return false }
        pin(path: rel, at: index)
        return true
    }

    /// Pins the folder at `path`; an existing pin moves to `index` instead.
    func pin(path: String, at index: Int? = nil) {
        var p = pins
        if let from = p.paths.firstIndex(of: path) {
            guard let index else { return }
            p.move(from: from, to: index > from ? index - 1 : index)
        } else {
            p.pin(path, at: index)
        }
        savePins(p)
    }

    /// No confirmation; the toast (and ⌘Z) puts it back where it was.
    func unpin(path: String) {
        var p = pins
        guard let index = p.unpin(path) else { return }
        savePins(p)
        let name = path.isEmpty ? (vault?.name ?? path) : (path as NSString).lastPathComponent
        let restore: () -> Void = { [weak self] in
            guard let self else { return }
            var p = self.pins
            p.pin(path, at: index)
            self.savePins(p)
            self.dismissToast()
        }
        hostWindow?.undoManager?.registerUndo(withTarget: self) { _ in MainActor.assumeIsolated { restore() } }
        hostWindow?.undoManager?.setActionName("Unpin")
        showToast(ToastMessage(text: "Unpinned " + name, action: "Undo", perform: restore))
    }

    func movePin(from: Int, to: Int) {
        var p = pins
        p.move(from: from, to: to)
        savePins(p)
    }

    private func savePins(_ new: Pins) {
        guard let v = vault, new != pins else { return }
        pins = new
        try? new.save(in: v)
        tree = FileTree(vault: v, pins: new)
    }

    // MARK: Toast

    func showToast(_ message: ToastMessage) {
        toastTask?.cancel()
        withAnimation(Theme.Motion.fast) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(Theme.Motion.fast) { toast = nil }
    }

    /// A dropped folder inside the vault is pinned; one outside it opens as the vault. A
    /// dropped file inside the vault is shown.
    @discardableResult
    func handleDropped(_ urls: [URL]) -> Bool {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, !VaultScanner.isPackage(url) {
                if vault?.contains(url) == true { pin(url) } else { open(url) }
                return true
            }
            if let v = vault, let ref = v.ref(for: url), v.exists(ref) {
                jump(to: ref, anchor: nil); return true
            }
        }
        return false
    }

    /// The whole file list again, after the watcher lost events or the rules changed.
    private func rescan() {
        guard let s = session else { return }
        Task {
            let (files, set) = await s.listFiles()
            guard self.session === s else { return }
            self.setFiles(files, set: set)
            if let sel = selected, !vault!.exists(sel) { selected = nil }
            history.prune(keeping: fileSet)
        }
    }

    /// Patches `files` and the sidebar's loaded folders for what the watcher saw, without
    /// walking the vault again (unless it asks for everything).
    private func applyDiskChanges(_ refs: [FileRef], in s: VaultSession) {
        if refs.contains(where: { $0.relativePath.isEmpty }) {
            tree.reloadRules()
            noteFoldersChanged([""])
            rescan()
            return
        }
        noteFoldersChanged(Set(refs.map(\.directory)).union(refs.map(\.relativePath)))
        Task {
            guard let (list, set) = await s.applyDiskChanges(refs), self.session === s else { return }
            let gone = selected.map { !set.contains($0) } ?? false
            setFiles(list, set: set)
            if gone, let sel = selected, !vault!.exists(sel) { selected = nil }
        }
    }

    private func noteFoldersChanged(_ folders: Set<String>) {
        changedFolders = folders
        treeRevision &+= 1
    }

    private func filesChanged(_ refs: [FileRef], in s: VaultSession) {
        guard session === s else { return }
        applyDiskChanges(refs, in: s)
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
        if recordInHistory {
            history.push(History.Entry(file: ref, anchor: pendingAnchor, mode: mode, folder: selectedFolder, transient: selectionFromSidebar))
        }
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
        restore(e)
    }

    func goForward() {
        guard let e = history.goForward() else { return }
        restore(e)
    }

    /// Puts the app back the way an entry saw it: folder, mode, then file and anchor.
    private func restore(_ e: History.Entry) {
        restoringHistory = true
        defer { restoringHistory = false }
        if selectedFolder != e.folder { selectedFolder = e.folder }
        if mode != e.mode { mode = e.mode }
        if let f = e.file {
            select(f, anchor: e.anchor, source: .other, record: false)
        } else if selected != nil {
            select(nil, source: .other, record: false)
        }
    }

    /// The sidebar's selection in one step: the folder (a folder row, or the file's parent)
    /// and the file, so a folder-only selection is one history entry rather than two.
    func selectFromSidebar(folder: String?, file: FileRef?) {
        if selectedFolder != folder { selectedFolder = folder }
        if file == nil, selected == nil, !restoringHistory {
            history.push(History.Entry(file: nil, anchor: nil, mode: mode, folder: folder, transient: true))
        }
        select(file, source: .sidebar)
    }

    /// Trail "resume": the files of a session become the history, oldest first.
    func resume(_ files: [FileRef]) {
        let present = files.filter { self.fileSet.contains($0) || self.vault?.exists($0) == true }
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
        if !restoringHistory {
            history.push(History.Entry(file: selected, anchor: anchor, mode: mode, folder: selectedFolder))
        }
        if mode == .graph, graphStale { graphTask?.cancel(); graphTask = nil; Task { await refreshGraph() } }
    }

    func toggleRail() {
        withAnimation(Theme.Motion.normal) {
            if railShown {
                railVisible = false
                railPinned = false
            } else {
                railVisible = true
                railPinned = windowWidth < AppState.narrowWindow
            }
        }
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
        markGraphStale(urgent: true)
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

    /// Incremental at launch and after changes; `force` (the menu command) re-extracts everything.
    func reindex(force: Bool = false) {
        guard let s = session, indexStatus == nil else { return }
        indexing.status = VaultSession.IndexStatus(fraction: force ? 0 : nil)
        Task { [weak self] in
            await s.reindex(force: force) { [weak self] status in
                guard let self, self.session === s, self.indexStatus != nil else { return }
                self.indexing.status = status
            }
            guard let self, self.session === s else { return }
            self.indexing.status = nil
            self.tree.reloadRules()
            await self.refreshSections()
            await self.refreshCounts()
            self.markGraphStale()
        }
    }

    /// The graph feeds Graph mode and the local graph under the rail, so it is rebuilt
    /// whenever it goes stale, coalescing bursts; at once when Graph mode is on screen. A
    /// whole disk changes every few seconds, so there files changing on disk rebuild it at
    /// most every `slowGraphDelay`; a thought (`urgent`) still shows within a second or two.
    private func markGraphStale(urgent: Bool = false) {
        graphStale = true
        let slow = !urgent && mode != .graph && files.count > Self.bigVault
        if slow, graphTask != nil { return }
        graphTask?.cancel()
        let delay: UInt64 = mode == .graph ? 300_000_000 : slow ? Self.slowGraphDelay : 1_500_000_000
        graphTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.graphTask = nil
            await self.refreshGraph()
        }
    }

    /// Above this many files the vault is a disk, not a project.
    static let bigVault = 50_000
    static let slowGraphDelay: UInt64 = 30_000_000_000

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

    /// The local vision model leaves its description as a thought on the image.
    func describeImage(_ ref: FileRef) {
        guard let s = session, let engine = s.ask else { return }
        showToast(ToastMessage(text: "Describing " + ref.name))
        Task {
            do {
                try await engine.describe(ref)
                dismissToast()
            } catch {
                showToast(ToastMessage(text: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            }
            await commentsDidChange(for: ref, in: s)
        }
    }

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
            PaletteCommand(id: "rail", title: railShown ? "Hide Comments" : "Show Comments", keys: "⌘⌥I", symbol: "sidebar.right") { [weak self] in self?.toggleRail() },
            PaletteCommand(id: "back", title: "Back", keys: "⌘[", symbol: "chevron.left", enabled: canGoBack) { [weak self] in self?.goBack() },
            PaletteCommand(id: "forward", title: "Forward", keys: "⌘]", symbol: "chevron.right", enabled: canGoForward) { [weak self] in self?.goForward() },
            PaletteCommand(id: "prev", title: "Previous Page", keys: "⌘↑", symbol: "arrow.up", enabled: hasAnchors) { [weak self] in self?.stepAnchor(-1) },
            PaletteCommand(id: "next", title: "Next Page", keys: "⌘↓", symbol: "arrow.down", enabled: hasAnchors) { [weak self] in self?.stepAnchor(1) },
            PaletteCommand(id: "openwith", title: "Open in " + (defaultAppName(for: selected) ?? "Default App"), keys: "⌘↩", symbol: "arrow.up.forward.app", enabled: hasFile) { [weak self] in self?.openExternally() },
            PaletteCommand(id: "reveal", title: "Reveal in Finder", keys: "⌘⇧R", symbol: "finder", enabled: hasFile) { [weak self] in self?.revealInFinder() },
            PaletteCommand(id: "copypath", title: "Copy Path", keys: nil, symbol: "doc.on.doc", enabled: hasFile) { [weak self] in self?.copyPath() },
            PaletteCommand(id: "pin", title: "Pin Folder…", keys: nil, symbol: "pin", enabled: hasVault) { [weak self] in self?.pinFolderDialog() },
            PaletteCommand(id: "reindex", title: "Reindex Vault", keys: nil, symbol: "arrow.clockwise", enabled: hasVault && indexStatus == nil) { [weak self] in self?.reindex(force: true) },
            PaletteCommand(id: "global", title: captureGlobal ? "Stop Capturing From Other Apps" : "Capture From Other Apps", keys: captureGlobalKeys, symbol: "keyboard") { [weak self] in
                self?.captureGlobal.toggle()
            },
            PaletteCommand(id: "trailrec", title: trailEnabled ? "Pause Trail Recording" : "Resume Trail Recording", keys: nil, symbol: "record.circle") { [weak self] in
                self?.trailEnabled.toggle()
            },
        ]
        let provider = AskProvider.preferred
        if provider != .llama {
            list.append(PaletteCommand(id: "asklocal", title: "Ask: Use Local Model", keys: nil, symbol: "desktopcomputer") {
                AskProvider.preferred = .llama
            })
        }
        if provider != .claude {
            list.append(PaletteCommand(id: "askclaude", title: "Ask: Use Claude", keys: nil, symbol: "cloud") {
                AskProvider.preferred = .claude
            })
        }
        if let ref = selected, FileFamily(ext: ref.ext) == .image {
            list.append(PaletteCommand(id: "describe", title: "Describe Image", keys: nil, symbol: "eye", enabled: askEngine != nil) { [weak self] in
                self?.describeImage(ref)
            })
        }
        if needsFullDiskAccess {
            list.append(PaletteCommand(id: "fda", title: "Grant Full Disk Access", keys: nil, symbol: "lock.open") { [weak self] in
                self?.openFullDiskAccessSettings()
            })
        }
        for (path, title) in Defaults.recentVaultTitles() where path != vault?.root.path {
            let url = URL(fileURLWithPath: path)
            list.append(PaletteCommand(id: "recent:" + path, title: "Open " + title, keys: nil, symbol: "clock") { [weak self] in self?.open(url) })
        }
        return list
    }
}

/// What `AppState.toast` shows: one line and at most one action.
struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    var action: String?
    var perform: (() -> Void)?
}

/// Reindex progress, observed by the palette only.
@MainActor
final class IndexingModel: ObservableObject {
    @Published var status: VaultSession.IndexStatus?
}
