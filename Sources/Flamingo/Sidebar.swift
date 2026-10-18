import AppKit
import Quartz
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The left sidebar's tabs, as in Obsidian: the file explorer, search, bookmarks.
enum SidebarTab: String, CaseIterable, Identifiable {
    case files, search, bookmarks
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .bookmarks: "bookmark"
        }
    }

    var title: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .bookmarks: "Bookmarks"
        }
    }
}

/// Obsidian's left side: a ribbon of actions down the window's edge, and beside it a panel
/// with tabs for the file explorer, search and bookmarks, the vault switcher at its foot.
/// The tab icons share the title bar with the traffic lights; the toggle beside them folds
/// the panel away and leaves the ribbon. Plan 01 owns.
struct Sidebar: View {
    @Environment(AppState.self) var state
    let topInset: CGFloat

    /// Room the traffic lights take at the window's left edge.
    static let trafficLights: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Color.clear.frame(width: Sidebar.trafficLights - Theme.Space.xs)
                if !state.sidebarCollapsed {
                    SidebarToggle()
                    Spacer(minLength: Theme.Space.s)
                    SidebarTabs()
                }
            }
            .padding(.trailing, Theme.Space.s)
            .frame(height: topInset)
            HStack(spacing: 0) {
                Ribbon()
                    .frame(width: Ribbon.width)
                if !state.sidebarCollapsed {
                    VHairline()
                    SidebarPanel()
                }
            }
        }
        .background(VisualEffect(.sidebar))
        .disabled(state.vault == nil)
    }

    /// The whole sidebar's width: the ribbon, and the panel when it is open.
    static func width(_ state: AppState) -> CGFloat {
        state.sidebarCollapsed ? Ribbon.width : Ribbon.width + Theme.Size.hairline + state.sidebarWidth
    }
}

/// Folds the panel away, or brings it back (⌃⌘S).
struct SidebarToggle: View {
    @Environment(AppState.self) var state

    var body: some View {
        IconButton("sidebar.left", help: state.sidebarCollapsed ? "Expand" : "Collapse") { state.toggleSidebar() }
    }
}

/// Files, Search, Bookmarks.
private struct SidebarTabs: View {
    @Environment(AppState.self) var state
    @Namespace private var tabs

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                IconButton(tab.symbol, help: tab.title, isOn: state.sidebarTab == tab) { state.sidebarTab = tab }
                    .background {
                        // One raised tile that glides to the tab picked.
                        if state.sidebarTab == tab {
                            Squircle(radius: Theme.Radius.s)
                                .fill(Theme.Color.hover)
                                .matchedGeometryEffect(id: "tab", in: tabs)
                        }
                    }
            }
        }
        .animation(Theme.Motion.glide, value: state.sidebarTab)
    }
}

/// The column of actions down the left edge.
struct Ribbon: View {
    @Environment(AppState.self) var state
    static let width: CGFloat = 44

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            IconButton("command", help: "Open command palette") { state.showPalette(.commands) }
            FinderColumnsButton(browser: state.browser)
            ForEach([AppState.Mode.graph, .trail, .ask]) { m in
                IconButton(m.symbol, help: "Open " + m.title.lowercased(),
                           isOn: m == .ask ? state.railShown && state.inspectorTab == .chat : state.mode == m) {
                    if m == .ask { state.focusChat() } else { state.mode = state.mode == m ? .files : m }
                }
            }
            IconButton("plus.bubble", help: "Leave a thought") { state.leaveThought() }
            IconButton("square.and.pencil", help: "Create new note") { state.newNote() }
            IconButton("dice", help: "Open random file") { state.openRandomFile() }
            Spacer(minLength: 0)
            IconButton("tray", help: "Inbox", isOn: state.briefingShown) { state.showBriefing() }
        }
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
        .frame(maxHeight: .infinity)
    }
}

/// Finder's column view of the current folder, with the open file selected in it; pressed
/// again, back to the file.
private struct FinderColumnsButton: View {
    @Environment(AppState.self) var state
    @ObservedObject var browser: ColumnBrowserModel

    var body: some View {
        IconButton(FolderStyle.columns.symbol, help: "Show in Finder columns",
                   isOn: state.mode == .files && state.selected == nil && browser.style == .columns) {
            state.toggleFinderColumns()
        }
    }
}

/// The open tab, and the vault switcher under it.
private struct SidebarPanel: View {
    @Environment(AppState.self) var state

    var body: some View {
        VStack(spacing: 0) {
            switch state.sidebarTab {
            case .files:
                FileExplorerHeader()
                FavoritesList(favorites: state.favorites, browser: state.browser)
                FileExplorer()
            case .search:
                SidebarSearchPane(model: state.sidebarSearch)
            case .bookmarks:
                BookmarksHeader()
                BookmarksPane()
            }
            Hairline()
            VaultSwitcher()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A centred row of small actions at the top of a tab, like Obsidian's nav buttons.
struct PaneActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2) { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
    }
}

/// An icon that opens a menu, sized and coloured like `IconButton`.
struct IconMenu<Content: View>: View {
    let systemName: String
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.Color.textSecondary)
        .frame(width: 24, height: 24)
        .opacity(hovering ? 1 : Theme.Opacity.rest)
        .onHover { hovering = $0 }
        .pressFeedback(shade: Theme.Radius.m - 2)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// New note, new folder, sort order, reveal the open file, collapse all.
private struct FileExplorerHeader: View {
    @Environment(AppState.self) var state

    var body: some View {
        let hasFile = state.selected != nil
        PaneActions {
            IconButton("square.and.pencil", help: "New note") { state.newNote() }
            IconButton("folder.badge.plus", help: "New folder") { state.newFolder() }
            IconMenu(systemName: "arrow.up.arrow.down", help: "Change sort order") {
                ForEach(0..<3) { group in
                    if group > 0 { Divider() }
                    ForEach(FileSort.allCases.filter { $0.group == group }, id: \.self) { sort in
                        Toggle(sort.title, isOn: Binding(get: { state.fileSort == sort }, set: { if $0 { state.fileSort = sort } }))
                    }
                }
            }
            // Goes to the open file: its folders open, the list scrolls to it, the row pulses.
            // Whether the list follows by itself is a setting (Settings, General).
            IconButton("scope", help: "Reveal current file") { state.revealCurrentFile() }
                .disabled(!hasFile)
                .allowsHitTesting(hasFile)
                .opacity(hasFile ? 1 : Theme.Opacity.disabled / Theme.Opacity.rest)
            IconButton("arrow.down.right.and.arrow.up.left", help: "Collapse all") { state.collapseAll(in: .files) }
        }
    }
}

/// The vault's name; click for the other vaults.
private struct VaultSwitcher: View {
    @Environment(AppState.self) var state
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Defaults.recentVaultTitles(), id: \.path) { recent in
                    Toggle(recent.title, isOn: Binding(get: { recent.path == state.vault?.root.path },
                                                       set: { _ in state.open(URL(fileURLWithPath: recent.path)) }))
                }
                Divider()
                Button("Open Another Vault…") { state.openVaultDialog() }
                Button("Reveal Vault in Finder") {
                    if let root = state.vault?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text(state.vault?.name ?? "No vault")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.Color.text)
            .fixedSize()
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(Squircle(radius: Theme.Radius.s)
                .fill(Theme.Color.hover).opacity(hovering ? 1 : 0))
            .onHover { hovering = $0 }
            .help("Switch vault")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: 36)
        .animation(Theme.Motion.fast, value: hovering)
    }
}

// MARK: - File explorer

/// The whole vault as a tree, each folder listed from disk when it is first opened. An
/// `NSOutlineView` so arrow keys, ←/→, type-to-select, scrolling and drag and drop are the
/// system's; each visible row hosts a `SidebarRow` so glyphs and type come from
/// `FlamingoDesign`. Drag a file or folder onto a folder to move it there, or drop files
/// from Finder; ↩ renames, ⌘V pastes, ⌘Y is Quick Look; the context menu is the columns'
/// (`FileMenu`). It follows what the columns select, and folders close again after a
/// while left alone.
struct FileExplorer: View {
    @Environment(AppState.self) var state

    var body: some View {
        FileExplorerOutline(state: state, tree: state.tree, revision: state.treeRevision, selected: state.selected,
                            selectedFolder: state.selectedFolder, columnsSelection: state.columnsSelection, bookmarks: state.bookmarks,
                            reveal: state.revealRequest, collapse: state.collapseRequest.flatMap { $0.tab == .files ? $0.id : nil },
                            rename: state.renameRequest, autoReveal: state.autoReveal)
    }
}

private struct FileExplorerOutline: NSViewRepresentable {
    let state: AppState
    let tree: FileTree
    let revision: Int
    let selected: FileRef?
    let selectedFolder: String?
    let columnsSelection: String?
    let bookmarks: Bookmarks
    let reveal: RevealRequest?
    let collapse: UUID?
    let rename: RenameRequest?
    let autoReveal: Bool

    func makeCoordinator() -> FileExplorerCoordinator { FileExplorerCoordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView.make(label: "Files")
        outline.registerForDraggedTypes([FileExplorerCoordinator.pathType, .fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(FileExplorerCoordinator.clicked(_:))
        outline.doubleAction = #selector(FileExplorerCoordinator.doubleClicked(_:))
        outline.menuOnEmptySpace = true
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu

        let scroll = SidebarOutlineView.scroll(outline)
        coordinator.install(outline: outline, scroll: scroll)
        state.focusSidebar = { [weak outline] in
            guard let outline, let window = outline.window else { return }
            window.makeFirstResponder(outline)
        }
        coordinator.apply(self)
        // Back from Search or Bookmarks, or unfolded: the list starts where the open file is.
        coordinator.showSelectionOnceLaidOut()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    /// Takes the space it is offered. Left to measure it, SwiftUI asks Auto Layout, which
    /// walks every row on each update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - Coordinator

@MainActor
private final class FileExplorerCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// A file or folder dragged inside the explorer; the string is its relative path.
    static let pathType = FileHandoff.relativePathType
    private static let cellID = NSUserInterfaceItemIdentifier("sidebar.cell")
    private static let rowID = NSUserInterfaceItemIdentifier("sidebar.row")

    let state: AppState
    private var outline: SidebarOutlineView!
    private var scroll: NSScrollView!

    private var tree = FileTree.empty
    private var vault: Vault? { tree.vault }
    private var revision = 0
    /// Expanded folder paths. Kept across rebuilds and persisted per vault.
    private var expanded: Set<String> = []
    private var lastSelected: FileRef?
    private var lastFolder: String?
    private var lastColumns: String?
    /// Folders open only because the columns went into them. They close again when the
    /// columns leave, so the tree shows the columns' way; folders opened here stay.
    private var columnsOpened: Set<String> = []
    /// The row last picked in the explorer itself. The columns follow it there; the explorer
    /// doesn't then open it, as a pick elsewhere would.
    private var pickedHere: String?
    private var showAllFolders = false
    private var rootItems: [AnyObject] = []
    private let pinnedHeader = ExplorerSection("Pinned")
    private let foldersHeader = ExplorerSection("Other folders")
    private let filesHeader = ExplorerSection("Files")
    private let moreFolders = ExplorerFolderToggle()
    private let divider = ExplorerSection("")

    private var pinPaths: [String] {
        state.bookmarks.all.compactMap { $0.bookmark.kind == .folder ? $0.bookmark.path : nil }
    }
    /// The open file, else what the columns have selected, else the sidebar's folder.
    private var selectionPath: String? { state.selected?.relativePath ?? state.columnsSelection ?? state.selectedFolder }
    /// True while the outline's selection is being changed programmatically.
    private var suppressSelection = false
    /// True while a reload restores expansion, so nothing is persisted mid-way.
    private var restoring = false
    /// Clearing the row highlight must survive watcher refreshes without closing the preview.
    private var selectionCleared = false
    /// A row shown in Quick Look from its context menu, without selecting (opening) it.
    private var quickLookNode: FileNode?

    /// Folders close after this long without the explorer being used or led anywhere, all
    /// but the way to the current place, so it doesn't keep open every folder it went through.
    static let idleCollapse: TimeInterval = 30
    private var lastActivity = Date()
    private var idleCheck: DispatchWorkItem?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func install(outline: SidebarOutlineView, scroll: NSScrollView) {
        self.outline = outline
        self.scroll = scroll
        outline.onCommandDelete = { [weak self] in
            guard let self, let node = self.selectedNode, !node.id.isEmpty else { return false }
            self.state.requestTrash(node.id, in: self.outline.window)
            return true
        }
        outline.onClearSelection = { [weak self] in self?.selectionCleared = true }
        outline.onCopy = { [weak self] in
            guard let self, let node = self.selectedNode else { return false }
            return self.state.copyFiles([FileRef(relativePath: node.id)])
        }
        outline.onReturn = { [weak self] in
            guard let self, let node = self.selectedNode, !node.id.isEmpty else { return false }
            self.beginRename(node)
            return true
        }
        outline.onPaste = { [weak self] moving in
            guard let self, let v = self.vault else { return false }
            var folder = self.selectedNode
            if let f = folder, !f.isFolder { folder = f.parent }
            self.state.paste(into: self.url(of: folder) ?? v.root, moving: moving)
            return true
        }
        outline.quickLookURL = { [weak self] in
            guard let self, let node = self.quickLookNode ?? self.selectedNode else { return nil }
            return self.url(of: node)
        }
        outline.onActivity = { [weak self] in self?.noteActivity() }
        if Log.enabled {
            FileExplorerQA.status = { [weak self] in self?.qaStatus() ?? "unmounted" }
            FileExplorerQA.collapseIdle = { [weak self] in self?.collapseIdle() }
            FileExplorerQA.scroll = { [weak self] y in
                guard let self else { return }
                self.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        }
    }

    /// For `sidebar status`: the selected row, and whether it is fully inside the visible area.
    private func qaStatus() -> String {
        let row = outline.selectedRow
        let clip = scroll.contentView.bounds, insets = scroll.contentInsets
        var place = "none"
        if row >= 0 {
            let r = outline.rect(ofRow: row)
            let top = clip.minY + insets.top, bottom = clip.maxY - insets.bottom
            let shown = r.minY >= top - 0.5 && r.maxY <= bottom + 0.5
            place = (shown ? "visible" : "hidden") + String(format: " at=%.2f", (r.midY - top) / max(1, bottom - top))
        }
        return "row=\(row) id=\(selectedNode?.id ?? "-") \(place) rows=\(outline.numberOfRows) y=\(Int(clip.minY)) h=\(Int(clip.height)) docH=\(Int(outline.frame.height)) window=\(outline.window != nil)"
    }

    /// Where a row is on disk.
    private func url(of node: FileNode?) -> URL? {
        guard let v = vault, let node, node.depth >= 0 else { return nil }
        return v.root.appendingPathComponent(node.id, isDirectory: node.isFolder)
    }

    /// Called from `makeNSView` and every `updateNSView`. Cheap unless something changed.
    func apply(_ v: FileExplorerOutline) {
        if v.tree !== tree {
            revision = v.revision
            reload(tree: v.tree)
        } else {
            if v.revision != revision {
                revision = v.revision
                refresh(state.changedFolders)
            }
            if tree.configurePins(pinPaths) { reloadRows() }
        }
        if let collapse = v.collapse, state.take(collapse) { collapseAll() }
        if let reveal = v.reveal, state.take(reveal.id), reveal.force || v.autoReveal {
            selectionCleared = false
            // Asked for: about the middle unless it already sits comfortably, and a pulse.
            // Following: only if hidden.
            self.reveal(reveal.file, placement: reveal.pulse ? .centredIfCramped : .centredIfHidden,
                        expand: reveal.expand, pulse: reveal.pulse)
            noteActivity()
        }
        if v.selected != lastSelected || v.selectedFolder != lastFolder || v.columnsSelection != lastColumns {
            let folderMoved = v.selectedFolder != lastFolder
            selectionCleared = false
            lastSelected = v.selected
            lastFolder = v.selectedFolder
            lastColumns = v.columnsSelection
            quickLookNode = nil
            func place(_ path: String) -> Bool {
                let ref = FileRef(relativePath: path)
                return v.autoReveal ? self.reveal(ref, placement: .centredIfHidden) : selectIfVisible(ref)
            }
            if let path = v.selected?.relativePath ?? v.columnsSelection ?? v.selectedFolder {
                // The columns went somewhere, or a folder became the place, not after a pick
                // here: the explorer goes too, into the folder as well as to it.
                let following = v.autoReveal && v.selected == nil && path != pickedHere
                    && (v.columnsSelection != nil || folderMoved)
                if path != pickedHere { pickedHere = nil }
                // Something the columns show that the tree leaves out (an ignored file):
                // its folder instead.
                var shown = following ? followColumns(to: path) : place(path)
                if !shown, v.selected == nil, path == v.columnsSelection, let folder = v.selectedFolder {
                    shown = following ? followColumns(to: folder) : place(folder)
                }
                if !shown { deselectStale(keeping: v.selectedFolder) }
            } else {
                // The columns back at the vault's top.
                if v.autoReveal, v.selected == nil { closeColumnsFolders(keeping: []) }
                deselectFile()
            }
            noteActivity()
        }
        if let rename = v.rename, rename.tab == .files, !rename.inColumns, state.take(rename.id) {
            let path = rename.target
            DispatchQueue.main.async { [weak self] in self?.beginRename(path) }
        }
    }

    /// Clears a file selection made from outside (vault switch, file gone). A selected
    /// folder stays: that is the explorer's own doing.
    private func deselectFile() {
        if let node = selectedNode, !node.isFolder {
            suppressSelection = true
            outline.deselectAll(nil)
            suppressSelection = false
        }
    }

    /// With the place not in the list (auto-reveal off and its folder closed, or an ignored
    /// file): no row stays highlighted for somewhere else, except the sidebar's own folder.
    private func deselectStale(keeping folder: String?) {
        guard let node = selectedNode, !(node.isFolder && node.id == folder) else { return }
        suppressSelection = true
        outline.deselectAll(nil)
        suppressSelection = false
    }

    private var selectedNode: FileNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    // MARK: Reload, expansion, reveal

    private func reload(tree: FileTree) {
        if self.tree.vault != tree.vault { selectionCleared = false; columnsOpened = [] }
        self.tree = tree
        expanded = vault.flatMap { Defaults.expandedFolders(in: $0) } ?? []
        showAllFolders = vault.map { Defaults.showsAllUnpinnedFolders(in: $0) } ?? false
        tree.configurePins(pinPaths)
        reloadRows()
        lastSelected = state.selected
        lastFolder = state.selectedFolder
        lastColumns = state.columnsSelection
        noteActivity()
    }

    /// Pinned folders first, a hairline, then the vault's own tree: every folder, then the
    /// files at its top. No headers; the hairline is the only marker.
    private func projectRoots() {
        rootItems = []
        if !tree.pinnedRoots.isEmpty { rootItems += tree.pinnedRoots + [divider] }
        rootItems += tree.unpinnedRoots
        rootItems += tree.top.filter { !$0.isFolder }
    }

    /// Structural controls have their own identities, never fake filesystem paths. A
    /// projection change preserves expansion and the active place without selecting it anew.
    private func reloadRows(revealSelection: Bool = true) {
        let wasRestoring = restoring, wasSuppressed = suppressSelection
        restoring = true
        suppressSelection = true
        projectRoots()
        outline.reloadData()
        for case let node as FileNode in rootItems where node.isFolder && expanded.contains(node.id) {
            outline.expandItem(node)
        }
        if !selectionCleared, let path = selectionPath {
            let ref = FileRef(relativePath: path)
            if revealSelection { _ = reveal(ref, placement: nil) }
            else { _ = selectIfVisible(ref) }
        } else { outline.deselectAll(nil) }
        suppressSelection = wasSuppressed
        restoring = wasRestoring
    }

    @objc private func toggleOtherFolders(_ sender: Any?) {
        showAllFolders.toggle()
        if let vault { Defaults.setShowsAllUnpinnedFolders(showAllFolders, in: vault) }
        reloadRows()
    }

    /// Refresh every loaded representation of a changed folder, including overlapping
    /// pins. The canonical tree and its shortcuts must not diverge after filesystem edits.
    private func refresh(_ folders: Set<String>) {
        guard !folders.isEmpty else { return }
        let targets = folders.contains("") ? tree.loadedFolders : folders.flatMap { tree.loadedNodes(at: $0) }
        var changed = false
        for node in Set(targets) where tree.refresh(node) { changed = true }
        let pinsChanged = tree.configurePins(pinPaths)
        if changed || pinsChanged { reloadRows(revealSelection: pinsChanged) }
    }

    private func persistExpansion() {
        guard let vault else { return }
        Defaults.setExpandedFolders(expanded, in: vault)
    }

    private func collapseAll() {
        let wasSuppressed = suppressSelection
        restoring = true
        suppressSelection = true
        for case let node as FileNode in rootItems where node.isFolder { outline.collapseItem(node, collapseChildren: true) }
        suppressSelection = wasSuppressed
        restoring = false
        expanded = []
        columnsOpened = []
        persistExpansion()
    }

    // MARK: Closing folders when left alone

    private func noteActivity() {
        lastActivity = Date()
        if idleCheck == nil { scheduleIdleCheck(after: Self.idleCollapse) }
    }

    private func scheduleIdleCheck(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.idleCheckFired() }
        idleCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func idleCheckFired() {
        idleCheck = nil
        guard let outline, let window = outline.window, window.isVisible else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle < Self.idleCollapse { return scheduleIdleCheck(after: Self.idleCollapse - idle) }
        if inUse(in: window) { return noteActivity() }
        collapseIdle()
    }

    /// The pointer over the list, a name being typed, its menu open, or a drag under way.
    private func inUse(in window: NSWindow) -> Bool {
        if outline.isEditing || outline.contextRow >= 0 || NSEvent.pressedMouseButtons != 0 { return true }
        let mouse = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
        return scroll.bounds.contains(scroll.convert(window.convertPoint(fromScreen: mouse), from: nil))
    }

    /// Closes every open folder except those holding the selected row (or, with the
    /// highlight cleared, the current place).
    private func collapseIdle() {
        var keepRows = Set<ObjectIdentifier>(), keepPaths = Set<String>()
        // A folder the columns are in stays open, as they show it.
        var node = selectedNode.flatMap { $0.isFolder && columnsOpened.contains($0.id) ? $0 : $0.parent }
        while let n = node, n.depth >= 0 { keepRows.insert(ObjectIdentifier(n)); keepPaths.insert(n.id); node = n.parent }
        if selectedNode == nil, let path = selectionPath {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty { keepPaths.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        let closing = (0..<outline.numberOfRows).reversed().compactMap { row -> FileNode? in
            guard let n = outline.item(atRow: row) as? FileNode, n.isFolder, outline.isItemExpanded(n) else { return nil }
            let kept = selectedNode == nil ? keepPaths.contains(n.id) : keepRows.contains(ObjectIdentifier(n))
            return kept ? nil : n
        }
        guard !closing.isEmpty || !expanded.isSubset(of: keepPaths) else { return }
        let wasSuppressed = suppressSelection
        restoring = true
        suppressSelection = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.fastSeconds
            for n in closing { outline.animator().collapseItem(n, collapseChildren: true) }
        }
        suppressSelection = wasSuppressed
        restoring = false
        expanded.formIntersection(keepPaths)
        columnsOpened.formIntersection(keepPaths)
        persistExpansion()
        if outline.selectedRow >= 0 { outline.bringRowIntoView(outline.selectedRow, placement: .centredIfHidden) }
    }

    /// The tree's node for `path`. A file made a moment ago may be missing from a listing the
    /// watcher hasn't refreshed yet: that folder is listed again, and the rows with it.
    private func node(for path: String) -> FileNode? {
        let (node, relisted) = tree.nodeRelisting(for: path)
        if relisted { reloadRows(revealSelection: false) }
        return node
    }

    /// Expands the file's ancestors (outermost first), selects its row and, with a
    /// `placement`, scrolls to it (and pulses it, if asked) once the list is laid out. Never
    /// calls back into `state.select`. `false` when the file isn't in the tree.
    @discardableResult
    private func reveal(_ ref: FileRef, placement: SidebarOutlineView.RowPlacement?, expand: Bool = false, pulse: Bool = false) -> Bool {
        guard let node = node(for: ref.relativePath) else { return false }
        var top = node
        while let parent = top.parent, parent.depth >= 0 { top = parent }
        if top.depth >= 0, !rootItems.contains(where: { $0 === top }) {
            // A forced reveal can target a fourth folder before the shell changes its
            // selection. Expand the list, so its native outline ancestors are reachable.
            showAllFolders = true
            if let vault { Defaults.setShowsAllUnpinnedFolders(true, in: vault) }
            let wasSuppressed = suppressSelection, wasRestoring = restoring
            suppressSelection = true; restoring = true
            projectRoots()
            outline.reloadData()
            for case let root as FileNode in rootItems where root.isFolder && expanded.contains(root.id) { outline.expandItem(root) }
            suppressSelection = wasSuppressed; restoring = wasRestoring
        }
        var ancestors: [FileNode] = []
        var p = node.parent
        while let n = p, n.depth >= 0 { ancestors.append(n); p = n.parent }
        for folder in ancestors.reversed() where !outline.isItemExpanded(folder) {
            outline.expandItem(folder)
        }
        if expand, node.isFolder { outline.expandItem(node) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        let wasSuppressed = suppressSelection
        suppressSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelection = wasSuppressed
        if let placement { show(node, placement: placement, pulse: pulse) }
        return true
    }

    /// Scrolls to `node`'s row and pulses it. Following a navigation it jumps there: an
    /// animated scroll redraws the whole window every frame, for half a second after each
    /// back, forward or column pick. Only an asked-for reveal (the pulse) glides. A list that
    /// has only just appeared (back from another tab, unfolded) has no size yet: it waits for
    /// one, then is put in place rather than scrolled.
    private func show(_ node: FileNode, placement: SidebarOutlineView.RowPlacement, pulse: Bool, attempt: Int = 0) {
        guard outline.window != nil, scroll.contentView.bounds.height > 1 else {
            guard attempt < 30 else { return }
            DispatchQueue.main.async { [weak self] in self?.show(node, placement: placement, pulse: pulse, attempt: attempt + 1) }
            return
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.bringRowIntoView(row, placement: placement, animated: pulse && attempt == 0) { [weak self] in
            guard pulse, let self else { return }
            let row = self.outline.row(forItem: node)
            guard row >= 0 else { return }
            (self.outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.pulse()
        }
    }

    /// The columns are at `path`: its row is selected with the folders on the way open and,
    /// a folder, open too, its rows in view. Folders opened for the columns before and off
    /// that way close.
    private func followColumns(to path: String) -> Bool {
        guard let node = node(for: path) else { return false }
        var keep = Set<String>()
        var folder = node.isFolder ? path : (path as NSString).deletingLastPathComponent
        while !folder.isEmpty { keep.insert(folder); folder = (folder as NSString).deletingLastPathComponent }
        closeColumnsFolders(keeping: keep)
        let before = expanded
        let shown = reveal(FileRef(relativePath: path), placement: node.isFolder ? .opened : .centredIfHidden, expand: node.isFolder)
        columnsOpened.formUnion(expanded.subtracting(before))
        return shown
    }

    /// Closes the folders opened for the columns that aren't in `keep`, innermost first.
    private func closeColumnsFolders(keeping keep: Set<String>) {
        let closing = columnsOpened.subtracting(keep)
        guard !closing.isEmpty else { return }
        let wasSuppressed = suppressSelection, wasRestoring = restoring
        restoring = true
        suppressSelection = true
        for row in (0..<outline.numberOfRows).reversed() {
            guard let n = outline.item(atRow: row) as? FileNode, closing.contains(n.id), outline.isItemExpanded(n) else { continue }
            outline.collapseItem(n)
        }
        suppressSelection = wasSuppressed
        restoring = wasRestoring
        columnsOpened.subtract(closing)
        expanded.subtract(closing)
        persistExpansion()
    }

    /// For a list that was just made: its selected row in view once it has a size.
    func showSelectionOnceLaidOut() {
        guard let node = selectedNode else { return }
        show(node, placement: .centredIfHidden, pulse: false, attempt: 1)
    }

    /// With auto-reveal off: highlight the file only if its row is already in the tree.
    private func selectIfVisible(_ ref: FileRef) -> Bool {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? FileNode)?.id == ref.relativePath }) else { return false }
        let wasSuppressed = suppressSelection
        suppressSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelection = wasSuppressed
        return true
    }

    private func beginRename(_ path: String) {
        guard let node = node(for: path) else { return }
        reveal(FileRef(relativePath: path), placement: .nearestEdge)
        beginRename(node)
    }

    private func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        noteActivity()
        let name = node.name
        let stem = node.isFolder ? name : (name as NSString).deletingPathExtension
        let id = node.id
        outline.beginEditing(row: row, text: name, selecting: NSRange(location: 0, length: (stem as NSString).length)) { [weak self] new in
            guard let self, new != name else { return }
            self.state.rename(id, to: new)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootItems.count }
        guard let node = item as? FileNode else { return 0 }
        return node.isFolder ? tree.load(node).count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rootItems[index] }
        return tree.load(node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, !node.id.isEmpty,
              let url = state.url(for: FileRef(relativePath: node.id)) else { return nil }
        return FileHandoff.pasteboardItem(url: url, relativePath: node.id)
    }

    /// Onto a folder, or onto a file's folder; never into the dragged folder itself or
    /// where it already is. Files from Finder (or from outside the vault in the columns)
    /// move or copy in by Finder's rules, as they do in the columns.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard item == nil || item is FileNode else { return [] }
        noteActivity()
        var target = item as? FileNode
        if let t = target, !t.isFolder { target = t.parent.flatMap { $0.depth >= 0 ? $0 : nil } }
        guard let path = info.draggingPasteboard.string(forType: Self.pathType), !path.isEmpty else {
            let urls = FileHandoff.fileURLs(on: info.draggingPasteboard)
            guard let folder = url(of: target) ?? vault?.root, !urls.isEmpty,
                  urls.allSatisfy({ FileDrop.canDrop($0, into: folder) }) else { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return FileDrop.operation(urls, into: folder, mask: info.draggingSourceOperationMask,
                                      keepsThoughts: state.keepsThoughts(urls, into: folder))
        }
        let folder = target?.id ?? ""
        let parent = (path as NSString).deletingLastPathComponent
        guard folder != parent, !FileTree.contains(path, folder) else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard item == nil || item is FileNode else { return false }
        let folder = (item as? FileNode)?.id ?? ""
        if !folder.isEmpty, let node = item as? FileNode, !outline.isItemExpanded(node) {
            expanded.insert(folder)
            persistExpansion()
        }
        guard let path = info.draggingPasteboard.string(forType: Self.pathType), !path.isEmpty else {
            let urls = FileHandoff.fileURLs(on: info.draggingPasteboard)
            guard let into = url(of: item as? FileNode) ?? vault?.root, !urls.isEmpty else { return false }
            let operation = FileDrop.operation(urls, into: into, mask: info.draggingSourceOperationMask,
                                               keepsThoughts: state.keepsThoughts(urls, into: into))
            guard !operation.isEmpty else { return false }
            state.transfer(urls, into: into, moving: operation == .move)
            return true
        }
        return state.move(path, into: folder)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? ExplorerSection, section.title.isEmpty {
            let view = NSView()
            let line = NSBox()
            line.boxType = .custom
            line.borderWidth = 0
            line.fillColor = Theme.NS.hairline
            line.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(line)
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                                         line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                                         line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                         line.heightAnchor.constraint(equalToConstant: 1)])
            return view
        }
        if let section = item as? ExplorerSection {
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let view = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                                         label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)])
            label.setAccessibilityLabel(section.title == "Pinned" ? "Pinned folders" : section.title)
            return view
        }
        if item is ExplorerFolderToggle {
            let remaining = max(0, tree.unpinnedRoots.count - 3)
            let title = showAllFolders ? "Show less" : "Show \(remaining) more"
            let button = NSButton(title: title, target: self, action: #selector(toggleOtherFolders(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.image = NSImage(systemSymbolName: showAllFolders ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.setAccessibilityLabel(showAllFolders ? "Show fewer unpinned folders" : "Show all \(tree.unpinnedRoots.count) unpinned folders")
            return button
        }
        guard let node = item as? FileNode else { return nil }
        let row = outlineView.row(forItem: node)
        let host = SidebarRowHost(node: node, state: state, selected: row >= 0 && outlineView.isRowSelected(row))
        if let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? SidebarCellView {
            cell.rootView = host
            return cell
        }
        let cell = SidebarCellView(rootView: host)
        cell.identifier = Self.cellID
        cell.sizingOptions = []
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is FileNode }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? ExplorerSection).map { $0.title.isEmpty ? 13 : 27 } ?? Theme.Size.row
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let row = outlineView.makeView(withIdentifier: Self.rowID, owner: nil) as? SidebarRowView { return row }
        let row = SidebarRowView()
        row.identifier = Self.rowID
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FileNode)?.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        guard !suppressSelection else { return }
        guard let node = selectedNode else { return }
        selectionCleared = false
        quickLookNode = nil
        pickedHere = node.id
        noteActivity()
        state.selectFromSidebar(folder: node.ref == nil ? node.id : (node.id as NSString).deletingLastPathComponent,
                                file: node.ref)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if !restoring { noteActivity() }
        if !restoring, !expanded.contains(node.id) {
            expanded.insert(node.id)
            persistExpansion()
        }
        // Children remember their own state across a collapse and a rebuild.
        for child in node.children where child.isFolder && expanded.contains(child.id) && !outline.isItemExpanded(child) {
            outline.expandItem(child)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        noteActivity()
        columnsOpened.remove(node.id)
        guard expanded.contains(node.id) else { return }
        expanded.remove(node.id)
        persistExpansion()
    }

    // MARK: Mouse

    /// A click on the row already selected changes no selection, so a row highlighted
    /// because the columns have it selected opens here, as any other click would.
    @objc func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, row == outline.selectedRow, let node = outline.item(atRow: row) as? FileNode else { return }
        if let ref = node.ref {
            if state.selected != ref { state.selectFromSidebar(folder: (node.id as NSString).deletingLastPathComponent, file: ref) }
        } else if state.columnsSelection != nil || state.selectedFolder != node.id {
            pickedHere = node.id
            state.selectFromSidebar(folder: node.id, file: nil)
        }
    }

    @objc func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if let ref = node.ref {
            if let url = state.url(for: ref), state.expandIfArchive(url) { return }
            state.openExternally(ref)
        } else if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let v = vault else { return }
        let row = outline.contextRow
        guard row >= 0 else { return FileMenu.buildBackground(menu, folder: v.root, state: state) }
        guard let node = outline.item(atRow: row) as? FileNode, let url = url(of: node) else { return }
        noteActivity()
        FileMenu.build(menu, url: url, isFolder: node.isFolder, state: state, host: FileMenu.Host(
            open: { [weak self] in self?.state.openFromBrowser(url, isFolder: node.isFolder) },
            rename: node.id.isEmpty ? nil : { [weak self] in self?.beginRename(node) },
            quickLook: { [weak self] in
                guard let self else { return }
                self.quickLookNode = node
                self.outline.window?.makeFirstResponder(self.outline)
                self.outline.toggleQuickLook()
            },
            window: outline.window))
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.endContextMenu()
    }
}

/// The mounted explorer, for the QA hook (NavigationQA.swift); set only with FLAMINGO_DEBUG.
@MainActor
enum FileExplorerQA {
    static var status: (() -> String)?
    static var collapseIdle: (() -> Void)?
    static var scroll: ((CGFloat) -> Void)?
}

/// Non-filesystem rows in the explorer; neither can be selected, renamed, or dropped onto.
private final class ExplorerSection {
    let title: String
    init(_ title: String) { self.title = title }
}
private final class ExplorerFolderToggle {}
