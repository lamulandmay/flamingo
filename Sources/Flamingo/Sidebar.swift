import AppKit
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
    @EnvironmentObject var state: AppState
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
    @EnvironmentObject var state: AppState

    var body: some View {
        IconButton("sidebar.left", help: state.sidebarCollapsed ? "Expand" : "Collapse") { state.toggleSidebar() }
    }
}

/// Files, Search, Bookmarks.
private struct SidebarTabs: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                IconButton(tab.symbol, help: tab.title, isOn: state.sidebarTab == tab) { state.sidebarTab = tab }
                    .background(Squircle(radius: Theme.Radius.s)
                        .fill(Theme.Color.hover)
                        .opacity(state.sidebarTab == tab ? 1 : 0))
            }
        }
        .animation(Theme.Motion.fast, value: state.sidebarTab)
    }
}

/// The column of actions down the left edge.
struct Ribbon: View {
    @EnvironmentObject var state: AppState
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
            IconButton("tray", help: "Capture inbox") { state.isInboxPresented = true }
        }
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
        .frame(maxHeight: .infinity)
    }
}

/// Finder's column view of the current folder, with the open file selected in it; pressed
/// again, back to the file.
private struct FinderColumnsButton: View {
    @EnvironmentObject var state: AppState
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
    @EnvironmentObject var state: AppState

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
        .help(help)
        .accessibilityLabel(help)
    }
}

/// New note, new folder, sort order, auto-reveal, collapse all.
private struct FileExplorerHeader: View {
    @EnvironmentObject var state: AppState

    var body: some View {
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
            IconButton("scope", help: "Auto-reveal current file", isOn: state.autoReveal) { state.autoReveal.toggle() }
            IconButton("arrow.down.right.and.arrow.up.left", help: "Collapse all") { state.collapseAll(in: .files) }
        }
    }
}

/// The vault's name; click for the other vaults.
private struct VaultSwitcher: View {
    @EnvironmentObject var state: AppState
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
/// `FlamingoDesign`. Drag a file or folder onto a folder to move it there.
struct FileExplorer: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        FileExplorerOutline(state: state, tree: state.tree, revision: state.treeRevision, selected: state.selected,
                            selectedFolder: state.selectedFolder, bookmarks: state.bookmarks,
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
    let bookmarks: Bookmarks
    let reveal: RevealRequest?
    let collapse: UUID?
    let rename: RenameRequest?
    let autoReveal: Bool

    func makeCoordinator() -> FileExplorerCoordinator { FileExplorerCoordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView.make(label: "Files")
        outline.registerForDraggedTypes([FileExplorerCoordinator.pathType])
        outline.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(FileExplorerCoordinator.doubleClicked(_:))
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
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.apply(self)
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
    private var selectionPath: String? { state.selected?.relativePath ?? state.selectedFolder }
    /// True while the outline's selection is being changed programmatically.
    private var suppressSelection = false
    /// True while a reload restores expansion, so nothing is persisted mid-way.
    private var restoring = false
    /// Clearing the row highlight must survive watcher refreshes without closing the preview.
    private var selectionCleared = false

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
            self.reveal(reveal.file, scroll: true, expand: reveal.expand)
        }
        if v.selected != lastSelected || v.selectedFolder != lastFolder {
            selectionCleared = false
            lastSelected = v.selected
            lastFolder = v.selectedFolder
            if let path = v.selected?.relativePath ?? v.selectedFolder {
                if selectedNode?.id != path {
                    let ref = FileRef(relativePath: path)
                    let shown = v.autoReveal ? self.reveal(ref, scroll: true) : selectIfVisible(ref)
                    if !shown { deselectFile() }
                }
            } else {
                deselectFile()
            }
        }
        if let rename = v.rename, rename.tab == .files, state.take(rename.id) {
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

    private var selectedNode: FileNode? {
        let row = outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    // MARK: Reload, expansion, reveal

    private func reload(tree: FileTree) {
        if self.tree.vault != tree.vault { selectionCleared = false }
        self.tree = tree
        expanded = vault.flatMap { Defaults.expandedFolders(in: $0) } ?? []
        showAllFolders = vault.map { Defaults.showsAllUnpinnedFolders(in: $0) } ?? false
        tree.configurePins(pinPaths)
        reloadRows()
        lastSelected = state.selected
        lastFolder = state.selectedFolder
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
            if revealSelection { _ = reveal(ref, scroll: false) }
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
        persistExpansion()
    }

    /// Expands the file's ancestors (outermost first), selects its row and, if asked,
    /// scrolls it into view. Never calls back into `state.select`. `false` when the file
    /// isn't in the tree.
    @discardableResult
    private func reveal(_ ref: FileRef, scroll shouldScroll: Bool, expand: Bool = false) -> Bool {
        guard let node = tree.node(for: ref) else { return false }
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
        if shouldScroll { outline.scrollRowIntoView(row) }
        return true
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
        guard let node = tree.node(for: path) else { return }
        reveal(FileRef(relativePath: path), scroll: true)
        beginRename(node)
    }

    private func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
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
    /// where it already is.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard item == nil || item is FileNode,
              let path = info.draggingPasteboard.string(forType: Self.pathType), !path.isEmpty else { return [] }
        var target = item as? FileNode
        if let t = target, !t.isFolder { target = t.parent.flatMap { $0.depth >= 0 ? $0 : nil } }
        let folder = target?.id ?? ""
        let parent = (path as NSString).deletingLastPathComponent
        guard folder != parent, !FileTree.contains(path, folder) else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard item == nil || item is FileNode,
              let path = info.draggingPasteboard.string(forType: Self.pathType), !path.isEmpty else { return false }
        let folder = (item as? FileNode)?.id ?? ""
        if !folder.isEmpty, let node = item as? FileNode, !outline.isItemExpanded(node) {
            expanded.insert(folder)
            persistExpansion()
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
        guard !suppressSelection else { return }
        guard let node = selectedNode else { return }
        selectionCleared = false
        state.selectFromSidebar(folder: node.ref == nil ? node.id : (node.id as NSString).deletingLastPathComponent,
                                file: node.ref)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
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
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode, expanded.contains(node.id) else { return }
        expanded.remove(node.id)
        persistExpansion()
    }

    // MARK: Mouse

    @objc func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if let ref = node.ref {
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
        let row = outline.contextRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        let bookmarked = state.isBookmarked(node.id, folder: node.isFolder)
        if let ref = node.ref {
            add("Open Beside", #selector(openBeside(_:)))
            add("Open in " + (state.defaultAppName(for: ref) ?? "Default App"), #selector(openInApp(_:)))
            add("Leave a Thought", #selector(leaveThought(_:)))
        } else {
            add("New File…", #selector(newFile(_:)))
            add("New Note", #selector(newNote(_:)))
            add("New Folder", #selector(newFolder(_:)))
            add("Search in Folder", #selector(searchInFolder(_:)))
        }
        menu.addItem(.separator())
        add(node.isFolder ? (bookmarked ? "Unpin Folder" : "Pin Folder") : (bookmarked ? "Remove Bookmark" : "Bookmark"), #selector(toggleBookmark(_:)))
        if !node.id.isEmpty { add("Rename…", #selector(rename(_:))) }
        menu.addItem(.separator())
        add("Reveal in Finder", #selector(revealInFinder(_:)))
        add(node.isFolder ? "Copy Folder" : "Copy File", #selector(copyFile(_:)))
        add("Copy Path", #selector(copyPath(_:)))
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.endContextMenu()
    }

    private func node(_ sender: NSMenuItem) -> FileNode? { sender.representedObject as? FileNode }

    @objc private func openInApp(_ sender: NSMenuItem) {
        guard let ref = node(sender)?.ref else { return }
        state.openExternally(ref)
    }

    @objc private func openBeside(_ sender: NSMenuItem) {
        guard let ref = node(sender)?.ref else { return }
        state.openBeside(ref)
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.showNewFile(in: n.id)
    }

    @objc private func newNote(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.newNote(in: n.id)
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.newFolder(in: n.id)
    }

    @objc private func searchInFolder(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.showSidebarSearch(SidebarSearchModel.scopedQuery(folder: n.id))
    }

    @objc private func toggleBookmark(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.toggleBookmark(path: n.id, folder: n.isFolder)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        beginRename(n)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        // A folder has no ref; its relative path resolves the same way through the vault.
        state.revealInFinder(n.ref ?? FileRef(relativePath: n.id))
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.copyPath(n.ref ?? FileRef(relativePath: n.id))
    }

    @objc private func copyFile(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.copyFiles([n.ref ?? FileRef(relativePath: n.id)])
    }

    @objc private func leaveThought(_ sender: NSMenuItem) {
        guard let n = node(sender), let ref = n.ref else { return }
        let row = outline.row(forItem: n)
        if row >= 0 {
            suppressSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelection = false
        }
        state.select(ref, source: .sidebar)
        state.leaveThought()
    }
}

/// Non-filesystem rows in the explorer; neither can be selected, renamed, or dropped onto.
private final class ExplorerSection {
    let title: String
    init(_ title: String) { self.title = title }
}
private final class ExplorerFolderToggle {}
