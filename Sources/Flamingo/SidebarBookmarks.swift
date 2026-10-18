import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Bookmark the current file, new group, collapse all.
struct BookmarksHeader: View {
    @Environment(AppState.self) var state

    var body: some View {
        let marked = state.selected.map { state.isBookmarked($0.relativePath, folder: false) } ?? false
        PaneActions {
            IconButton(marked ? "bookmark.fill" : "bookmark", help: marked ? "Remove bookmark" : "Bookmark current file", isOn: marked) {
                state.toggleBookmarkCurrent()
            }
            .disabled(state.selected == nil && (state.selectedFolder ?? "").isEmpty)
            IconButton("folder.badge.plus", help: "New group") { state.addBookmarkGroup() }
            IconButton("arrow.down.right.and.arrow.up.left", help: "Collapse all") { state.collapseAll(in: .bookmarks) }
        }
    }
}

/// `.flamingo/bookmarks.json` as a list: files, folders, searches, and groups of them.
/// Click to open; drag to reorder or into a group; drop files from Finder to bookmark
/// them; ⌫ removes, with Undo. Plan 01 owns.
struct BookmarksPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        if let error = state.bookmarksError {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Bookmarks need attention").font(Theme.Font.bodyMedium)
                Text(error).font(Theme.Font.small).textSelection(.enabled)
                Text("Your original bookmark file has been kept. New changes are paused until it can be read.").font(Theme.Font.small)
                Button("Retry reading") { state.retryBookmarks() }
                Button("Keep a recovery copy and start empty") { state.recoverBookmarks() }
            }.padding(Theme.Space.l).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.bookmarks.items.isEmpty {
            VStack(spacing: Theme.Space.s) {
                Text("No bookmarks yet")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("⌘D bookmarks the current file.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Space.l)
        } else {
            BookmarksOutline(state: state, bookmarks: state.bookmarks, selected: state.selected,
                             collapse: state.collapseRequest.flatMap { $0.tab == .bookmarks ? $0.id : nil },
                             rename: state.renameRequest)
        }
    }
}

/// One bookmark and where it sits. Rebuilt whenever the bookmarks change.
final class BookmarkNode {
    let bookmark: Bookmark
    let path: Bookmarks.Path
    var children: [BookmarkNode] = []
    init(_ bookmark: Bookmark, path: Bookmarks.Path) { self.bookmark = bookmark; self.path = path }
    var isGroup: Bool { bookmark.kind == .group }
}

private struct BookmarksOutline: NSViewRepresentable {
    let state: AppState
    let bookmarks: Bookmarks
    let selected: FileRef?
    let collapse: UUID?
    let rename: RenameRequest?

    func makeCoordinator() -> BookmarksCoordinator { BookmarksCoordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView.make(label: "Bookmarks")
        outline.registerForDraggedTypes([BookmarksCoordinator.bookmarkType, .fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .gap

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(BookmarksCoordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.onDelete = { [weak coordinator] in coordinator?.removeSelected() ?? false }
        outline.onReturn = { [weak coordinator] in coordinator?.openSelected() ?? false }

        let scroll = SidebarOutlineView.scroll(outline)
        coordinator.install(outline: outline)
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

@MainActor
private final class BookmarksCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// A bookmark dragged inside the list; the string is its index path, `2.0`.
    static let bookmarkType = NSPasteboard.PasteboardType("com.flamingo.sidebar.bookmark")
    private static let cellID = NSUserInterfaceItemIdentifier("bookmark.cell")
    private static let rowID = NSUserInterfaceItemIdentifier("bookmark.row")

    let state: AppState
    private var outline: SidebarOutlineView!
    private var bookmarks: Bookmarks?
    private var roots: [BookmarkNode] = []
    /// Groups the user folded, by `ctime`. Persisted per vault.
    private var folded: Set<Int64> = []
    private var lastSelected: FileRef?
    private var restoring = false

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func install(outline: SidebarOutlineView) {
        self.outline = outline
        if let v = state.vault { folded = Defaults.foldedBookmarkGroups(in: v) }
        outline.onCopy = { [weak self] in
            guard let self, self.outline.selectedRow >= 0,
                  let node = self.outline.item(atRow: self.outline.selectedRow) as? BookmarkNode,
                  node.bookmark.kind == .file || node.bookmark.kind == .folder,
                  let path = node.bookmark.path else { return false }
            return self.state.copyFiles([FileRef(relativePath: path)])
        }
    }

    func apply(_ v: BookmarksOutline) {
        if v.bookmarks != bookmarks {
            bookmarks = v.bookmarks
            rebuild(v.bookmarks)
            lastSelected = nil
        }
        if let collapse = v.collapse, state.take(collapse) {
            restoring = true
            for n in roots where n.isGroup { outline.collapseItem(n, collapseChildren: true) }
            restoring = false
            folded = Set(v.bookmarks.all.filter { $0.bookmark.kind == .group }.map(\.bookmark.ctime))
            persistFolded()
        }
        if v.selected != lastSelected {
            lastSelected = v.selected
            highlight(v.selected)
        }
        if let rename = v.rename, rename.tab == .bookmarks, state.take(rename.id), let ctime = Int64(rename.target) {
            DispatchQueue.main.async { [weak self] in self?.beginRename(ctime: ctime) }
        }
    }

    private func rebuild(_ b: Bookmarks) {
        func nodes(_ list: [Bookmark], _ prefix: Bookmarks.Path) -> [BookmarkNode] {
            list.enumerated().map { i, bm in
                let n = BookmarkNode(bm, path: prefix + [i])
                n.children = nodes(bm.items ?? [], prefix + [i])
                return n
            }
        }
        roots = nodes(b.items, [])
        restoring = true
        outline.reloadData()
        func expand(_ list: [BookmarkNode]) {
            for n in list where n.isGroup && !folded.contains(n.bookmark.ctime) {
                outline.expandItem(n)
                expand(n.children)
            }
        }
        expand(roots)
        restoring = false
    }

    private var allNodes: [BookmarkNode] {
        var out: [BookmarkNode] = []
        func walk(_ list: [BookmarkNode]) { for n in list { out.append(n); walk(n.children) } }
        walk(roots)
        return out
    }

    /// The current file's bookmark, if it has one and its row is showing.
    private func highlight(_ file: FileRef?) {
        let node = file.flatMap { f in allNodes.first { $0.bookmark.kind == .file && $0.bookmark.path == f.relativePath } }
        let row = node.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
    }

    private func persistFolded() {
        if let v = state.vault { Defaults.setFoldedBookmarkGroups(folded, in: v) }
    }

    private func beginRename(ctime: Int64) {
        guard let node = allNodes.first(where: { $0.bookmark.ctime == ctime }) else { return }
        beginRename(node)
    }

    private func beginRename(_ node: BookmarkNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        let text = node.bookmark.displayName
        let ctime = node.bookmark.ctime
        outline.beginEditing(row: row, text: text, selecting: NSRange(location: 0, length: (text as NSString).length)) { [weak self] new in
            guard let self, new != text else { return }
            self.state.renameBookmark(ctime: ctime, to: new)
        }
    }

    // MARK: Actions

    @objc func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? BookmarkNode else { return }
        open(node)
    }

    func openSelected() -> Bool {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? BookmarkNode else { return false }
        open(node)
        return true
    }

    private func open(_ node: BookmarkNode) {
        if node.isGroup {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            state.openBookmark(node.bookmark)
        }
    }

    func removeSelected() -> Bool {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? BookmarkNode else { return false }
        state.removeBookmark(at: node.path)
        return true
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BookmarkNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? BookmarkNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BookmarkNode)?.isGroup ?? false
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? BookmarkNode else { return nil }
        let pb: NSPasteboardItem
        if node.bookmark.kind == .file || node.bookmark.kind == .folder,
           let path = node.bookmark.path, let url = state.url(for: FileRef(relativePath: path)) {
            // A bookmark drag still reorders bookmarks; it does not move its file.
            pb = FileHandoff.pasteboardItem(url: url)
        } else {
            pb = NSPasteboardItem()
        }
        pb.setString(node.path.map(String.init).joined(separator: "."), forType: Self.bookmarkType)
        return pb
    }

    private func draggedPath(_ info: NSDraggingInfo) -> Bookmarks.Path? {
        info.draggingPasteboard.string(forType: Self.bookmarkType).map { $0.split(separator: ".").compactMap { Int($0) } }
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        guard let v = state.vault else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { v.contains($0) && !v.isState($0) }
    }

    /// Between bookmarks, or onto a group (its end). Never a group into itself.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let from = draggedPath(info)
        guard from != nil || !droppedURLs(info).isEmpty else { return [] }
        var parent = item as? BookmarkNode
        var at = index
        if let p = parent, !p.isGroup {
            // Onto a bookmark that isn't a group: just before it.
            let grand = outlineView.parent(forItem: p) as? BookmarkNode
            at = p.path.last ?? 0
            parent = grand
            outlineView.setDropItem(grand, dropChildIndex: at)
        } else if at == NSOutlineViewDropOnItemIndex {
            at = parent?.children.count ?? roots.count
            outlineView.setDropItem(parent, dropChildIndex: at)
        }
        if let from, let target = parent?.path, target.starts(with: from) { return [] }
        return from != nil ? .move : .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let parent = (item as? BookmarkNode)?.path ?? []
        let at = index == NSOutlineViewDropOnItemIndex ? state.bookmarks.children(at: parent).count : index
        if let from = draggedPath(info) {
            state.moveBookmark(from: from, toParent: parent, index: at)
            return true
        }
        var added = false
        for (k, url) in droppedURLs(info).enumerated() {
            added = state.bookmark(url, at: parent + [at + k]) || added
        }
        return added
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BookmarkNode else { return nil }
        let row = outlineView.row(forItem: node)
        let host = BookmarkRowHost(bookmark: node.bookmark, vault: state.vault, selected: row >= 0 && outlineView.isRowSelected(row))
        if let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? BookmarkCellView {
            cell.rootView = host
            return cell
        }
        let cell = BookmarkCellView(rootView: host)
        cell.identifier = Self.cellID
        cell.sizingOptions = []
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let row = outlineView.makeView(withIdentifier: Self.rowID, owner: nil) as? SidebarRowView { return row }
        let row = SidebarRowView()
        row.identifier = Self.rowID
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? BookmarkNode)?.bookmark.displayName
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? BookmarkNode else { return }
        folded.remove(node.bookmark.ctime)
        persistFolded()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? BookmarkNode else { return }
        folded.insert(node.bookmark.ctime)
        persistFolded()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.contextRow
        guard row >= 0, let node = outline.item(atRow: row) as? BookmarkNode else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        switch node.bookmark.kind {
        case .file:
            let ref = FileRef(relativePath: node.bookmark.path ?? "")
            add("Open Beside", #selector(openBeside(_:)))
            add("Open in " + (state.defaultAppName(for: ref) ?? "Default App"), #selector(openInApp(_:)))
            add("Reveal in File Explorer", #selector(revealInExplorer(_:)))
            add("Reveal in Finder", #selector(revealInFinder(_:)))
            add("Copy File", #selector(copyFile(_:)))
            add("Copy Path", #selector(copyPath(_:)))
            menu.addItem(.separator())
        case .folder:
            add("Reveal in File Explorer", #selector(revealInExplorer(_:)))
            add("Reveal in Finder", #selector(revealInFinder(_:)))
            add("Copy Folder", #selector(copyFile(_:)))
            add("Copy Path", #selector(copyPath(_:)))
            menu.addItem(.separator())
        case .search, .group, nil:
            break
        }
        // The file or folder itself; the vault's own folder ("/") keeps its name.
        if let path = node.bookmark.path, !path.isEmpty {
            switch node.bookmark.kind {
            case .file: add("Rename File…", #selector(renameItem(_:)))
            case .folder: add("Rename Folder…", #selector(renameItem(_:)))
            case .search, .group, nil: break
            }
        }
        add(node.isGroup ? "Rename…" : "Edit Title…", #selector(rename(_:)))
        add(node.isGroup ? "Remove Group" : "Remove Bookmark", #selector(remove(_:)))
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.endContextMenu()
    }

    private func node(_ sender: NSMenuItem) -> BookmarkNode? { sender.representedObject as? BookmarkNode }

    @objc private func openInApp(_ sender: NSMenuItem) {
        guard let p = node(sender)?.bookmark.path else { return }
        state.openExternally(FileRef(relativePath: p))
    }

    @objc private func openBeside(_ sender: NSMenuItem) {
        guard let p = node(sender)?.bookmark.path else { return }
        state.openBeside(FileRef(relativePath: p))
    }

    @objc private func revealInExplorer(_ sender: NSMenuItem) {
        guard let b = node(sender)?.bookmark, let p = b.path else { return }
        if b.kind == .folder {
            state.revealFolder(p)
        } else {
            state.jump(to: FileRef(relativePath: p), anchor: nil)
            state.revealCurrentFile()
        }
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let p = node(sender)?.bookmark.path else { return }
        state.revealInFinder(FileRef(relativePath: p))
    }

    @objc private func copyFile(_ sender: NSMenuItem) {
        guard let p = node(sender)?.bookmark.path else { return }
        state.copyFiles([FileRef(relativePath: p)])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let p = node(sender)?.bookmark.path else { return }
        state.copyPath(FileRef(relativePath: p))
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        beginRename(n)
    }

    /// The file or folder itself, not the bookmark's title: its name in place of the row's.
    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let n = node(sender), let path = n.bookmark.path else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        let name = (path as NSString).lastPathComponent
        outline.beginEditing(row: row, text: name, selecting: RenameField.stem(of: name, isFolder: n.bookmark.kind == .folder)) { [weak self] new in
            guard let self, new != name else { return }
            self.state.rename(path, to: new)
        }
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let n = node(sender) else { return }
        state.removeBookmark(at: n.path)
    }
}

// MARK: - Rows

/// Glyph and name. A file or folder that is no longer on disk reads tertiary.
struct BookmarkRow: View {
    let bookmark: Bookmark
    let vault: Vault?
    @Environment(\.flamingoRowSelected) private var selected

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            glyph
                .frame(width: Theme.Size.icon)
            Text(bookmark.displayName)
                .font(bookmark.kind == .group ? Theme.Font.bodyMedium : Theme.Font.body)
                .foregroundStyle(missing ? Theme.Color.textTertiary : Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
        }
        .padding(.trailing, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .help(bookmark.path ?? bookmark.query ?? "")
    }

    @ViewBuilder private var glyph: some View {
        switch bookmark.kind {
        case .file: FileGlyph(ext: ((bookmark.path ?? "") as NSString).pathExtension.lowercased(), selected: selected)
        case .folder: FolderGlyph(selected: selected)
        case .search: symbol("magnifyingglass")
        case .group: symbol("bookmark")
        case nil: symbol("questionmark.square.dashed")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: Theme.Size.iconSmall))
            .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textSecondary)
    }

    private var missing: Bool {
        guard let vault, let p = bookmark.path, bookmark.kind == .file || bookmark.kind == .folder else { return false }
        return !FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(p).path)
    }
}

struct BookmarkRowHost: View {
    let bookmark: Bookmark
    let vault: Vault?
    var selected: Bool

    var body: some View {
        BookmarkRow(bookmark: bookmark, vault: vault)
            .environment(\.flamingoRowSelected, selected)
            .id(bookmark.ctime)
    }
}

final class BookmarkCellView: NSHostingView<BookmarkRowHost>, SidebarSelectableCell {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var rowSelected: Bool {
        get { rootView.selected }
        set { rootView.selected = newValue }
    }
}
