import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The pinned folders as trees under sidebar material, each folder listed from disk when it
/// is first opened. An `NSOutlineView` so arrow keys, ←/→, type-to-select, scrolling and drag
/// and drop are the system's; each visible row hosts a `SidebarRow` so glyphs and type come
/// from `FlamingoDesign`. Drag a pin to reorder, drag a folder in (from Finder or from inside
/// a pin) to pin it, ⌫ on a pin unpins it. Plan 01 owns.
///
/// Sits at the window's left edge under the transparent title bar; `topInset` is the
/// title bar's height, so the first row starts below the traffic lights and rows scroll
/// under them.
struct Sidebar: View {
    @EnvironmentObject var state: AppState
    let topInset: CGFloat

    var body: some View {
        SidebarOutline(state: state, tree: state.tree, revision: state.treeRevision, selected: state.selected,
                       reveal: state.revealRequest, topInset: topInset)
    }
}

// MARK: - Representable

private struct SidebarOutline: NSViewRepresentable {
    let state: AppState
    let tree: FileTree
    let revision: Int
    let selected: FileRef?
    let reveal: RevealRequest?
    let topInset: CGFloat

    func makeCoordinator() -> SidebarCoordinator { SidebarCoordinator(state: state) }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState

        let outline = SidebarOutlineView()
        outline.headerView = nil
        outline.rowHeight = Theme.Size.row
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 14
        outline.indentationMarkerFollowsCell = true
        outline.autoresizesOutlineColumn = false
        outline.allowsTypeSelect = true
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        outline.focusRingType = .none
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.intercellSpacing = .zero
        outline.gridStyleMask = []
        outline.usesAutomaticRowHeights = false
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.setAccessibilityLabel("Files")
        outline.registerForDraggedTypes([SidebarCoordinator.folderType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .gap

        let column = NSTableColumn(identifier: SidebarCoordinator.columnID)
        column.resizingMask = .autoresizingMask
        column.minWidth = 40
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(SidebarCoordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu

        let scroll = NSScrollView(frame: material.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = outline
        outline.sizeLastColumnToFit()
        material.addSubview(scroll)

        coordinator.install(outline: outline, scroll: scroll)
        outline.onDelete = { [weak coordinator] in coordinator?.unpinSelected() ?? false }
        state.focusSidebar = { [weak outline] in
            guard let outline, let window = outline.window else { return }
            window.makeFirstResponder(outline)
        }
        coordinator.apply(tree: tree, revision: revision, selected: selected, reveal: reveal, topInset: topInset)
        return material
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        context.coordinator.apply(tree: tree, revision: revision, selected: selected, reveal: reveal, topInset: topInset)
    }
}

// MARK: - Coordinator

@MainActor
final class SidebarCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("sidebar.name")
    /// A folder dragged inside the sidebar; the string is its relative path.
    static let folderType = NSPasteboard.PasteboardType("com.flamingo.sidebar.folder")
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
    private var lastRevealID: UUID?
    /// True while the outline's selection is being changed programmatically.
    private var suppressSelection = false
    /// True while a reload restores expansion, so nothing is persisted mid-way.
    private var restoring = false

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func install(outline: SidebarOutlineView, scroll: NSScrollView) {
        self.outline = outline
        self.scroll = scroll
    }

    /// Called from `makeNSView` and every `updateNSView`. Cheap unless something changed.
    func apply(tree: FileTree, revision: Int, selected: FileRef?, reveal: RevealRequest?, topInset: CGFloat) {
        let top = topInset + Theme.Space.s
        if scroll.contentInsets.top != top {
            scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: Theme.Space.s, right: 0)
        }
        if tree !== self.tree {
            self.revision = revision
            reload(tree: tree, selected: selected)
        } else if revision != self.revision {
            self.revision = revision
            refresh(state.changedFolders)
        }
        if let reveal, reveal.id != lastRevealID {
            lastRevealID = reveal.id
            self.reveal(reveal.file, scroll: true)
        }
        if selected != lastSelected {
            lastSelected = selected
            if let selected {
                if selectedNode?.ref != selected, !self.reveal(selected, scroll: true) { deselectFile() }
            } else {
                deselectFile()
            }
        }
    }

    /// Clears a file selection made from outside (vault switch, file gone, a file under no
    /// pin). A selected folder stays: that is the sidebar's own doing.
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

    private func reload(tree: FileTree, selected: FileRef?) {
        self.tree = tree
        restoring = true
        suppressSelection = true
        outline.reloadData()
        // Pins start open; whatever the user opened or closed since is remembered.
        expanded = vault.flatMap { Defaults.expandedFolders(in: $0) } ?? Set(tree.root.children.map(\.id))
        // Top level only; `outlineViewItemDidExpand` carries the remembered state inward.
        for pin in tree.root.children where expanded.contains(pin.id) {
            outline.expandItem(pin)
        }
        if let selected { _ = reveal(selected, scroll: true) } else { outline.deselectAll(nil) }
        suppressSelection = false
        restoring = false
    }

    /// Re-lists loaded folders whose contents changed on disk. `""` means every one.
    private func refresh(_ folders: Set<String>) {
        guard !folders.isEmpty else { return }
        let targets = folders.contains("") ? tree.loadedFolders : folders.flatMap { tree.loadedNodes(at: $0) }
        var changed = false
        restoring = true
        suppressSelection = true
        for node in targets where tree.refresh(node) {
            changed = true
            outline.reloadItem(node, reloadChildren: true)
            for child in node.children where child.isFolder && expanded.contains(child.id) && !outline.isItemExpanded(child) {
                outline.expandItem(child)
            }
        }
        if changed, let ref = state.selected, let node = tree.node(for: ref) {
            let row = outline.row(forItem: node)
            if row >= 0, outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        suppressSelection = false
        restoring = false
    }

    private func persistExpansion() {
        guard let vault else { return }
        Defaults.setExpandedFolders(expanded, in: vault)
    }

    /// Expands the file's ancestors (outermost first), selects its row and, if asked,
    /// scrolls it into view. Never calls back into `state.select`. `false` when no pin
    /// shows the file.
    @discardableResult
    private func reveal(_ ref: FileRef, scroll shouldScroll: Bool) -> Bool {
        guard let node = tree.node(for: ref) else { return false }
        var ancestors: [FileNode] = []
        var p = node.parent
        while let n = p, n.depth >= 0 { ancestors.append(n); p = n.parent }
        for folder in ancestors.reversed() where !outline.isItemExpanded(folder) {
            outline.expandItem(folder)
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        suppressSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelection = false
        if shouldScroll { scrollRowIntoView(row) }
        return true
    }

    /// `scrollRowToVisible` ignores the title-bar inset; this keeps the row clear of it,
    /// with a short ease-out when the distance is small enough to follow.
    private func scrollRowIntoView(_ row: Int) {
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let rowRect = outline.rect(ofRow: row)
        let visible = clip.bounds
        let usableTop = visible.minY + insets.top
        let usableBottom = visible.maxY - insets.bottom
        var y = visible.origin.y
        if rowRect.minY < usableTop {
            y = rowRect.minY - insets.top
        } else if rowRect.maxY > usableBottom {
            y = rowRect.maxY + insets.bottom - visible.height
        } else {
            return
        }
        let lowest = max(-insets.top, outline.bounds.height + insets.bottom - visible.height)
        y = min(max(y, -insets.top), lowest)
        let target = NSPoint(x: visible.origin.x, y: y)
        if abs(y - visible.origin.y) < visible.height * 2 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fastSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return tree.root.children.count }
        return node.isFolder ? tree.load(node).count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return tree.root.children[index] }
        return tree.load(node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.isFolder else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(node.id, forType: Self.folderType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let fromSidebar = info.draggingPasteboard.string(forType: Self.folderType) != nil
        guard fromSidebar || !droppedFolders(info).isEmpty else { return [] }
        // Only between pins: a drop onto or inside a pin lands just before that pin.
        let pins = tree.root.children
        var target = index
        if let node = item as? FileNode, let pin = node.pin, let i = pins.firstIndex(of: pin) { target = i }
        else if target == NSOutlineViewDropOnItemIndex { target = pins.count }
        outlineView.setDropItem(nil, dropChildIndex: target)
        return fromSidebar ? .move : .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let at = index == NSOutlineViewDropOnItemIndex ? nil : index
        if let path = info.draggingPasteboard.string(forType: Self.folderType) {
            state.pin(path: path, at: at)
            return true
        }
        var pinned = false
        for (k, url) in droppedFolders(info).enumerated() {
            pinned = state.pin(url, at: at.map { $0 + k }) || pinned
        }
        return pinned
    }

    /// Folders inside the vault among dropped file URLs.
    private func droppedFolders(_ info: NSDraggingInfo) -> [URL] {
        guard let vault else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDir: ObjCBool = false
            return vault.contains(url) && !vault.isState(url) && !VaultScanner.isPackage(url)
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// ⌫ on a selected pin. `false` (so the key beeps) on anything else.
    func unpinSelected() -> Bool {
        guard let node = selectedNode, node.isPin else { return false }
        state.unpin(path: node.id)
        return true
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
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
        let node = selectedNode
        state.selectFromSidebar(folder: node.map { $0.ref == nil ? $0.id : ($0.id as NSString).deletingLastPathComponent },
                                file: node?.ref)
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
        if let ref = node.ref {
            add("Open in " + (state.defaultAppName(for: ref) ?? "Default App"), #selector(openInApp(_:)))
            add("Reveal in Finder", #selector(revealInFinder(_:)))
            add("Copy Path", #selector(copyPath(_:)))
            menu.addItem(.separator())
            add("Leave a Thought", #selector(leaveThought(_:)))
        } else {
            if node.isPin {
                add("Unpin", #selector(unpin(_:)))
            } else if !state.pins.contains(node.id) {
                add("Pin", #selector(pin(_:)))
            }
            add("Reveal in Finder", #selector(revealInFinder(_:)))
        }
    }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        state.pin(path: node.id)
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        state.unpin(path: node.id)
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.endContextMenu()
    }

    @objc private func openInApp(_ sender: NSMenuItem) {
        guard let ref = (sender.representedObject as? FileNode)?.ref else { return }
        state.openExternally(ref)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        // A folder has no ref; its relative path resolves the same way through the vault.
        state.revealInFinder(node.ref ?? FileRef(relativePath: node.id))
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let ref = (sender.representedObject as? FileNode)?.ref else { return }
        state.copyPath(ref)
    }

    @objc private func leaveThought(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, let ref = node.ref else { return }
        let row = outline.row(forItem: node)
        if row >= 0 {
            suppressSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelection = false
        }
        state.select(ref, source: .sidebar)
        state.leaveThought()
    }
}

// MARK: - Views

/// Leaves `Space.s` on the left so disclosure triangles sit inside the selection shape,
/// presents the context menu itself (so the clicked row gets a ring that matches the
/// selection shape instead of the system's full-width box), and takes keyboard focus
/// when nothing else has it.
final class SidebarOutlineView: NSOutlineView {
    /// The row a context menu is open for, else -1.
    private(set) var contextRow = -1
    /// ⌫ / ⌦ with nothing held. Returns `false` to let the key through (it beeps).
    var onDelete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty, onDelete?() == true { return }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Theme.Space.s
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x += Theme.Space.s
        frame.size.width = max(0, frame.size.width - Theme.Space.s)
        return frame
    }

    // Never let NSTableView run the menu: its clicked-row highlight is a square box.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        if !showContextMenu(for: event) { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showContextMenu(for: event) { return }
        super.mouseDown(with: event)
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let menu else { return false }
        contextRow = row
        (rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isContextTarget = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        endContextMenu()
        return true
    }

    func endContextMenu() {
        guard contextRow >= 0 else { return }
        (rowView(atRow: contextRow, makeIfNecessary: false) as? SidebarRowView)?.isContextTarget = false
        contextRow = -1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder === window || window.firstResponder === window.contentView else { return }
        window.makeFirstResponder(self)
    }
}

/// Selection as a rounded `Theme.NS.selection` fill inset by `Space.s`, the same whether
/// or not the outline has focus. Nothing behind rows: the material shows through.
final class SidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { if isSelected != oldValue { for view in subviews { push(selectionTo: view) } } }
    }

    /// True while a context menu is open for this row: a 1pt accent ring in the selection shape.
    var isContextTarget = false {
        didSet { if isContextTarget != oldValue { needsDisplay = true } }
    }

    /// Never `.emphasized`: the disclosure triangle keeps its colour on the tinted fill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        push(selectionTo: subview)
    }

    // The row is the hit view for clicks on its body. Context clicks go straight to the
    // outline view's own presenter; AppKit's default would route through `menu(for:)`.
    override func rightMouseDown(with event: NSEvent) {
        if let outline = superview as? SidebarOutlineView { outline.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let outline = superview as? SidebarOutlineView {
            outline.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Theme.Space.s, dy: 0)
        Theme.NS.selection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.s, yRadius: Theme.Radius.s).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isContextTarget else { return }
        let rect = bounds.insetBy(dx: Theme.Space.s + 0.5, dy: 0.5)
        let ring = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.s, yRadius: Theme.Radius.s)
        ring.lineWidth = 1
        Theme.NS.accent.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    private func push(selectionTo view: NSView) {
        guard let cell = view as? SidebarCellView, cell.rootView.selected != isSelected else { return }
        cell.rootView.selected = isSelected
    }
}

/// Hosts one `SidebarRow`. Transparent to hit-testing, so clicks, double-clicks and
/// right-clicks reach the outline view; hover still tracks through its tracking area.
final class SidebarCellView: NSHostingView<SidebarRowHost> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
