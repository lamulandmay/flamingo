import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoIndex
import FlamingoTrail
import FlamingoAsk
import FlamingoExtract
import FlamingoGraph

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
    /// For a folder: open it as well.
    var expand = false
    /// The user asked for it (rather than the selection moving), so it reveals even with
    /// auto-reveal off.
    var force = false
    /// "Reveal current file": the row is brought to the middle and pulses.
    var pulse = false
}

/// A row to rename in place: a vault-relative path in the file explorer, a bookmark's
/// `ctime` in the bookmarks.
struct RenameRequest: Equatable {
    let id = UUID()
    let tab: SidebarTab
    let target: String
    /// A new folder made while the columns are on screen: they rename it, not the sidebar.
    var inColumns = false
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
    let actionHistory: ActionHistory
    var suppressActionHistory = false

    // MARK: Contract

    @Published private(set) var vault: Vault?
    @Published private(set) var files: [FileRef] = []
    @Published var selected: FileRef? { didSet {
        if selected != oldValue, !synchronizingPane { activePane.show(selected); selectionChanged() }
    } }
    /// The sidebar's folder, or the selected file's parent. The graph scopes to it.
    @Published var selectedFolder: String?
    /// Divider widths and window width: per-frame geometry, observed only by the layout so
    /// dragging a divider doesn't redraw every view reading this object.
    let layout = PanelLayout()
    /// Two-finger swipe progress and the arrival after one, observed only by the content's
    /// `SwipeFollow`, so a swipe's frames don't redraw the layout either.
    let swipe = SwipeMotion()
    /// +1 is a completed back swipe, -1 forward, 0 at rest.
    var swipeAmount: CGFloat {
        get { swipe.amount }
        set { swipe.amount = newValue }
    }
    private var restoringHistory = false
    var openingVault = false
    @Published var anchor: FileAnchor? { didSet {
        if anchor != oldValue, !synchronizingPane {
            if activePane.anchor != anchor { activePane.anchor = anchor }
            history.updateAnchor(anchor)
            if let selected, let anchor { savedAnchors[selected.relativePath] = anchor }
            // Pages turn, media plays and carets move many times a second: save once it rests.
            persistWorkspaceSoon()
        }
    } }
    /// Files, Graph, Trail, Ask. The design module's enum, so `SegmentedModes` binds directly.
    typealias Mode = FlamingoMode
    @Published var mode: Mode = .files { didSet {
        // Chat lives in the right sidebar now, reachable from every mode: ⌘4, menus and
        // restored history that still say "ask" open it there instead of replacing the view.
        if mode == .ask { mode = oldValue == .ask ? .files : oldValue; focusChat(); return }
        if mode != oldValue { modeChanged(); recordSetting("Change View", before: oldValue, after: mode) { [weak self] in self?.mode = $0 } }
    } }

    // MARK: Shell state

    @Published private(set) var tree = FileTree.empty
    /// Folders (relative paths) whose listing changed on disk; `""` among them means all.
    /// The sidebar re-lists the ones it has loaded when `treeRevision` moves.
    @Published private(set) var treeRevision = 0
    private(set) var changedFolders: Set<String> = []
    /// `.flamingo/bookmarks.json`: files, folders, searches and groups, Obsidian's format.
    @Published private(set) var bookmarks = Bookmarks()
    @Published private(set) var bookmarksError: String?
    /// The left sidebar: which tab shows, whether the panel beside the ribbon is open, and
    /// the file explorer's order and auto-reveal toggle.
    @Published var sidebarTab = Defaults.sidebarTab { didSet { Defaults.sidebarTab = sidebarTab; recordSetting("Change Sidebar", before: oldValue, after: sidebarTab) { [weak self] in self?.sidebarTab = $0 } } }
    @Published var sidebarCollapsed = Defaults.sidebarCollapsed { didSet { Defaults.sidebarCollapsed = sidebarCollapsed; if !sidebarCollapsed { tiling.userOpened(.sidebar) } } }
    @Published var fileSort = Defaults.fileSort {
        didSet {
            guard fileSort != oldValue else { return }
            recordSetting("Sort Files", before: oldValue, after: fileSort) { [weak self] in self?.fileSort = $0 }
            Defaults.fileSort = fileSort
            if let v = vault { tree = FileTree(vault: v, sort: fileSort) }
        }
    }
    @Published var autoReveal = Defaults.autoReveal {
        didSet {
            recordSetting("Auto Reveal", before: oldValue, after: autoReveal) { [weak self] in self?.autoReveal = $0 }
            Defaults.autoReveal = autoReveal
            if autoReveal, let f = selected { revealRequest = RevealRequest(file: f, force: true) }
        }
    }
    /// "Collapse all" in the file explorer or the bookmarks, by tab.
    @Published private(set) var collapseRequest: (tab: SidebarTab, id: UUID)?
    /// A row the file explorer or the bookmarks should start renaming in place.
    @Published private(set) var renameRequest: RenameRequest?
    /// The current file, while its name in the title is being edited (`renameInTitle`).
    @Published var renamingTitle: FileRef?
    /// The search tab's query and results; kept here so they survive switching tabs.
    let sidebarSearch = SidebarSearchModel()
    /// The search results list in the content area (SearchResults.swift).
    let searchResults = SearchResultsModel()
    /// Where the folder surface is, and Finder's favorites above the file tree (ColumnBrowser.swift).
    let browser = ColumnBrowserModel()
    let favorites = FinderFavoritesModel()
    /// Requests (reveal, rename, collapse) a sidebar list has acted on, so one made after
    /// a tab switch doesn't act on them again.
    private var handledRequests: Set<UUID> = []

    /// `true` the first time a sidebar list sees request `id`.
    func take(_ id: UUID) -> Bool { handledRequests.insert(id).inserted }
    /// `files` as a set, for membership on a whole-disk vault.
    private(set) var fileSet: Set<FileRef> = []
    /// Bumped whenever `files` is replaced, so the palette rebuilds its table only then.
    private(set) var filesVersion = 0
    /// `false` until the first full walk of the vault lands; `files` is partial until then.
    private var listed = false
    private var fileListingRequest = 0
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
    @Published var railVisible = Defaults.railVisible { didSet { Defaults.railVisible = railVisible; if railVisible { tiling.userOpened(.inspector) }; refreshGraphIfShown() } }
    /// Set when the user shows the rail on a window too narrow to show it by itself.
    @Published var railPinned = false
    /// Tracked by the app delegate; the rail hides itself below `narrowWindow` unless pinned.
    var windowWidth: CGFloat {
        get { layout.windowWidth }
        set { if layout.windowWidth != newValue { layout.windowWidth = newValue; windowResizedForTiles() } }
    }
    static let narrowWindow: CGFloat = 980

    /// What the layout actually shows: the user's choice, unless the window is too narrow.
    var railShown: Bool { railVisible && (windowWidth >= AppState.narrowWindow || railPinned) }
    var sidebarWidth: CGFloat {
        get { layout.leftWidth }
        set { layout.leftWidth = newValue; Defaults.sidebarWidth = newValue }
    }
    /// The right sidebar's open tab.
    @Published var inspectorTab = Defaults.inspectorTab { didSet { Defaults.inspectorTab = inspectorTab; refreshGraphIfShown() } }
    /// Bumped to put the keys in the chat field.
    @Published private(set) var chatFocusRequest = 0
    /// Bumped whenever connections or dismissed suggestions change on disk.
    @Published var connectionsRevision = 0
    private var workspaceSaveTask: Task<Void, Never>?
    /// The suggestion deck, while wandering.
    @Published var wander: WanderDeck? { didSet { refreshGraphIfShown() } }
    /// Bumped whenever `graph` is replaced. Views compare this, not the graph itself.
    @Published private(set) var graphRevision = 0
    /// The newest connection for the graph to show off; a new `id` plays it.
    @Published private(set) var graphCelebration: GraphCelebration?
    /// Thoughts and connections celebrated so far; the Thoughts tab's glyph hops on each.
    @Published private(set) var celebrationCount = 0
    /// Bumped to start the graph's Replay History.
    @Published private(set) var graphReplayRequest = 0
    /// How the graph is laid out. From View ▸ Graph Layout, the palette, or the graph's own menu.
    @Published var graphArrangement = Defaults.graphArrangement { didSet { Defaults.graphArrangement = graphArrangement } }
    @Published private(set) var jumpRequest: JumpRequest? { didSet {
        if !synchronizingPane { activePane.jumpRequest = jumpRequest }
    } }
    @Published private(set) var revealRequest: RevealRequest?
    /// What the columns have selected, vault-relative, for the file explorer to highlight
    /// without opening it (ColumnBrowser.swift). Cleared when the sidebar picks for itself.
    @Published var columnsSelection: String?
    @Published private(set) var history = History()
    @Published var trailEnabled = TrailStore.isEnabled { didSet { TrailStore.isEnabled = trailEnabled; recents.refreshSoon(); recordSetting("Record Trail", before: oldValue, after: trailEnabled) { [weak self] in self?.trailEnabled = $0 } } }

    private(set) var session: VaultSession?
    /// Recent files for the ⌘⌥ ring and Go → Recent Files (AppState+Recents.swift). Separate
    /// objects, so their updates redraw only the ring, not the window.
    let recents = RecentFilesModel()
    let radial = RadialMenuModel()
    /// Thoughts v2: jobs, understanding, night shift (AppState+Thoughts.swift).
    let thoughts = ThoughtsRuntime()
    @Published var isNewFilePresented = false
    /// Connect mode (⌘J): the grid of files you click to connect, over the content.
    @Published var connectGridShown = false
    /// Where the New File sheet creates: the folder on screen when ⌘N was pressed.
    @Published var newFileDirectory: URL?
    @Published var sourceHighlight = "" { didSet {
        if !synchronizingPane { activePane.sourceHighlight = sourceHighlight }
    } }
    @Published var selectedCommentID: UUID?
    @Published var openFiles: [FileRef] = []
    @Published var isHealthPresented = false
    @Published var isInboxPresented = false
    /// The morning inbox (see `AppState+Briefing.swift`).
    lazy var briefing: BriefingModel = { let model = BriefingModel(); model.state = self; return model }()
    @Published var analysisMessage: String?
    @Published var continuityError: String?
    private var reconcilingRenames: VaultSession?
    @Published var automaticAnalysis = UserDefaults.standard.object(forKey: "automaticAnalysis") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticAnalysis, forKey: "automaticAnalysis"); recordSetting("Automatic Analysis", before: oldValue, after: automaticAnalysis) { [weak self] in self?.automaticAnalysis = $0 } }
    }
    var textBuffers: [String: TextBuffer] = [:]
    var savedAnchors: [String: FileAnchor] = [:]
    var trackedEditorFiles = Set<FileRef>()
    var analysisTasks: [FileRef: Task<Void, Never>] = [:]
    var analyzedStamps: [FileRef: Date] = [:]
    var askEngine: AskEngine? { session?.ask }
    var trailStore: TrailStore? { session?.trail }

    /// Set by the active preview while it is on screen.
    var navigator: AnchorNavigator? {
        get { activePane.navigator }
        set { activePane.navigator = newValue }
    }
    /// The four panes, built once; the layout decides which show (AppState+Tiling.swift).
    let allPanes = DocumentPaneID.allCases.map { DocumentPane(id: $0) }
    let tiling = PaneTiling()
    /// What each empty pane offers (PaneLauncher.swift).
    let launcher = PaneLauncherModel()
    private var tilingObserver: AnyCancellable?
    var primaryPane: DocumentPane { allPanes[0] }
    var secondaryPane: DocumentPane { allPanes[1] }
    @Published var activePaneID: DocumentPaneID = .primary
    var splitVisible: Bool { tiling.arrangement.kind != .single }
    var activePane: DocumentPane { pane(activePaneID) }
    func pane(_ id: DocumentPaneID) -> DocumentPane { allPanes[DocumentPaneID.allCases.firstIndex(of: id)!] }
    var synchronizingPane = false
    /// Set by the sidebar so panels can hand keyboard focus back.
    var focusSidebar: (() -> Void)?
    /// The main window. Floating panels parent to it.
    weak var hostWindow: NSWindow?

    private var selectionFromSidebar = false
    private var recordInHistory = true
    private var pendingAnchor: FileAnchor?
    /// Keep startup references until a successful identity scan has drained its rename outbox.
    /// A missing path can be a file renamed while Flamingo was closed, not a deleted tab.
    private var pendingWorkspaceSelection: FileRef?
    private var workspaceRestorationPending = false
    private var workspaceIndexCompleted = false
    private var openedTask: Task<Void, Never>?
    private var graphTask: Task<Void, Never>?
    private var graphStale = true
    private var trashConfirmationOpen = false
    private var trailObserver: NSObjectProtocol?

    init(actionHistory: ActionHistory? = nil) {
        self.actionHistory = actionHistory ?? ActionHistory()
        for pane in allPanes {
            pane.onActivate = { [weak self] id in self?.activatePane(id) }
            pane.onLocationChanged = { [weak self] pane in self?.paneLocationChanged(pane) }
        }
        // Layout changes are rare, so the whole shell may redraw for them (menus, the top bar).
        tilingObserver = tiling.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        launcher.attach(self)
        sidebarSearch.runUnified = { [weak self] query in
            guard let self else { throw CancellationError() }
            return try await self.unifiedSearch(query, limit: 150)
        }
        sidebarSearch.run = { [weak self] q, folder in
            guard let session = self?.session else { throw CocoaError(.fileReadNoSuchFile) }
            return try await session.searchAll(q, inFolder: folder)
        }
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

        persistWorkspace()
        guard preserveOpenDrafts() else { return }
        let remembered = Defaults.workspace(in: v)
        let lastSelected = remembered?.selected ?? Defaults.lastSelected(in: v)
        openingVault = true
        actionHistory.clear()
        dismissToast()
        pendingWorkspaceSelection = nil
        workspaceRestorationPending = true
        workspaceIndexCompleted = false
        session?.stop()
        stopThoughts()
        analysisTasks.values.forEach { $0.cancel() }; analysisTasks = [:]
        trackedEditorFiles = []; analyzedStamps = [:]; analysisMessage = nil
        continuityError = nil
        indexing.status = nil
        indexing.error = nil
        indexing.pendingForce = nil
        let s = VaultSession(vault: v)
        session = s
        vault = v
        attachRecents(to: s)
        VaultScanner.writeDefaultIgnoreFile(in: v)
        do { bookmarks = try Bookmarks.loadOrCreateChecked(in: v); bookmarksError = nil }
        catch { bookmarks = Bookmarks(); bookmarksError = error.localizedDescription; report(error) }
        listed = false
        setFiles([])
        tree = FileTree(vault: v, sort: fileSort)
        sidebarSearch.reset()
        synchronizingPane = true
        allPanes.forEach { $0.reset() }; activePaneID = .primary; tiling.set(TileArrangement())
        selected = nil; selectedFolder = nil; anchor = nil; navigator = nil
        synchronizingPane = false
        textBuffers = [:]; openFiles = []; savedAnchors = [:]
        sourceHighlight = ""; selectedCommentID = nil
        jumpRequest = nil; revealRequest = nil; columnsSelection = nil
        comments = []; commentCounts = [:]; graph = Graph(); graphRevision &+= 1; sections = []
        history = History()
        graphStale = true
        graphTask?.cancel()
        graphTask = nil
        Defaults.noteRecent(v.root)
        MainMenu.refreshRecents()
        hostWindow?.title = v.name
        hostWindow?.representedURL = v.root
        wireCapture()
        startThoughts(for: s)

        s.onIndexingError = { [weak self, weak s] message in
            guard let self, let s, self.session === s else { return }
            self.indexing.error = message
        }
        let watcher = s.watcher
        s.watcher.onChange = { [weak self] batch in
            // How far this batch reaches, read before the watcher's next flush.
            let through = watcher.deliveredThrough
            Task { @MainActor in
                guard self?.session === s else { return }
                if self?.indexing.status?.phase == .catchingUp { self?.indexing.status?.files += batch.count }
                if batch.contains(VaultWatcher.allNotes) { await s.reloadNotes() }
                let refs = batch.filter { $0 != VaultWatcher.allNotes }
                guard !refs.isEmpty, self?.session === s else { return }
                // Root/ignore/dropped-event requests enter the tracked, cancellable scan.
                // The watcher already applies the shared admission policy to user files.
                if !refs.contains(where: { $0.relativePath.isEmpty }) {
                    _ = await s.update(refs, through: through)
                    await self?.applyIndexedRenames(in: s)
                }
                self?.filesChanged(refs, in: s)
                if self?.session === s { self?.editorFilesChanged(refs) }
            }
        }
        s.watcher.onSidecarChange = { [weak self] targets in
            Task { @MainActor in self?.sidecarsChanged(targets, in: s) }
        }
        s.watcher.onHistoryDone = { [weak self] in
            let through = watcher.deliveredThrough
            Task { @MainActor in self?.caughtUp(through: through, in: s) }
        }

        if let remembered {
            savedAnchors = remembered.anchors
            openFiles = remembered.openFiles
            trackedEditorFiles = Set(openFiles)
            for file in openFiles { analyzedStamps[file] = PreviewKind.modificationDate(of: v.url(for: file)) }
            selectedFolder = remembered.folder
            mode = Mode(rawValue: remembered.mode) ?? .files
            history = remembered.history.restored(in: v, preservingMissingFiles: true)
        }
        if let last = lastSelected, v.exists(last) {
            select(last, anchor: savedAnchors[last.relativePath], source: .other, record: false)
        } else {
            pendingWorkspaceSelection = lastSelected
        }
        if let split = remembered?.split {
            synchronizingPane = true
            restoreSplit(split, in: v)
            synchronizingPane = false
            synchronizeActivePane(record: false)
            pendingWorkspaceSelection = activePane.pendingFile
        }
        openingVault = false
        // Resume from where the index left off: replay what changed while the vault was
        // closed instead of walking every file again. Without a checkpoint, walk.
        let replaying = s.startWatching()
        if replaying { beginCatchUp(in: s) }
        checkFullDiskAccess()
        Task { [weak self] in
            await self?.refreshCounts()
            if !replaying { self?.reindex() }
        }
        fileListingRequest &+= 1
        let listingRequest = fileListingRequest
        Task { [weak self] in
            let (files, set) = await s.listFiles { [weak self] partial, members in
                guard let self, self.session === s, self.fileListingRequest == listingRequest, !self.listed else { return }
                self.setFiles(partial, set: members)
            }
            guard let self, self.session === s, self.fileListingRequest == listingRequest else { return }
            self.listed = true
            self.setFiles(files, set: set)
            // A folder is a useful destination. Do not silently replace it with an arbitrary file.
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
        if let last = Defaults.lastVault { open(URL(fileURLWithPath: last)) }
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

    // MARK: Bookmarks

    /// "Bookmark Folder…": any folder inside the vault, hidden ones included.
    func bookmarkFolderDialog() {
        guard let v = vault else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.showsHiddenFiles = true
        p.prompt = "Bookmark"
        p.directoryURL = v.root
        guard p.runModal() == .OK else { return }
        var added = false
        for url in p.urls { added = bookmark(url) || added }
        if !added { NSSound.beep() }
    }

    /// Bookmarks a file or folder given by URL, at `path` (the end when `nil`). `false` when
    /// it is outside the vault.
    @discardableResult
    func bookmark(_ url: URL, at path: Bookmarks.Path? = nil) -> Bool {
        guard let v = vault, let rel = v.relativePath(of: url), !v.isState(url) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        let kind: Bookmark.Kind = isDir.boolValue && !VaultScanner.isPackage(url) ? .folder : .file
        addBookmark(Bookmark(kind: kind, ctime: bookmarks.nextCTime(), path: rel), at: path)
        return true
    }

    func isBookmarked(_ path: String, folder: Bool) -> Bool {
        bookmarks.path(of: folder ? .folder : .file, at: path) != nil
    }

    /// Bookmarks a file or folder, or removes its bookmarks when it has some.
    func toggleBookmark(path: String, folder: Bool) {
        let kind: Bookmark.Kind = folder ? .folder : .file
        if let at = bookmarks.path(of: kind, at: path) {
            removeBookmark(at: at)
        } else {
            addBookmark(Bookmark(kind: kind, ctime: bookmarks.nextCTime(), path: path))
        }
    }

    /// ⌘D: the current file, else the selected folder.
    func toggleBookmarkCurrent() {
        if let f = selected { toggleBookmark(path: f.relativePath, folder: false) }
        else if let folder = selectedFolder, !folder.isEmpty { toggleBookmark(path: folder, folder: true) }
        else { NSSound.beep() }
    }

    func bookmarkSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if bookmarks.all.contains(where: { $0.bookmark.kind == .search && $0.bookmark.query == q }) { return }
        addBookmark(Bookmark(kind: .search, ctime: bookmarks.nextCTime(), query: q))
    }

    /// A new group at the top of the list, named in place.
    func addBookmarkGroup() {
        let b = Bookmark(kind: .group, ctime: bookmarks.nextCTime(), title: "New group")
        addBookmark(b, at: [0])
        sidebarCollapsed = false
        sidebarTab = .bookmarks
        renameRequest = RenameRequest(tab: .bookmarks, target: String(b.ctime))
    }

    func addBookmark(_ b: Bookmark, at path: Bookmarks.Path? = nil) {
        var new = bookmarks
        if let path { new.insert(b, at: path) } else { new.add(b) }
        saveBookmarks(new, actionName: "Add Bookmark")
    }

    /// No confirmation; the toast (and ⌘Z) puts it back where it was.
    func removeBookmark(at path: Bookmarks.Path) {
        var new = bookmarks
        guard let gone = new.remove(at: path) else { return }
        guard let id = saveBookmarks(new, actionName: "Remove Bookmark") else { return }
        Feedback.play(.poof)
        showToast(ToastMessage(text: "Removed " + gone.displayName, action: "Undo", perform: { [weak self] in self?.undoAction(id) }))
    }

    func moveBookmark(from: Bookmarks.Path, toParent parent: Bookmarks.Path, index: Int) {
        var new = bookmarks
        guard new.move(from: from, toParent: parent, index: index) != nil else { return }
        saveBookmarks(new, actionName: "Move Bookmark")
    }

    /// An empty title goes back to the file, folder or query name.
    func renameBookmark(ctime: Int64, to title: String) {
        guard let at = bookmarks.path(ctime: ctime) else { return }
        var new = bookmarks
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        new.modify(at: at) { $0.title = t.isEmpty && $0.kind != .group ? nil : (t.isEmpty ? $0.title : t) }
        saveBookmarks(new, actionName: "Rename Bookmark")
    }

    /// A bookmark clicked: a file opens, a folder is revealed in the file explorer, a search
    /// runs in the search tab.
    func openBookmark(_ b: Bookmark) {
        switch b.kind {
        case .file:
            guard let p = b.path else { return }
            let ref = FileRef(relativePath: p)
            guard fileSet.contains(ref) || vault?.exists(ref) == true else { NSSound.beep(); return }
            jump(to: ref, anchor: nil)
        case .folder:
            guard let p = b.path else { return }
            revealFolder(p)
        case .search:
            showSidebarSearch(b.query)
        case .group, nil:
            break
        }
    }

    @discardableResult
    private func saveBookmarks(_ new: Bookmarks, actionName: String? = nil) -> UUID? {
        guard let v = vault, new != bookmarks, bookmarksError == nil else { return nil }
        let old = bookmarks
        do {
            try new.save(in: v); bookmarks = new
            guard let actionName else { return nil }
            return actionHistory.register(name: actionName, undo: { [weak self] in
                try self?.restoreBookmarks(old, expecting: new, in: v)
            }, redo: { [weak self] in
                try self?.restoreBookmarks(new, expecting: old, in: v)
            })
        } catch { report(error); return nil }
    }

    private func restoreBookmarks(_ value: Bookmarks, expecting expected: Bookmarks, in vault: Vault) throws {
        guard self.vault == vault, try Bookmarks.loadOrCreateChecked(in: vault) == expected else { throw UndoFailure.changed }
        try value.save(in: vault)
        bookmarks = value
    }

    func retryBookmarks() {
        guard let v = vault else { return }
        do { bookmarks = try Bookmarks.loadOrCreateChecked(in: v); bookmarksError = nil }
        catch { bookmarksError = error.localizedDescription }
    }

    func recoverBookmarks() {
        guard let v = vault, bookmarksError != nil else { return }
        do {
            let backup = v.bookmarksURL.deletingPathExtension().appendingPathExtension("recovery-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: v.bookmarksURL, to: backup)
            let replacement = Bookmarks()
            try replacement.save(in: v)
            bookmarks = replacement; bookmarksError = nil
            showToast(ToastMessage(text: "Original bookmarks preserved in \(backup.lastPathComponent)"))
        } catch { bookmarksError = error.localizedDescription }
    }

    // MARK: Sidebar

    func toggleSidebar() {
        let previous = sidebarCollapsed
        sidebarCollapsed.toggle()
        recordSetting("Toggle Sidebar", before: previous, after: sidebarCollapsed) { [weak self] in self?.sidebarCollapsed = $0 }
    }

    func showSidebarTab(_ tab: SidebarTab) {
        if sidebarCollapsed { sidebarCollapsed = false }
        sidebarTab = tab
    }

    /// ⌘⇧F, or a search bookmark: the search tab, focused, with `query` if given.
    func showSidebarSearch(_ query: String? = nil) {
        showSidebarTab(.search)
        if let query { sidebarSearch.query = query }
        sidebarSearch.focus()
    }

    /// "Reveal current file in navigation".
    func revealCurrentFile() {
        guard let f = selected else { NSSound.beep(); return }
        showSidebarTab(.files)
        revealRequest = RevealRequest(file: f, force: true, pulse: true)
    }

    /// Shows a folder in the file explorer, opened, and scopes the graph to it.
    func revealFolder(_ path: String) {
        showSidebarTab(.files)
        selectFromSidebar(folder: path, file: nil)
        revealRequest = RevealRequest(file: FileRef(relativePath: path), expand: true, force: true)
    }

    func collapseAll(in tab: SidebarTab) {
        collapseRequest = (tab, UUID())
    }

    func openRandomFile() {
        let pool = files.count > 200_000 ? Array(files.prefix(200_000)) : files
        guard let f = pool.randomElement() else { NSSound.beep(); return }
        jump(to: f, anchor: nil)
    }

    // MARK: File operations

    /// Where new files and folders land: the folder on screen when no file is open (the
    /// deepest column, or the icon view's folder), else the sidebar's folder, else the
    /// open file's folder, else the vault's top level.
    private var targetDirectory: URL? {
        guard let v = vault else { return nil }
        if mode == .files, selected == nil, let shown = browser.folder { return shown }
        let folder = selectedFolder ?? selected?.directory ?? ""
        return folder.isEmpty ? v.root : v.root.appendingPathComponent(folder, isDirectory: true)
    }

    /// `targetDirectory` inside the vault, vault-relative; the sidebar's folder when the
    /// folder on screen is outside it.
    private var targetFolder: String {
        if let v = vault, let url = targetDirectory, let rel = vaultFolder(url, in: v) { return rel }
        return selectedFolder ?? selected?.directory ?? ""
    }

    /// A folder's vault-relative path ("" for the root), or nil outside the vault.
    private func vaultFolder(_ url: URL, in v: Vault) -> String? {
        if url.standardizedFileURL.path == v.root.standardizedFileURL.path { return "" }
        guard let rel = v.relativePath(of: url), !v.isState(url) else { return nil }
        return rel
    }

    /// ⌘N: pick a kind of file, name it, and it's made in the folder on screen, or in
    /// `folder` (vault-relative) when a folder's menu asks.
    func showNewFile(in folder: String? = nil) {
        guard let v = vault, let directory = folder.map({ $0.isEmpty ? v.root : v.root.appendingPathComponent($0, isDirectory: true) }) ?? targetDirectory else { return }
        newFileDirectory = directory
        isNewFilePresented = true
    }

    /// A blank `format` named `name` in `directory`, opened where it's edited: text in
    /// Flamingo, everything else in its own app. An empty name is the next free "Untitled".
    /// Kinds only their app can start open that app instead.
    func createDocument(_ format: DocumentFactory.Format, name: String, in directory: URL) throws {
        let wasSuppressed = suppressActionHistory; suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        guard let v = vault else { return }
        guard format.isFile else {
            guard let app = Self.application(for: format) else { throw DocumentError.unsupportedType(format.ext) }
            isNewFilePresented = false
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in self?.showToast(ToastMessage(text: "Couldn't open " + app.deletingPathExtension().lastPathComponent)) }
            }
            return
        }
        let url = try Self.createUntitledIfEmpty(format, name: name, in: directory)
        isNewFilePresented = false
        guard let folder = vaultFolder(directory, in: v), let relative = v.relativePath(of: url) else {
            // Outside the vault there's no tab for it: its app opens it, the columns re-list it.
            noteFoldersChanged([]); NSWorkspace.shared.open(url)
            return
        }
        let file = FileRef(relativePath: relative)
        registerCreation(relative, in: v)
        setFiles(files + [file]); noteFoldersChanged([folder])
        showSidebarTab(.files); jump(to: file, anchor: nil)
        trackedEditorFiles.insert(file)
        if format.isText {
            textBuffer(for: file)?.focusRequested = true
        } else { openExternally(file) }
        if let s = session { Task { await s.update([file]); await refreshSections() } }
    }

    private static func createUntitledIfEmpty(_ format: DocumentFactory.Format, name: String, in directory: URL) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !name.isEmpty { return try DocumentFactory.create(format, name: name, in: directory) }
            for n in 0..<1000 {
                do { return try DocumentFactory.create(format, name: n == 0 ? "Untitled" : "Untitled \(n)", in: directory) }
                catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) { continue }
            }
            throw DocumentError.invalidName
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw DocumentError.exists((try? DocumentFactory.filename(name, format: format)) ?? name)
        }
    }

    /// The app a kind opens in: its own app for kinds only an app can start (matched by
    /// bundle identifier, or its prefix for versioned ones like Premiere), else this
    /// Mac's default app for the extension. Nil when no app here handles it.
    static func application(for format: DocumentFactory.Format) -> URL? {
        let type = UTType(filenameExtension: format.ext)
        if case .app(let id) = format.source {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
            return type.flatMap { t in
                NSWorkspace.shared.urlsForApplications(toOpen: t).first { Bundle(url: $0)?.bundleIdentifier?.hasPrefix(id) == true }
            }
        }
        return type.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    func textBuffer(for file: FileRef) -> TextBuffer? {
        guard let v = vault else { return nil }
        if let buffer = textBuffers[file.relativePath] { return buffer }
        let buffer = TextBuffer(file: file, vault: v)
        buffer.actionHistory = actionHistory
        buffer.onSaved = { [weak self] in self?.documentSaved(file) }
        textBuffers[file.relativePath] = buffer
        return buffer
    }

    func saveDocument() {
        guard let file = selected, let buffer = textBuffers[file.relativePath] else { return }
        Task { await buffer.save() }
    }

    /// Saves the workspace after half a second without another anchor change.
    func persistWorkspaceSoon() {
        workspaceSaveTask?.cancel()
        let v = vault
        workspaceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.vault == v else { return }
            self.persistWorkspace()
        }
    }

    func persistWorkspace() {
        workspaceSaveTask?.cancel(); workspaceSaveTask = nil
        guard !openingVault, let v = vault else { return }
        Defaults.setWorkspace(WorkspaceSnapshot(selected: selected ?? pendingWorkspaceSelection, folder: selectedFolder, mode: mode.rawValue,
                                                anchors: savedAnchors, openFiles: openFiles, history: SavedHistory(history),
                                                split: savedSplit()), in: v)
    }

    /// Completion and outbox drainage arrive separately. Failed/cancelled scans never
    /// discard remembered places, and a late rename never replaces a user's new selection.
    func finishWorkspaceRestoration(in s: VaultSession, indexOutcome: VaultSession.ReindexOutcome? = nil, renamesDrained: Bool = false) {
        guard session === s, workspaceRestorationPending else { return }
        if let indexOutcome { workspaceIndexCompleted = indexOutcome == .completed }
        guard workspaceIndexCompleted, renamesDrained, s.indexingError == nil, continuityError == nil else { return }
        let v = s.vault
        openFiles = openFiles.filter { v.exists($0) }
        history.prune(keeping: Set(history.entries.compactMap(\.file).filter { v.exists($0) }))
        let pending = pendingWorkspaceSelection
        pendingWorkspaceSelection = nil
        workspaceRestorationPending = false
        for pane in allPanes where pane.id != activePaneID {
            if let pending = pane.pendingFile {
                let resolved = v.exists(pending) ? pending : Wikilink.resolve(pending.relativePath, in: v, candidates: openFiles)
                let location = pane.anchor ?? pane.anchors[pending.relativePath]
                pane.show(resolved); pane.pendingFile = nil
                if let resolved { pane.anchor = location; pane.jumpRequest = location.map { JumpRequest(file: resolved, anchor: $0) } }
            }
        }
        if let pending, selected == nil {
            // Rename consumption already relocated the remembered tabs and anchor keys.
            // Alias lookup also handles a previous launch that acknowledged the move.
            let current = v.exists(pending) ? pending : Wikilink.resolve(pending.relativePath, in: v, candidates: openFiles)
            if let current { select(current, anchor: activePane.anchor ?? activePane.anchors[pending.relativePath] ?? savedAnchors[current.relativePath], source: .other, record: false) }
        }
        for pane in allPanes { pane.pendingFile = nil }
        pruneMissingPanes()
        persistWorkspace()
    }

    /// ⌘W closes the document in front, never the window: the focused pane in split view,
    /// otherwise the current tab. Graph and Trail show no document, so there it does nothing.
    var canCloseDocument: Bool { (mode == .files || mode == .ask) && (splitVisible || selected != nil) }

    func closeCurrentDocument() {
        guard canCloseDocument else { return }
        if splitVisible { closePane(activePaneID) } else if let selected { closeTab(selected) }
    }

    /// Drops a file from the tab strip once its draft is safe; false leaves it open.
    func releaseTab(_ file: FileRef) -> Bool {
        if let buffer = textBuffers[file.relativePath], !buffer.persistDraft() {
            showToast(ToastMessage(text: "This draft could not be backed up. Save a copy before closing it.")); return false
        }
        openFiles.removeAll { $0 == file }
        if pendingWorkspaceSelection == file { pendingWorkspaceSelection = nil }
        if let buffer = textBuffers[file.relativePath], !buffer.dirty, !buffer.saving {
            textBuffers.removeValue(forKey: file.relativePath)
        }
        return true
    }

    func closeTab(_ file: FileRef) {
        let wasSuppressed = suppressActionHistory; suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        let before = undoWorkspaceSnapshot()
        guard releaseTab(file) else { return }
        for pane in allPanes where pane.id != activePaneID && (pane.file == file || pane.pendingFile == file) { pane.show(nil); pane.pendingFile = nil }
        if selected == file { select(openFiles.last, source: .other) }
        persistWorkspace()
        let after = undoWorkspaceSnapshot()
        actionHistory.register(name: "Close Tab", undo: { [weak self] in self?.restoreUndoWorkspace(before) }, redo: { [weak self] in self?.restoreUndoWorkspace(after) })
    }

    func preserveOpenDrafts() -> Bool {
        let results = textBuffers.values.map { $0.persistDraft() }
        let capturePreserved = CaptureController.shared.preserveDraft()
        let thoughtFailures = ThoughtDraftCheckpoint.flush()
        guard capturePreserved, results.allSatisfy({ $0 }), thoughtFailures.isEmpty else {
            let detail = thoughtFailures.first.map { " " + $0 } ?? ""
            showToast(ToastMessage(text: "A draft could not be backed up. Save a copy before closing the workspace." + detail))
            return false
        }
        return true
    }

    /// ⌥⌘N: an empty `Untitled.md`, selected and named in place.
    func newNote(in folder: String? = nil) {
        create(in: folder ?? targetFolder, base: "Untitled", ext: "md", folder: false)
    }

    /// ⌘⇧N: an `Untitled` folder, named in place.
    func newFolder(in folder: String? = nil) {
        create(in: folder ?? targetFolder, base: "Untitled", ext: nil, folder: true)
    }

    private func create(in folder: String, base: String, ext: String?, folder isFolder: Bool) {
        let wasSuppressed = suppressActionHistory; suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        guard let v = vault else { return }
        let dir = folder.isEmpty ? v.root : v.root.appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        var name = ext.map { base + "." + $0 } ?? base
        var n = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = ext.map { "\(base) \(n).\($0)" } ?? "\(base) \(n)"
            n += 1
        }
        let url = dir.appendingPathComponent(name, isDirectory: isFolder)
        do {
            if isFolder {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            showToast(ToastMessage(text: "Couldn't create " + name))
            return
        }
        let rel = folder.isEmpty ? name : folder + "/" + name
        registerCreation(rel, in: v)
        showSidebarTab(.files)
        noteFoldersChanged([folder])
        if isFolder {
            mode = .files
            selectFromSidebar(folder: rel, file: nil)
            revealRequest = RevealRequest(file: FileRef(relativePath: rel), force: true)
        } else {
            let ref = FileRef(relativePath: rel)
            if !fileSet.contains(ref) { setFiles(files + [ref]) }
            jump(to: ref, anchor: nil)
        }
        // The columns rename a folder they will show: one inside the folder they start at.
        let shownInColumns = browser.style == .columns && browser.root.flatMap { ColumnBrowserModel.chain(from: $0, to: url) } != nil
        renameRequest = RenameRequest(tab: .files, target: rel, inColumns: isFolder && shownInColumns)
    }

    /// Only the focused Files outline invokes this, through Command–Delete.
    func requestTrash(_ path: String, in window: NSWindow?) {
        guard !trashConfirmationOpen, let vault else { return }
        do {
            let target = try FileTrash.inspect(path, in: vault)
            if target.isEmptyFolder {
                _ = trash(target, confirmed: false)
                return
            }
            guard let window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move “\(target.url.lastPathComponent)” to Trash?"
            alert.informativeText = "Command-Z can restore it for 10 seconds. After that, it remains in Trash. Unsaved edits are kept as a recovery draft."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            alert.buttons[1].keyEquivalentModifierMask = []
            trashConfirmationOpen = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.trashConfirmationOpen = false
                if response == .alertFirstButtonReturn { _ = self.trash(target, confirmed: true) }
            }
        } catch { report(error) }
    }

    /// Retire live document state only after the OS has accepted a recoverable trash move.
    @discardableResult
    func trash(_ target: FileTrash.Target, confirmed: Bool,
               trashItem: ((URL) throws -> URL)? = nil,
               moveToTrash: ((URL) throws -> Void)? = nil) -> Bool {
        let wasSuppressed = suppressActionHistory; suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        guard vault == target.vault, let s = session else { return false }
        let path = target.path
        let affected = textBuffers.filter { FileTree.contains(path, $0.key) }
        guard !affected.values.contains(where: { $0.saving }) else {
            showToast(ToastMessage(text: "Wait for this file to finish saving, then try again.")); return false
        }
        guard affected.values.map({ $0.persistDraft() }).allSatisfy({ $0 }) else {
            showToast(ToastMessage(text: "The draft could not be backed up. Save a copy before deleting this item.")); return false
        }
        let workspace = undoWorkspaceSnapshot()
        let knownFiles = files.filter { FileTree.contains(path, $0.relativePath) }
        var receipt: FileTrash.Receipt?
        var undoFailure: Error?
        do {
            try FileTrash.move(target, confirmed: confirmed) { url in
                if let moveToTrash { try moveToTrash(url) }
                else {
                    let destination = try (trashItem ?? FileTrash.trashURL)(url)
                    do { receipt = try FileTrash.Receipt(target: target, trashURL: destination) }
                    catch { undoFailure = error }
                }
            }
        }
        catch FileTrash.Failure.confirmationRequired {
            requestTrash(path, in: hostWindow)
            return false
        } catch { report(error); return false }
        // Finder's own sound, for a delete the user asked for (not an undo replaying one).
        if !actionHistory.isApplying { Feedback.play(.trash) }

        for pane in allPanes where pane.id != activePaneID { pane.remove(path) }
        openFiles.removeAll { FileTree.contains(path, $0.relativePath) }
        if let pending = pendingWorkspaceSelection, FileTree.contains(path, pending.relativePath) { pendingWorkspaceSelection = nil }
        for key in affected.keys { textBuffers.removeValue(forKey: key) }
        savedAnchors = savedAnchors.filter { !FileTree.contains(path, $0.key) }
        trackedEditorFiles = trackedEditorFiles.filter { !FileTree.contains(path, $0.relativePath) }
        analyzedStamps = analyzedStamps.filter { !FileTree.contains(path, $0.key.relativePath) }
        for file in Array(analysisTasks.keys) where FileTree.contains(path, file.relativePath) {
            analysisTasks.removeValue(forKey: file)?.cancel()
        }
        history.remove(path)
        setFiles(files.filter { !FileTree.contains(path, $0.relativePath) })
        if let folder = selectedFolder, FileTree.contains(path, folder) {
            selectedFolder = (path as NSString).deletingLastPathComponent
        }
        if let selected, FileTree.contains(path, selected.relativePath) { select(nil, source: .other, record: false) }
        noteFoldersChanged([path, (path as NSString).deletingLastPathComponent])
        persistWorkspace()
        if let initialReceipt = receipt, !actionHistory.isApplying {
            var currentReceipt = initialReceipt
            let id = actionHistory.register(name: "Delete " + target.url.lastPathComponent, expiresAfter: 10, undo: { [weak self] in
                guard let self, self.vault == target.vault else { throw UndoFailure.changed }
                try currentReceipt.restore()
                self.restoreDeletedWorkspace(workspace, files: knownFiles, path: path)
            }, redo: { [weak self] in
                guard let self, self.vault == target.vault else { throw UndoFailure.changed }
                let next = try currentReceipt.inspectRestored()
                guard self.trash(next, confirmed: true, trashItem: { url in
                    let destination = try (trashItem ?? FileTrash.trashURL)(url)
                    if let receipt = try? FileTrash.Receipt(target: next, trashURL: destination) { currentReceipt = receipt }
                    return destination
                }) else { throw UndoFailure.failed }
            })
            showToast(ToastMessage(text: "Moved “\(target.url.lastPathComponent)” to Trash · Undo for 10 seconds", action: "Undo", perform: { [weak self] in self?.undoAction(id) }), duration: 10)
        } else if let undoFailure {
            showToast(ToastMessage(text: "Moved to Trash. Quick Undo is unavailable: " + undoFailure.localizedDescription))
        }
        // Thoughts and connection history remain recoverable if the source is restored.
        Task {
            _ = await s.update([FileRef(relativePath: path)])
            filesChanged([FileRef(relativePath: path)], in: s)
        }
        return true
    }

    /// Puts the current file's name in the title up for editing, as ↩ renames in Finder: ↩
    /// that nothing on screen took (`MainWindow`), or File ▸ Rename….
    @discardableResult
    func renameInTitle() -> Bool {
        guard let file = selected, vault != nil else { return false }
        renamingTitle = file
        return true
    }

    /// Renames a file or folder in place (same folder, new name).
    @discardableResult
    func rename(_ path: String, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") || path.split(separator: "/").last?.hasPrefix(".") == true else {
            NSSound.beep(); return false
        }
        let parent = (path as NSString).deletingLastPathComponent
        let dest = parent.isEmpty ? name : parent + "/" + name
        return relocate(path, to: dest)
    }

    /// Moves a file or folder into another folder (drag in the file explorer).
    @discardableResult
    func move(_ path: String, into folder: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let dest = folder.isEmpty ? name : folder + "/" + name
        guard !FileTree.contains(path, folder) else { NSSound.beep(); return false }
        return relocate(path, to: dest)
    }

    /// Moves `old` to `new` on disk, and everything that follows it: its thoughts (the
    /// sidecars), bookmarks, the selection and the explorer's open folders.
    private func relocate(_ old: String, to new: String) -> Bool {
        let wasSuppressed = suppressActionHistory; suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        guard let v = vault, let s = session, old != new, !old.isEmpty else { return false }
        if textBuffers.contains(where: { FileTree.contains(old, $0.key) && ($0.value.dirty || $0.value.saving) }) {
            showToast(ToastMessage(text: "Save the open draft before moving or renaming this file."))
            return false
        }
        let from = v.root.appendingPathComponent(old), to = v.root.appendingPathComponent(new)
        let fm = FileManager.default
        // A case-only rename is the same file on a case-insensitive disk.
        if fm.fileExists(atPath: to.path), old.lowercased() != new.lowercased() {
            showToast(ToastMessage(text: (new as NSString).lastPathComponent + " already exists"))
            return false
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { return false }
        let isPackage = VaultScanner.isPackage(from)
        let identity = try? FileTrash.inspect(old, in: v)
        if old.lowercased() != new.lowercased() {
            do {
                let refs = try s.sidecar.sidecarRefs()
                if refs.contains(where: { FileTree.contains(new, $0.relativePath) }) {
                    showToast(ToastMessage(text: "That destination has saved thoughts. Choose another name to preserve them."))
                    return false
                }
            } catch { report(error); return false }
        }
        do { try fm.moveItem(at: from, to: to) } catch {
            showToast(ToastMessage(text: "Couldn't rename " + (old as NSString).lastPathComponent))
            return false
        }
        // Thoughts follow their files. A folder's files are found by their sidecars.
        let moved: [(FileRef, FileRef)]
        if isDir.boolValue && !isPackage {
            let refs = (try? s.sidecar.sidecarRefs()) ?? []
            moved = refs.filter { $0.relativePath.hasPrefix(old + "/") }
                .map { ($0, FileRef(relativePath: new + $0.relativePath.dropFirst(old.count))) }
        } else {
            moved = [(FileRef(relativePath: old), FileRef(relativePath: new))]
        }
        var relocated: [(FileRef, FileRef)] = []
        do {
            for (a, b) in moved { try s.sidecar.move(sidecarFor: a, to: b); relocated.append((a, b)) }
        } catch {
            var rollbackErrors: [String] = []
            for (a, b) in relocated.reversed() {
                do { try s.sidecar.move(sidecarFor: b, to: a) } catch { rollbackErrors.append(error.localizedDescription) }
            }
            do { try fm.moveItem(at: to, to: from) } catch { rollbackErrors.append(error.localizedDescription) }
            showToast(ToastMessage(text: "Move failed while preserving thoughts: " + error.localizedDescription + (rollbackErrors.isEmpty ? " · Original restored." : " · Recovery needed: " + rollbackErrors.joined(separator: "; "))))
            return false
        }
        do { try s.connections.reconcile(oldPath: old, newPath: new) } catch { report(error) }
        do { try s.trail.reconcile(oldPath: old, newPath: new) } catch { report(error) }
        do { try PathAliases(vault: v).reconcile(oldPath: old, newPath: new) } catch { report(error) }
        for pane in allPanes where pane.id != activePaneID { pane.relocate(old, to: new) }
        history.relocate(old, to: new)
        searchResults.relocate(old, to: new)
        func relocatedPath(_ path: String) -> String { FileTree.contains(old, path) ? new + path.dropFirst(old.count) : path }
        openFiles = openFiles.map { FileRef(relativePath: relocatedPath($0.relativePath)) }
        savedAnchors = Dictionary(savedAnchors.map { (relocatedPath($0.key), $0.value) }, uniquingKeysWith: { _, new in new })
        for path in Array(textBuffers.keys) where FileTree.contains(old, path) { textBuffers.removeValue(forKey: path) }
        trackedEditorFiles = Set(trackedEditorFiles.map { FileRef(relativePath: relocatedPath($0.relativePath)) })
        let previousFiles = files.filter { FileTree.contains(old, $0.relativePath) }
        let newFiles = previousFiles.map { FileRef(relativePath: relocatedPath($0.relativePath)) }
        setFiles(files.map { FileRef(relativePath: relocatedPath($0.relativePath)) })

        var b = bookmarks
        b.rename(old, to: new)
        saveBookmarks(b)
        var expanded = Defaults.expandedFolders(in: v) ?? []
        if expanded.contains(where: { FileTree.contains(old, $0) }) {
            expanded = Set(expanded.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
            Defaults.setExpandedFolders(expanded, in: v)
        }
        let oldParent = (old as NSString).deletingLastPathComponent, newParent = (new as NSString).deletingLastPathComponent
        noteFoldersChanged([oldParent, newParent])
        if let folder = selectedFolder, FileTree.contains(old, folder) {
            selectedFolder = new + folder.dropFirst(old.count)
        }
        if let sel = selected, FileTree.contains(old, sel.relativePath) {
            let ref = FileRef(relativePath: new + sel.relativePath.dropFirst(old.count))
            select(ref, source: .other, record: false)
        }
        activePane.relocate(old, to: new)
        func destinationStillMatches() -> Bool {
            guard self.session === s, let identity, let current = try? FileTrash.inspect(new, in: v) else { return false }
            return current.device == identity.device && current.inode == identity.inode
        }
        Task {
            guard destinationStillMatches() else { return }
            do {
                try await s.recordRename(from: FileRef(relativePath: old), to: FileRef(relativePath: new))
                guard destinationStillMatches() else { return }
                let direct = !isDir.boolValue || isPackage ? [FileRef(relativePath: new)] : []
                let updated = await s.update(Array(Set(newFiles + direct)))
                guard destinationStillMatches() else { return }
                await applyIndexedRenames(in: s)
                guard destinationStillMatches() else { return }
                if updated { try await s.pruneMovedSources(previousFiles) }
                await refreshGraph()
            } catch {
                guard destinationStillMatches() else { return }
                continuityError = "File moved; workspace details need retry: " + error.localizedDescription
                report(error)
            }
        }
        persistWorkspace()
        if let identity {
            actionHistory.register(name: "Move or Rename File", undo: { [weak self] in
                guard let self, self.vault == v else { throw UndoFailure.changed }
                try self.checkIdentity(new, vault: v, device: identity.device, inode: identity.inode)
                guard self.relocate(new, to: old) else { throw UndoFailure.failed }
            }, redo: { [weak self] in
                guard let self, self.vault == v else { throw UndoFailure.changed }
                try self.checkIdentity(old, vault: v, device: identity.device, inode: identity.inode)
                guard self.relocate(old, to: new) else { throw UndoFailure.failed }
            })
        }
        return true
    }

    // MARK: Toast

    /// Consume identity-confirmed moves after the index sees native-editor or filesystem renames.
    /// The index keeps a durable outbox until every dependent store has acknowledged the move.
    func applyIndexedRenames(in s: VaultSession) async {
        guard session === s, reconcilingRenames !== s else { return }
        reconcilingRenames = s
        defer { if reconcilingRenames === s { reconcilingRenames = nil } }
        for _ in 0..<10 {
            let moves = await s.takeIndexedRenames()
            guard session === s else { return }
            if moves.isEmpty {
                finishWorkspaceRestoration(in: s, renamesDrained: true)
                return
            }
            for move in moves {
                func destinationStillMatches() -> Bool {
                    guard let expected = move.fileIdentity else { return false }
                    return (try? FileIdentity.existingID(for: s.vault.url(for: move.to))) == expected
                }
                guard destinationStillMatches() else { continue } // An undo or later move may supersede this record.
                do {
                    let sidecar = s.sidecar, connections = s.connections, trail = s.trail, vault = s.vault
                    // Keep metadata replay on the same executor as user moves/undo so
                    // an inverse move cannot interleave halfway through this sequence.
                    do {
                        guard let identity = move.fileIdentity else { throw SidecarError.identityMismatch(path: move.to.relativePath) }
                        try sidecar.move(sidecarFor: move.from, to: move.to, matching: identity)
                        try connections.reconcile(oldPath: move.from.relativePath, newPath: move.to.relativePath)
                        try trail.reconcile(oldPath: move.from.relativePath, newPath: move.to.relativePath)
                        try PathAliases(vault: vault).reconcile(oldPath: move.from.relativePath, newPath: move.to.relativePath)
                    }
                    guard session === s else { return }
                    guard destinationStillMatches() else { continue }
                    if let buffer = textBuffers[move.from.relativePath] {
                        let successor = try await buffer.relocated(to: move.to, vault: s.vault)
                        guard session === s else { return }
                        guard destinationStillMatches() else { continue }
                        successor.onSaved = { [weak self] in self?.documentSaved(move.to) }
                        textBuffers[move.to.relativePath] = successor
                        textBuffers.removeValue(forKey: move.from.relativePath)
                    }
                    var updatedBookmarks = bookmarks
                    updatedBookmarks.rename(move.from.relativePath, to: move.to.relativePath)
                    if updatedBookmarks != bookmarks, bookmarksError == nil {
                        try updatedBookmarks.save(in: s.vault); bookmarks = updatedBookmarks
                    }
                    for pane in allPanes where pane.id != activePaneID { pane.relocate(move.from.relativePath, to: move.to.relativePath) }
                    history.relocate(move.from.relativePath, to: move.to.relativePath)
                    openFiles = openFiles.map { $0 == move.from ? move.to : $0 }
                    if pendingWorkspaceSelection == move.from { pendingWorkspaceSelection = move.to }
                    if let saved = savedAnchors.removeValue(forKey: move.from.relativePath) { savedAnchors[move.to.relativePath] = saved }
                    if trackedEditorFiles.remove(move.from) != nil { trackedEditorFiles.insert(move.to) }
                    if let stamp = analyzedStamps.removeValue(forKey: move.from) { analyzedStamps[move.to] = stamp }
                    analysisTasks.removeValue(forKey: move.from)?.cancel()
                    setFiles(Array(Set(files.map { $0 == move.from ? move.to : $0 })))
                    noteFoldersChanged([move.from.directory, move.to.directory])
                    if selected == move.from { select(move.to, anchor: anchor, source: .other, record: false) }
                    activePane.relocate(move.from.relativePath, to: move.to.relativePath)
                    persistWorkspace()
                    try await s.acknowledgeIndexedRename(move)
                    continuityError = nil
                } catch {
                    guard destinationStillMatches() else { continue }
                    continuityError = "File moved; workspace details need retry: " + error.localizedDescription
                    report(error)
                    return
                }
            }
            markGraphStale(urgent: true)
            sidebarSearch.refresh()
        }
    }

    func showToast(_ message: ToastMessage, duration: TimeInterval = 6) {
        toastTask?.cancel()
        withAnimation(Theme.Motion.fast) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
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
                if let v = vault, let rel = v.relativePath(of: url), !v.isState(url) { revealFolder(rel) } else { open(url) }
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
        fileListingRequest &+= 1
        let request = fileListingRequest
        Task {
            let (files, set) = await s.listFiles()
            guard self.session === s, self.fileListingRequest == request else { return }
            self.listed = true
            self.setFiles(files, set: set)
            pruneMissingPanes()
            if !workspaceRestorationPending { history.prune(keeping: fileSet) }
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
            if gone || allPanes.contains(where: { $0.file != nil }) { pruneMissingPanes() }
        }
    }

    func noteFoldersChanged(_ folders: Set<String>) {
        changedFolders = folders
        treeRevision &+= 1
    }

    private func filesChanged(_ refs: [FileRef], in s: VaultSession) {
        guard session === s else { return }
        let all = refs.contains { $0.relativePath.isEmpty }
        // Lost events or new rules: the index can't vouch for itself until a walk completes,
        // and the file list has to come from the disk, not from the index.
        if all { s.distrustCheckpoint() }
        applyDiskChanges(refs, in: s)
        if all { reindex(eventsLost: true) }
        indexing.error = s.indexingError
        sidebarSearch.refresh()
        if let sel = selected, all || refs.contains(sel) {
            Task { await refreshSections() }
        }
        Task { await refreshCounts() }
        markGraphStale()
    }

    private func sidecarsChanged(_ targets: [FileRef], in s: VaultSession) {
        guard session === s else { return }
        sidebarSearch.refresh()
        if let sel = selected, targets.contains(sel) || targets.contains(VaultWatcher.allNotes) { Task { await refreshComments() } }
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
        cc.availableFiles = { [weak self] vault in self?.vault == vault ? self?.files ?? [] : [] }
        cc.onSaveComment = { [weak self] file, comment in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            try await self.saveComment(comment, to: file)
            self.celebrate(comment, on: file)
        }
        wireThoughtCapture()
    }

    // MARK: Document panes

    private func paneLocationChanged(_ pane: DocumentPane) {
        guard !synchronizingPane else { return }
        if pane.id == activePaneID, pane.file == selected, anchor != pane.anchor { anchor = pane.anchor }
        else { persistWorkspace() }
    }

    /// Focusing a pane republishes its existing location without issuing another jump.
    /// This preserves native text selections, PDF scroll positions and media playheads.
    func activatePane(_ id: DocumentPaneID) {
        guard id != activePaneID, tiling.arrangement.visible.contains(id) else { return }
        activePane.cancelFocusRequest()
        activePaneID = id
        synchronizeActivePane(record: true)
    }

    func synchronizeActivePane(record: Bool) {
        let changedFile = selected != activePane.file
        synchronizingPane = true
        selected = activePane.file
        anchor = activePane.anchor
        jumpRequest = activePane.jumpRequest
        sourceHighlight = activePane.sourceHighlight
        if changedFile { selectedCommentID = nil }
        if let selected { selectedFolder = selected.directory }
        synchronizingPane = false
        if changedFile { comments = []; sections = [] }
        if let selected {
            if let anchor { savedAnchors[selected.relativePath] = anchor }
            if !openFiles.contains(selected) { openFiles.append(selected) }
            if record { history.push(History.Entry(file: selected, anchor: anchor, mode: mode, folder: selectedFolder)) }
            revealRequest = RevealRequest(file: selected)
            scheduleOpenedEvent(for: selected)
            if changedFile {
                Task { await refreshComments() }
                Task { await refreshSections() }
            }
        } else { openedTask?.cancel() }
        if let vault, !openingVault { Defaults.setLastSelected(selected, in: vault) }
        persistWorkspace()
    }

    // Layouts, splitting, closing and focusing panes: AppState+Tiling.swift.

    private func pruneMissingPanes() {
        guard let vault else { return }
        for pane in allPanes {
            if let file = pane.file, !vault.exists(file) {
                if pane.id == activePaneID { selected = nil } else { pane.show(nil) }
            }
        }
        persistWorkspace()
    }

    // MARK: Selection

    /// `graph`: a click in the graph selects the file and leaves the graph's folder alone.
    enum SelectionSource { case sidebar, graph, other }

    /// The one way to change what is showing. `anchor` moves the preview once it loads.
    func select(_ ref: FileRef?, anchor: FileAnchor? = nil, source: SelectionSource, record: Bool = true) {
        let before = undoWorkspaceSnapshot()
        defer {
            if record { recordWorkspaceChange("Navigate", before: before) }
        }
        if !openingVault, record { pendingWorkspaceSelection = nil }
        if source == .other, let ref, !restoringHistory { selectedFolder = ref.directory }
        selectionFromSidebar = source == .sidebar
        recordInHistory = record
        pendingAnchor = anchor ?? ref.flatMap { activePane.anchors[$0.relativePath] ?? savedAnchors[$0.relativePath] }
        if ref == selected {
            // Same file: only the anchor moves.
            if let anchor = pendingAnchor { jumpToAnchor(anchor) }
            if source == .other, let ref { revealRequest = RevealRequest(file: ref) }
        } else {
            selected = ref
        }
        selectionFromSidebar = false
        recordInHistory = true
        pendingAnchor = nil
    }

    private func selectionChanged() {
        selectedCommentID = nil
        sourceHighlight = ""
        navigator = nil
        anchor = nil
        sections = []
        comments = []
        jumpRequest = nil
        if let v = vault, !openingVault { Defaults.setLastSelected(selected, in: v) }
        guard let ref = selected else {
            openedTask?.cancel()
            persistWorkspace()
            return
        }
        if !openFiles.contains(ref) { openFiles.append(ref); if openFiles.count > 16 { openFiles.removeFirst() } }
        if recordInHistory {
            history.push(History.Entry(file: ref, anchor: pendingAnchor, mode: mode, folder: selectedFolder, transient: selectionFromSidebar))
        }
        if let a = pendingAnchor { jumpToAnchor(a) }
        if !selectionFromSidebar { revealRequest = RevealRequest(file: ref) }
        Task { await refreshComments() }
        Task { await refreshSections() }
        scheduleOpenedEvent(for: ref)
        persistWorkspace()
    }

    /// Moves the preview (if it can) and the current anchor. Comment chips land here.
    func jumpToAnchor(_ a: FileAnchor) {
        guard let ref = selected else { return }
        sourceHighlight = ""; selectedCommentID = nil
        anchor = a
        jumpRequest = JumpRequest(file: ref, anchor: a)
        navigator?.jump(to: a)
    }

    func clearSourceJump() { jumpRequest = nil; anchor = nil; sourceHighlight = "" }

    /// From graph, trail, ask, search, or a wikilink: show this file here.
    func jump(to ref: FileRef, anchor: FileAnchor?) {
        mode = .files
        select(ref, anchor: anchor, source: .other)
    }

    /// A clicked wikilink from the rail: `q3.pptx#slide 2` → that file at that anchor.
    func openLink(_ raw: String, from source: FileRef? = nil) {
        guard let v = vault else { return }
        if openThoughtLink(raw, from: source) { return }
        let target = Wikilink.components(of: raw).target
        let anchor = Wikilink.anchor(in: raw)
        let file = (source ?? selected).flatMap { Wikilink.resolve(target, from: $0, in: v, candidates: files) }
            ?? Wikilink.resolve(target, in: v, candidates: files)
        guard let file else {
            showToast(ToastMessage(text: "Couldn’t find linked file: " + target, action: "Search", perform: { [weak self] in self?.showSidebarSearch(target) }))
            return
        }
        jump(to: file, anchor: anchor)
    }

    private func scheduleOpenedEvent(for ref: FileRef) {
        openedTask?.cancel()
        guard let s = session else { return }
        openedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.selected == ref, self.session === s else { return }
            self.establishWorkingIdentity(for: ref)
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
        if e.file == nil {
            // The folder surface goes back to where it was: a place outside the vault, or
            // the sidebar's folder (keeping the columns' selection when it is still inside).
            // A results list comes back as it was left.
            if let results = e.results { restoreResults(results) }
            else if let place = e.place { browser.browse(place, following: sidebarFolderURL) }
            else if let folder = sidebarFolderURL { browser.follow(folder, force: true) }
        }
        if let f = e.file {
            select(f, anchor: e.anchor, source: .other, record: false)
        } else if selected != nil {
            select(nil, source: .other, record: false)
        }
    }

    /// The sidebar's selection in one step: the folder (a folder row, or the file's parent)
    /// and the file, so a folder-only selection is one history entry rather than two.
    func selectFromSidebar(folder: String?, file: FileRef?) {
        if columnsSelection != nil { columnsSelection = nil }
        if selectedFolder != folder { selectedFolder = folder }
        if file == nil, selected == nil, !restoringHistory {
            history.push(History.Entry(file: nil, anchor: nil, mode: mode, folder: folder, transient: true))
        }
        select(file, source: .sidebar)
        persistWorkspace()
    }

    /// A folder outside the vault shown in the folder surface gets a history entry of its own.
    func recordPlace(_ url: URL) {
        history.push(History.Entry(file: nil, anchor: nil, mode: mode, folder: selectedFolder, place: url))
    }

    /// A search results list gets an entry of its own (AppState+SearchResults.swift).
    func recordResults(_ results: SearchResultsPlace) {
        history.push(History.Entry(file: nil, anchor: nil, mode: mode, folder: selectedFolder, results: results))
    }

    /// Trail "resume": the files of a session become the history, oldest first.
    func resume(_ files: [FileRef]) {
        resumeLocations(files.map { TrailLocation(file: $0, anchor: nil) })
    }

    func resumeLocations(_ locations: [TrailLocation]) {
        let present = locations.filter { vault?.exists($0.file) == true }
        guard let last = present.last else { return }
        restoringHistory = true
        defer { restoringHistory = false; persistWorkspace() }
        history.restore(entries: present.map { History.Entry(file: $0.file, anchor: $0.anchor, mode: .files, folder: $0.file.directory) }, index: present.count - 1)
        openFiles = present.map(\.file)
        for location in present { if let a = location.anchor { savedAnchors[location.file.relativePath] = a } }
        mode = .files
        selectedFolder = last.file.directory
        select(last.file, anchor: last.anchor, source: .other, record: false)
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
        jumpToAnchor(anchors[next])
    }

    var hasAnchors: Bool { navigator != nil || !sections.isEmpty }

    // MARK: Modes

    private func modeChanged() {
        if !restoringHistory && !openingVault {
            history.push(History.Entry(file: selected, anchor: anchor, mode: mode, folder: selectedFolder))
        }
        if mode == .graph, graphStale { graphTask?.cancel(); graphTask = nil; Task { await refreshGraph() } }
        persistWorkspace()
    }

    /// Opens the right sidebar on `tab`.
    func showInspector(_ tab: InspectorTab) {
        inspectorTab = tab
        if !railShown {
            withAnimation(Theme.Motion.normal) {
                railVisible = true
                railPinned = windowWidth < AppState.narrowWindow
            }
        }
    }

    /// Graph mode, playing the vault's history.
    func replayGraph() {
        mode = .graph
        graphReplayRequest &+= 1
    }

    /// Graph mode, laid out as `arrangement`.
    func showGraphArrangement(_ arrangement: GraphArrangement) {
        graphArrangement = arrangement
        if mode != .graph { mode = .graph }
    }

    /// The chat, from anywhere: opens the right sidebar on it and puts the keys in its field.
    func focusChat() {
        // Request first: opening the sidebar can mount the chat synchronously, and it reads
        // the request as it appears.
        chatFocusRequest &+= 1
        showInspector(.chat)
    }

    func toggleRail() {
        let previous = [railVisible, railPinned]
        defer { recordSetting("Toggle Comments", before: previous, after: [railVisible, railPinned]) { [weak self] in self?.railVisible = $0[0]; self?.railPinned = $0[1] } }
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
        Task {
            do { try await saveComment(comment, to: file) } catch { report(error) }
        }
    }

    func saveComment(_ comment: Comment, to file: FileRef) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        let comment = comment.stamped()
        try changeComments(in: s, files: [file], name: "Add Thought") { try s.sidecar.append(comment, to: file) }
        s.trail.recordComment(comment, on: file)
        thoughtDidSave(comment, in: file, session: s)   // the save is done; the index may still be busy
        await commentsDidChange(for: file, in: s)
    }

    /// A thought just landed on `file`: show the connections it made where they can be seen.
    /// In Graph mode the graph settles on them and draws them in; anywhere else the graph
    /// appears in the corner to do it. A thought that links nothing gets only its chime.
    func celebrate(_ comment: Comment, on file: FileRef) {
        let level = ThoughtStrength(comment).rawValue
        var targets: [FileRef] = []
        if let v = vault {
            for raw in comment.links {
                let target = Wikilink.components(of: raw).target
                guard let f = Wikilink.resolve(target, from: file, in: v, candidates: files),
                      f != file, !targets.contains(f) else { continue }
                targets.append(f)
            }
        }
        celebrationCount &+= 1
        let c = GraphCelebration(id: celebrationCount, source: file, targets: targets, level: level)
        if mode == .graph, let window = NSApp.windows.first(where: { $0 is MainWindow }), ConnectionPiP.inWindow(window) {
            graphCelebration = c
        } else if !targets.isEmpty {
            showConnectionPiP(c)
        } else {
            Chime.play(level: level)
        }
    }

    /// The graph couldn't show it (its files are outside the graph's folder): the corner can.
    func celebrationMissed(_ c: GraphCelebration) {
        if c.targets.isEmpty { Chime.play(level: c.level) } else { showConnectionPiP(c) }
    }

    private func showConnectionPiP(_ c: GraphCelebration) {
        ConnectionPiP.shared.onOpen = { [weak self] file in
            NSApp.activate()
            self?.select(file, source: .other)
            self?.mode = .graph
        }
        pendingPiP = c
        guard graph.nodes.isEmpty, session != nil else { return showPendingPiP(c.id) }
        // Nothing has shown the graph this session, so it was never built. Give the build a
        // moment so the corner shows the file's neighbors, not just the pair.
        Task { [weak self] in await self?.refreshGraph(); self?.showPendingPiP(c.id) }
        Task { [weak self] in try? await Task.sleep(for: .milliseconds(450)); self?.showPendingPiP(c.id) }
    }

    private var pendingPiP: GraphCelebration?

    private func showPendingPiP(_ id: Int) {
        guard let c = pendingPiP, c.id == id else { return }
        pendingPiP = nil
        ConnectionPiP.shared.show(c, in: graph, over: NSApp.windows.first { $0 is MainWindow })
    }

    func attachInboxThought(_ comment: Comment, from source: FileRef, to target: FileRef) async throws {
        guard let s = session, source != target, s.vault.exists(target) else { throw CocoaError(.fileNoSuchFile) }
        var attached = comment
        attached.anchor = nil // An external app's location is not a location in the destination file.
        try changeComments(in: s, files: [source, target], name: "Attach Thought") {
            let destination = try s.sidecar.document(for: target)
            try s.sidecar.append(attached, to: target)
            do { try s.sidecar.delete(comment.id, from: source) }
            catch {
                if let destination { try s.sidecar.save(destination, for: target) }
                else { try s.sidecar.removeSidecar(for: target) }
                throw error
            }
        }
        s.trail.recordComment(attached, on: target)
        await commentsDidChange(for: target, in: s)
        await commentsDidChange(for: source, in: s)
    }

    func saveEditedComment(_ comment: Comment, in file: FileRef) async throws {
        try await saveEditedThought(comment, in: file)
    }

    func saveDeletedComment(_ comment: Comment, from file: FileRef) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        try changeComments(in: s, files: [file], name: "Delete Thought") { try s.sidecar.delete(comment.id, from: file) }
        await commentsDidChange(for: file, in: s)
    }

    /// Undo of a delete: the same comment comes back with its id and timestamp.
    func restoreComment(_ comment: Comment, to file: FileRef? = nil) {
        guard let file = file ?? selected else { return }
        Task { do { try await saveComment(comment, to: file) } catch { report(error) } }
    }

    func updateComment(_ comment: Comment, in file: FileRef) {
        Task { do { try await saveEditedComment(comment, in: file) } catch { report(error) } }
    }

    func deleteComment(_ comment: Comment, from file: FileRef) {
        Task { do { try await saveDeletedComment(comment, from: file) } catch { report(error) } }
    }

    func changeComments(in session: VaultSession, files: [FileRef], name: String, change: () throws -> Void) throws {
        let before = try files.map { try session.sidecar.document(for: $0) }
        try change()
        let after = try files.map { try session.sidecar.document(for: $0) }
        actionHistory.register(name: name, undo: { [weak self] in
            try self?.restoreComments(before, expecting: after, files: files, in: session)
        }, redo: { [weak self] in
            try self?.restoreComments(after, expecting: before, files: files, in: session)
        })
    }

    private func restoreComments(_ snapshots: [SidecarDocument?], expecting expected: [SidecarDocument?], files: [FileRef], in session: VaultSession) throws {
        guard self.session === session else { throw UndoFailure.changed }
        let current = try files.map { try session.sidecar.document(for: $0) }
        guard current == expected else { throw UndoFailure.changed }
        for i in files.indices where session.vault.exists(files[i]) {
            if let identity = expected[i]?.id ?? snapshots[i]?.id,
               try FileIdentity.existingID(for: session.vault.url(for: files[i])) != identity { throw UndoFailure.changed }
        }
        var completed = [Int]()
        do {
            for i in files.indices {
                try session.sidecar.replaceDocument(snapshots[i], for: files[i], expecting: expected[i])
                completed.append(i)
            }
        } catch {
            for i in completed.reversed() {
                try session.sidecar.replaceDocument(expected[i], for: files[i], expecting: snapshots[i])
            }
            throw error
        }
        if let selected, let i = files.firstIndex(of: selected) { comments = snapshots[i]?.comments ?? [] }
        for (i, file) in files.enumerated() { commentCounts[file] = snapshots[i]?.comments.count ?? 0 }
        Task { for file in files { await commentsDidChange(for: file, in: session) } }
    }

    func commentsDidChange(for file: FileRef, in s: VaultSession) async {
        guard session === s else { return }
        if file == selected { await refreshComments() }
        if isFolderNote(file) { await s.reloadNotes() } else { await s.update([file]) }   // re-ingests the sidecar into the index
        guard session === s else { return }
        await refreshCounts()
        markGraphStale(urgent: true)
        sidebarSearch.refresh()
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

    /// Walks every file: at launch when there is no checkpoint to resume from, after the
    /// watcher lost events (`eventsLost`), and on request. `force` (the menu command)
    /// re-extracts everything.
    func reindex(force: Bool = false, eventsLost: Bool = false) {
        guard let s = session else { return }
        if eventsLost { s.distrustCheckpoint() }
        guard indexStatus == nil else {
            indexing.pendingForce = (indexing.pendingForce ?? false) || force
            return
        }
        let runID = UUID()
        indexing.runID = runID
        indexing.status = VaultSession.IndexStatus(phase: .walking, force: force)
        runIndexPass(in: s, runID: runID) { progress in
            // The walk sets the checkpoint; re-reading stale rows can then stop at any time
            // and carry on after the next launch's replay.
            let walked = await s.reindex(force: force, progress: progress)
            guard walked == .completed else { return walked }
            return await s.refreshStale(through: nil, progress: progress)
        }
    }

    /// While the watcher replays what changed since the last run. A replay that never
    /// finishes (it takes seconds for a day of changes to a home folder) falls back to a walk.
    private func beginCatchUp(in s: VaultSession) {
        let runID = UUID()
        indexing.runID = runID
        indexing.status = VaultSession.IndexStatus(phase: .catchingUp)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.catchUpTimeout)
            guard let self, self.session === s, self.indexing.runID == runID, self.indexStatus?.phase == .catchingUp else { return }
            Log.debug("index: replay never finished; walking instead")
            self.indexing.status = nil
            self.reindex(eventsLost: true)
        }
    }

    static let catchUpTimeout: UInt64 = 600_000_000_000

    /// The replay is done: everything that changed while the vault was closed is applied.
    /// Re-read what an extractor update left stale, then finish like a walk would.
    private func caughtUp(through: UInt64?, in s: VaultSession) {
        guard session === s, indexStatus?.phase == .catchingUp else { return }
        let runID = indexing.runID
        indexing.status = VaultSession.IndexStatus(phase: .refreshing)
        runIndexPass(in: s, runID: runID) { progress in await s.refreshStale(through: through, progress: progress) }
    }

    /// Runs one indexing pass as `runID`, then restores the workspace, applies renames,
    /// refreshes what the index feeds, and starts any walk asked for meanwhile.
    private func runIndexPass(in s: VaultSession, runID: UUID,
                              _ pass: @escaping (@escaping @MainActor (VaultSession.IndexStatus) -> Void) async -> VaultSession.ReindexOutcome) {
        let cancellationGeneration = s.indexCancellationGeneration
        Task { [weak self] in
            let outcome = await pass { [weak self] status in
                guard let self, self.session === s, self.indexing.runID == runID, self.indexStatus != nil else { return }
                self.indexing.status = status
            }
            guard let self, self.session === s, self.indexing.runID == runID else { return }
            self.indexing.error = s.indexingError
            self.finishWorkspaceRestoration(in: s, indexOutcome: outcome)
            await self.applyIndexedRenames(in: s)
            guard self.session === s, self.indexing.runID == runID else { return }
            self.tree.reloadRules()
            await self.refreshSections()
            await self.refreshCounts()
            guard self.session === s, self.indexing.runID == runID else { return }
            self.indexing.status = nil
            self.sidebarSearch.refresh()
            self.markGraphStale()
            let pending = self.indexing.pendingForce
            self.indexing.pendingForce = nil
            // Pause applies to this run and any rescan queued before the pause.
            if let force = pending, outcome != .cancelled, s.indexCancellationGeneration == cancellationGeneration {
                self.reindex(force: force)
            }
        }
    }

    /// The graph feeds Graph mode and the local graph under the rail, so it is rebuilt
    /// whenever it goes stale, coalescing bursts; at once when Graph mode is on screen. A
    /// whole disk changes every few seconds, so there files changing on disk rebuild it at
    /// most every `slowGraphDelay`; a thought (`urgent`) still shows within a second or two.
    /// Something on screen draws from the graph: Graph mode, the Connections tab (its local
    /// graph and discovered evidence) or Wander. Otherwise a stale graph waits.
    var graphShown: Bool { mode == .graph || (railShown && inspectorTab == .connections) || wander != nil }

    /// A graph that went stale while nothing showed it is rebuilt as soon as something does.
    func refreshGraphIfShown() {
        guard graphStale, graphShown, graphTask == nil else { return }
        markGraphStale(urgent: true)
    }

    private func markGraphStale(urgent: Bool = false, trailOnly: Bool = false) {
        graphStale = true
        // Nothing shows it: don't spend seconds rebuilding a whole-disk graph per file opened.
        guard graphShown else { graphTask?.cancel(); graphTask = nil; return }
        let slow = !urgent && mode != .graph && files.count > Self.bigVault
        if slow, graphTask != nil { return }
        // Opening files only adds shared-session edges; let a run of opens settle first.
        if trailOnly, graphTask != nil { return }
        graphTask?.cancel()
        let delay: UInt64 = urgent ? 200_000_000 : trailOnly ? 5_000_000_000 : mode == .graph ? 300_000_000 : slow ? Self.slowGraphDelay : 1_500_000_000
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
        markGraphStale(trailOnly: true)
    }

    func refreshGraph() async {
        guard let s = session else { graph = Graph(); graphRevision &+= 1; return }
        let g = await s.buildGraph()
        guard session === s else { return }
        graph = g
        graphRevision &+= 1
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
        guard let file = ref ?? selected, let url = url(for: file) else { return }
        establishWorkingIdentity(for: file)
        trackedEditorFiles.insert(file)
        analyzedStamps[file] = PreviewKind.modificationDate(of: url)
        if !NSWorkspace.shared.open(url) { showToast(ToastMessage(text: "No editor opened this file. Choose an application in the file’s Open With menu.")) }
    }

    /// Identify only deliberately used files, so later native-editor renames can carry
    /// their working tabs, thoughts and links without guessing from filenames.
    func establishWorkingIdentity(for file: FileRef) {
        guard let s = session else { return }
        Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .utility) {
                    try FileIdentity.id(for: s.vault.url(for: file))
                }.value
                await s.update([file])
            } catch {
                guard let self, self.session === s else { return }
                self.showToast(ToastMessage(text: "Opened read-only · rename tracking unavailable for " + file.name))
            }
        }
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
        showToast(ToastMessage(text: error.localizedDescription))
    }

    // MARK: Commands (palette)

    var commands: [PaletteCommand] {
        let hasVault = vault != nil
        let hasFile = selected != nil
        var list: [PaletteCommand] = [
            PaletteCommand(id: "new-file", title: "New File…", keys: "⌘N", symbol: "doc.badge.plus", enabled: hasVault) { [weak self] in self?.showNewFile() },
            PaletteCommand(id: "connect-grid", title: "Connect Files", keys: "⌘J", symbol: "square.grid.3x3", enabled: hasVault) { [weak self] in self?.connectGridShown.toggle() },
            PaletteCommand(id: "health", title: "Workspace Health", keys: nil, symbol: "externaldrive", enabled: hasVault) { [weak self] in self?.isHealthPresented = true },
            PaletteCommand(id: "settings", title: "Settings…", keys: "⌘,", symbol: "gearshape") { [weak self] in
                if let self { SettingsWindowController.show(state: self) }
            },
            PaletteCommand(id: "shortcuts", title: "Keyboard Shortcuts", keys: "⌘/", symbol: "keyboard") { [weak self] in
                if let self { ShortcutsWindowController.toggle(captureKeys: self.captureGlobalKeys) }
            },
            PaletteCommand(id: "open", title: "Open Vault…", keys: "⌘O", symbol: "folder") { [weak self] in self?.openVaultDialog() },
            PaletteCommand(id: "search", title: "Search", keys: "⌘F", symbol: "magnifyingglass", enabled: hasVault) { [weak self] in self?.showPalette(.search) },
            PaletteCommand(id: "thought", title: "Leave a Thought", keys: "⌘⇧C", symbol: "text.bubble", enabled: hasVault) { [weak self] in self?.leaveThought() },
        ]
        for m in Mode.allCases {
            list.append(PaletteCommand(id: m.title.lowercased(), title: m.title, keys: "⌘\(m.rawValue + 1)", symbol: m.symbol, enabled: hasVault) { [weak self] in self?.mode = m })
        }
        for style in FolderStyle.allCases {
            list.append(PaletteCommand(id: "folder-" + style.rawValue, title: "View " + style.title, keys: "⌘⌥" + style.key, symbol: style.symbol, enabled: hasVault) { [weak self] in self?.showFolderStyle(style) })
        }
        for place in favorites.favorites {
            list.append(PaletteCommand(id: "go-" + place.url.path, title: "Go to " + place.name, keys: nil, symbol: "folder", enabled: hasVault) { [weak self] in self?.openFavorite(place.url) })
        }
        list += paneCommands
        list += thoughtCommands
        list += briefingCommands
        list += GraphArrangement.allCases.map { a in
            PaletteCommand(id: "graph-" + a.rawValue, title: "Graph Layout: " + a.title, keys: nil, symbol: a.symbol, enabled: hasVault) { [weak self] in self?.showGraphArrangement(a) }
        }
        list += [
            PaletteCommand(id: "split", title: splitVisible ? "Close Split View" : "Split View", keys: "⌘\\", symbol: "rectangle.split.2x1", enabled: hasVault) { [weak self] in self?.toggleSplit() },
            PaletteCommand(id: "open-beside", title: "Open Beside", keys: nil, symbol: "rectangle.split.2x1", enabled: hasFile) { [weak self] in if let self, let file = self.selected { self.openBeside(file, anchor: self.anchor) } },
            PaletteCommand(id: "rail", title: railShown ? "Hide Inspector" : "Show Inspector", keys: "⌘⌥I", symbol: "sidebar.right") { [weak self] in self?.toggleRail() },
            PaletteCommand(id: "tab-thoughts", title: "Inspector: Thoughts", keys: nil, symbol: InspectorTab.thoughts.symbol, enabled: hasVault) { [weak self] in self?.showInspector(.thoughts) },
            PaletteCommand(id: "tab-connections", title: "Inspector: Connections", keys: nil, symbol: InspectorTab.connections.symbol, enabled: hasVault) { [weak self] in self?.showInspector(.connections) },
            PaletteCommand(id: "tab-outline", title: "Inspector: Outline", keys: nil, symbol: InspectorTab.outline.symbol, enabled: hasVault) { [weak self] in self?.showInspector(.outline) },
            PaletteCommand(id: "wander", title: "Wander Suggestions", keys: nil, symbol: "dice", enabled: hasVault) { [weak self] in self?.startWander() },
            PaletteCommand(id: "replay", title: "Replay Graph History", keys: nil, symbol: "play", enabled: hasVault) { [weak self] in self?.replayGraph() },
            PaletteCommand(id: "resurface", title: "Resurface a Thought", keys: nil, symbol: "clock.arrow.circlepath", enabled: hasVault) { [weak self] in self?.resurfaceThought() },
            PaletteCommand(id: "analyze", title: "Analyze File", keys: nil, symbol: "sparkles", enabled: hasFile && askEngine != nil) { [weak self] in if let self, let file = self.selected { self.analyzeSavedFile(file) } },
            PaletteCommand(id: "back", title: "Back", keys: "⌘[", symbol: "chevron.left", enabled: canGoBack) { [weak self] in self?.goBack() },
            PaletteCommand(id: "forward", title: "Forward", keys: "⌘]", symbol: "chevron.right", enabled: canGoForward) { [weak self] in self?.goForward() },
            PaletteCommand(id: "prev", title: "Previous Page", keys: "⌘↑", symbol: "arrow.up", enabled: hasAnchors) { [weak self] in self?.stepAnchor(-1) },
            PaletteCommand(id: "next", title: "Next Page", keys: "⌘↓", symbol: "arrow.down", enabled: hasAnchors) { [weak self] in self?.stepAnchor(1) },
            PaletteCommand(id: "openwith", title: "Open in " + (defaultAppName(for: selected) ?? "Default App"), keys: "⌘↩", symbol: "arrow.up.forward.app", enabled: hasFile) { [weak self] in self?.openExternally() },
            PaletteCommand(id: "reveal", title: "Reveal in Finder", keys: "⌘⇧R", symbol: "finder", enabled: hasFile) { [weak self] in self?.revealInFinder() },
            PaletteCommand(id: "copyfile", title: "Copy File", keys: nil, symbol: "doc.on.doc", enabled: hasFile) { [weak self] in _ = self?.copyFiles() },
            PaletteCommand(id: "copypath", title: "Copy Path", keys: nil, symbol: "doc.on.doc", enabled: hasFile) { [weak self] in self?.copyPath() },
            PaletteCommand(id: "newnote", title: "Create New Note", keys: "⌥⌘N", symbol: "square.and.pencil", enabled: hasVault) { [weak self] in self?.newNote() },
            PaletteCommand(id: "newfolder", title: "Create New Folder", keys: "⌘⇧N", symbol: "folder.badge.plus", enabled: hasVault) { [weak self] in self?.newFolder() },
            PaletteCommand(id: "bookmark", title: isBookmarked(selected?.relativePath ?? "", folder: false) && hasFile ? "Remove Bookmark" : "Bookmark Current File", keys: "⌘D", symbol: "bookmark", enabled: hasFile) { [weak self] in self?.toggleBookmarkCurrent() },
            PaletteCommand(id: "bookmarkfolder", title: "Bookmark…", keys: nil, symbol: "bookmark", enabled: hasVault) { [weak self] in self?.bookmarkFolderDialog() },
            PaletteCommand(id: "bookmarkgroup", title: "Bookmarks: New Group", keys: nil, symbol: "folder.badge.plus", enabled: hasVault) { [weak self] in self?.addBookmarkGroup() },
            PaletteCommand(id: "sidebar", title: sidebarCollapsed ? "Show Left Sidebar" : "Hide Left Sidebar", keys: "⌃⌘S", symbol: "sidebar.left") { [weak self] in self?.toggleSidebar() },
            PaletteCommand(id: "explorer", title: "Files: Show File Explorer", keys: nil, symbol: "folder", enabled: hasVault) { [weak self] in self?.showSidebarTab(.files) },
            PaletteCommand(id: "searchall", title: "Search in All Files", keys: "⌘⇧F", symbol: "magnifyingglass", enabled: hasVault) { [weak self] in self?.showSidebarSearch() },
            PaletteCommand(id: "bookmarks", title: "Bookmarks: Show Bookmarks", keys: nil, symbol: "bookmark", enabled: hasVault) { [weak self] in self?.showSidebarTab(.bookmarks) },
            PaletteCommand(id: "revealnav", title: "Reveal Current File in Navigation", keys: "⌘⇧J", symbol: "scope", enabled: hasFile) { [weak self] in self?.revealCurrentFile() },
            PaletteCommand(id: "random", title: "Open Random File", keys: nil, symbol: "dice", enabled: hasVault && !files.isEmpty) { [weak self] in self?.openRandomFile() },
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

/// Indexing progress: the hairline, the palette and Workspace Health observe it.
@MainActor
final class IndexingModel: ObservableObject {
    @Published var status: VaultSession.IndexStatus?
    @Published var error: String?
    var pendingForce: Bool?
    var runID = UUID()
}


private enum UndoFailure: LocalizedError {
    case changed, failed
    var errorDescription: String? {
        switch self {
        case .changed: "Undo stopped because this item changed outside Flamingo. Your current files are untouched."
        case .failed: "The action could not be reversed. Resolve the issue and try Undo again."
        }
    }
}

extension AppState {
    func undoAction(_ id: UUID? = nil) {
        do {
            let done = try id.map { try actionHistory.undo(id: $0) } ?? actionHistory.undo()
            if done { dismissToast() }
        } catch { report(error) }
    }

    func redoAction() {
        do { if try actionHistory.redo() { dismissToast() } } catch { report(error) }
    }

    func recordSetting<T: Equatable>(_ name: String, before: T, after: T, apply: @escaping @MainActor (T) -> Void) {
        guard before != after, !openingVault, !suppressActionHistory else { return }
        actionHistory.register(name: name, undo: { apply(before) }, redo: { apply(after) })
    }

    private func checkIdentity(_ path: String, vault: Vault, device: UInt64, inode: UInt64) throws {
        let current = try FileTrash.inspect(path, in: vault)
        guard current.device == device, current.inode == inode else { throw UndoFailure.changed }
    }

    func recordWorkspaceChange(_ name: String, before: WorkspaceSnapshot) {
        guard !openingVault, !suppressActionHistory, !actionHistory.isApplying else { return }
        let after = undoWorkspaceSnapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let old = try? encoder.encode(before), let new = try? encoder.encode(after), old != new else { return }
        actionHistory.register(name: name, undo: { [weak self] in self?.restoreUndoWorkspace(before) }, redo: { [weak self] in self?.restoreUndoWorkspace(after) })
    }

    func undoWorkspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(selected: selected, folder: selectedFolder, mode: mode.rawValue, anchors: savedAnchors, openFiles: openFiles, history: SavedHistory(history),
                          split: savedSplit())
    }

    func restoreUndoWorkspace(_ snapshot: WorkspaceSnapshot) {
        guard let vault else { return }
        suppressActionHistory = true
        defer { suppressActionHistory = false }
        if let split = snapshot.split {
            synchronizingPane = true
            restoreSplit(split, in: vault)
            synchronizingPane = false
        }
        openFiles = snapshot.openFiles.filter { vault.exists($0) }
        savedAnchors = snapshot.anchors
        selectedFolder = snapshot.folder
        mode = Mode(rawValue: snapshot.mode) ?? .files
        select(snapshot.selected.flatMap { vault.exists($0) ? $0 : nil }, source: .other, record: false)
        selectedFolder = snapshot.folder
        history = snapshot.history.restored(in: vault)
        persistWorkspace()
    }

    private func restoreDeletedWorkspace(_ snapshot: WorkspaceSnapshot, files restored: [FileRef], path: String) {
        setFiles(Array(Set(files + restored)))
        noteFoldersChanged([path, (path as NSString).deletingLastPathComponent])
        restoreUndoWorkspace(snapshot)
        if let session { Task { _ = await session.update(restored); filesChanged(restored, in: session) } }
    }

    private func registerCreation(_ path: String, in vault: Vault) {
        guard let target = try? FileTrash.inspect(path, in: vault) else { return }
        let original = target.isEmptyFolder ? nil : try? Data(contentsOf: target.url)
        let workspace = undoWorkspaceSnapshot()
        var receipt: FileTrash.Receipt?
        actionHistory.register(name: target.isEmptyFolder ? "Create Folder" : "Create File", undo: { [weak self] in
            guard let self, self.vault == vault else { throw UndoFailure.changed }
            try self.checkIdentity(path, vault: vault, device: target.device, inode: target.inode)
            let current = try FileTrash.inspect(path, in: vault)
            guard target.isEmptyFolder ? current.isEmptyFolder : (try Data(contentsOf: target.url)) == original else { throw UndoFailure.changed }
            guard !self.textBuffers.contains(where: { FileTree.contains(path, $0.key) && ($0.value.dirty || $0.value.saving) }) else { throw UndoFailure.changed }
            guard self.trash(current, confirmed: true, trashItem: { url in
                let destination = try FileTrash.trashURL(for: url)
                receipt = try FileTrash.Receipt(target: current, trashURL: destination)
                return destination
            }) else { throw UndoFailure.failed }
            self.restoreUndoWorkspace(workspace)
        }, redo: { [weak self] in
            guard let self, self.vault == vault, let receipt else { throw UndoFailure.changed }
            try receipt.restore()
            let file = FileRef(relativePath: path)
            self.noteFoldersChanged([(path as NSString).deletingLastPathComponent])
            if target.isEmptyFolder { self.selectFromSidebar(folder: path, file: nil) }
            else { self.setFiles(Array(Set(self.files + [file]))); self.select(file, source: .other) }
        })
    }
}
