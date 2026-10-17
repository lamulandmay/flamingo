import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import FlamingoCore
import FlamingoDesign

/// How a folder shows when no file is open: Finder's icon view or its column view.
enum FolderStyle: String, CaseIterable, Identifiable {
    case icons, columns
    var id: String { rawValue }
    var symbol: String { self == .icons ? "square.grid.2x2" : "rectangle.split.3x1" }
    var title: String { self == .icons ? "as Icons" : "as Columns" }
    /// ⌥⌘1 and ⌥⌘3: Finder's numbers for the same two views.
    var key: String { self == .icons ? "1" : "3" }
}

/// Where the folder surface is. `root` is the folder the first column lists, anywhere on
/// the Mac (a Finder favorite such as /Applications can be outside the vault); `trail` is
/// the item selected in each column. The surface follows the sidebar's folder, but only
/// when that folder changes, so coming back from a file finds the columns as they were.
/// Plan 01 owns.
@MainActor
final class ColumnBrowserModel: ObservableObject {
    @Published var style = Defaults.folderStyle { didSet { Defaults.folderStyle = style } }
    @Published private(set) var root: URL?
    /// The deepest folder on show: the last column's folder, or what the icon view lists.
    @Published private(set) var folder: URL?
    /// Bumped when `root` or `trail` change from outside the columns, so they rebuild.
    @Published private(set) var revision = 0
    /// Bumped to put the keyboard in the columns, as when a favorite is clicked.
    @Published private(set) var focusRevision = 0
    /// Hidden files, toggled with ⇧⌘. as in Finder; starts as Finder's own setting.
    @Published var showHidden = FinderSettings.showsAllFiles
    /// The item selected in each column, outermost first. Column `i + 1` lists `trail[i]`
    /// when it is a folder; a file ends the trail and gets the preview column.
    var trail: [URL] = []
    /// Column widths by position, for as long as the app runs.
    var widths: [CGFloat] = []
    var focusPending = false
    private var followed: URL?

    /// Starts the columns at `url`. `following` is the sidebar folder this place stands
    /// for, so the surface doesn't jump back to that folder when it next appears.
    func browse(_ url: URL, focus: Bool = false, following: URL?) {
        reset(to: url)
        followed = following.map(Self.normal)
        if focus { focusPending = true; focusRevision += 1 }
    }

    /// The sidebar chose a folder. Inside the columns already, select down to it; anywhere
    /// else, the columns start there.
    func follow(_ sidebarFolder: URL, force: Bool = false) {
        let target = Self.normal(sidebarFolder)
        guard force || target != followed else { return }
        followed = target
        guard let root else { reset(to: target); return }
        if target == root { return }
        guard let chain = Self.chain(from: root, to: target) else { reset(to: target); return }
        folder = target
        if !trail.starts(with: chain) {
            trail = chain
            revision += 1
        }
    }

    /// The columns show `file` selected in its folder, from the current root when the file
    /// is inside it, else from its folder. `following` is the sidebar folder it stands for.
    func reveal(_ file: URL, following: URL?) {
        let file = Self.normal(file), parent = file.deletingLastPathComponent()
        if let root, let chain = Self.chain(from: root, to: file) {
            trail = chain
        } else {
            root = Self.normal(parent)
            trail = [file]
        }
        folder = Self.normal(parent)
        followed = following.map(Self.normal)
        revision += 1
    }

    func requestFocus() {
        focusPending = true
        focusRevision += 1
    }

    /// The columns' own navigation: what is selected now, and the deepest folder shown.
    func columnsChanged(trail: [URL], folder: URL?) {
        self.trail = trail
        if self.folder != folder { self.folder = folder }
    }

    private func reset(to url: URL) {
        let url = Self.normal(url)
        root = url
        folder = url
        trail = []
        revision += 1
    }

    /// Folders from just inside `root` down to `target`, or nil when `target` isn't inside.
    nonisolated static func chain(from root: URL, to target: URL) -> [URL]? {
        let base = root.pathComponents, parts = target.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        var url = root
        return parts.dropFirst(base.count).map { part in
            url = url.appendingPathComponent(part, isDirectory: true)
            return normal(url)
        }
    }

    /// One spelling per place: standardized, no trailing slash, so URLs compare by path.
    nonisolated static func normal(_ url: URL) -> URL { URL(fileURLWithPath: url.standardizedFileURL.path) }
}

/// Finder's own settings that the columns honour.
enum FinderSettings {
    private static func value(_ key: String) -> Bool {
        CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) as? Bool ?? false
    }
    static var showsAllFiles: Bool { value("AppleShowAllFiles") }
    static var foldersFirst: Bool { value("_FXSortFoldersFirst") }
    /// Spring-loaded folders (Accessibility → Pointer Control): the delay, or nil when off.
    static var springDelay: TimeInterval? {
        let d = UserDefaults.standard
        guard d.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return nil }
        return d.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
    }
}

extension AppState {
    /// The sidebar's folder as a place on disk.
    var sidebarFolderURL: URL? {
        guard let v = vault else { return nil }
        guard let folder = selectedFolder, !folder.isEmpty else { return v.root }
        return v.root.appendingPathComponent(folder, isDirectory: true)
    }

    /// A Finder favorite, or any folder: shown in the folder surface with the keyboard in it.
    /// Inside the vault it also becomes the sidebar's folder, so the graph, search and
    /// history follow; outside it, only the surface moves.
    func openFavorite(_ url: URL) { showFolder(url, focus: true) }

    func showFolder(_ url: URL, focus: Bool) {
        let url = ColumnBrowserModel.normal(url)
        if mode != .files { mode = .files }
        // Close the file first, so the folder gets its own history entry and ⌘[ from a
        // file opened in the columns comes back to them.
        if selected != nil { select(nil, source: .sidebar) }
        if let v = vault, let rel = v.relativePath(of: url), !v.isState(url) {
            browser.browse(url, focus: focus, following: url)
            selectFromSidebar(folder: rel.isEmpty ? nil : rel, file: nil)
        } else {
            browser.browse(url, focus: focus, following: sidebarFolderURL)
            recordPlace(url)
        }
    }

    /// The ribbon's Finder button. From a file: its folder in columns, the file selected and
    /// previewed, the keyboard in the columns. From the columns: back where you were.
    func toggleFinderColumns() {
        if mode == .files, selected == nil, browser.style == .columns {
            if canGoBack { goBack() }
            return
        }
        showFolderStyle(.columns)
    }

    /// Icons or columns, from the View menu, the palette or the ribbon: the folder surface,
    /// with the file that was open selected in it and the keyboard in the columns.
    func showFolderStyle(_ style: FolderStyle) {
        browser.style = style
        if mode != .files { mode = .files }
        if let file = selected.flatMap(url(for:)) {
            select(nil, source: .sidebar)
            // Its own history entry, so ⌘[ goes back to the file.
            selectFromSidebar(folder: selectedFolder, file: nil)
            browser.reveal(file, following: sidebarFolderURL)
        }
        browser.requestFocus()
    }

    /// Opens what a column or tile shows: a folder becomes the place, a file in the vault
    /// opens here, an app or a file outside the vault opens the way Finder would.
    func openFromBrowser(_ url: URL, isFolder: Bool) {
        if isFolder { showFolder(url, focus: true); return }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let v = vault, let ref = v.ref(for: url), !v.isState(url), type?.conforms(to: .application) != true {
            jump(to: ref, anchor: nil)
        } else if !NSWorkspace.shared.open(url) {
            NSSound.beep()
        }
    }

    /// Files dropped or pasted into `folder`, anywhere on the Mac. A move inside the vault
    /// goes through `move(_:into:)` so thoughts follow; the rest is the file system's, off
    /// the main thread, a copy taking Finder's "copy" name when the name is taken.
    func transfer(_ urls: [URL], into folder: URL, moving: Bool) {
        var rest: [URL] = []
        for url in urls {
            if moving, let v = vault, let from = v.relativePath(of: url), !from.isEmpty, !v.isState(url),
               let into = v.relativePath(of: folder), !v.isState(folder) {
                move(from, into: into)
            } else {
                rest.append(url)
            }
        }
        guard !rest.isEmpty else { return }
        Task {
            let failed = await Task.detached(priority: .userInitiated) {
                FileDrop.transfer(rest, into: folder, moving: moving)
            }.value
            if let failed { showToast(ToastMessage(text: "Couldn't \(moving ? "move" : "copy") “\(failed)”")) }
        }
    }
}

/// Finder's rules for dropping and pasting files into a folder.
enum FileDrop {
    /// Somewhere `url` can go: not where it already is, not into itself.
    static func canDrop(_ url: URL, into folder: URL) -> Bool {
        url.deletingLastPathComponent().path != folder.path
            && folder.path != url.path && !folder.path.hasPrefix(url.path + "/")
    }

    /// A move on the same disk, a copy onto another; ⌥ copies, ⌘ moves. `keepsThoughts`
    /// is false when a vault file would leave the vault, which then copies so its thoughts
    /// aren't left behind.
    static func operation(_ urls: [URL], into folder: URL, mask: NSDragOperation, keepsThoughts: Bool) -> NSDragOperation {
        let canMove = !mask.isDisjoint(with: [.move, .generic]) && keepsThoughts
        let canCopy = mask.contains(.copy)
        if canMove, !canCopy || urls.allSatisfy({ sameVolume($0, folder) }) { return .move }
        return canCopy ? .copy : []
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = (try? a.resourceValues(forKeys: key))?.volumeIdentifier,
              let vb = (try? b.resourceValues(forKeys: key))?.volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// Moves or copies each file into `folder`; the name of the last one that failed.
    static func transfer(_ urls: [URL], into folder: URL, moving: Bool) -> String? {
        let fm = FileManager.default
        var failed: String?
        for url in urls {
            var dest = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                // Finder asks before replacing; a move here never replaces.
                if moving { failed = url.lastPathComponent; continue }
                dest = copyName(for: url, in: folder)
            }
            do {
                if moving { try fm.moveItem(at: url, to: dest) } else { try fm.copyItem(at: url, to: dest) }
            } catch {
                failed = url.lastPathComponent
            }
        }
        return failed
    }

    /// "name copy.ext", then "name copy 2.ext", as Finder names a duplicate.
    static func copyName(for url: URL, in folder: URL) -> URL {
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = base + (n == 1 ? " copy" : " copy \(n)") + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

// MARK: - The view

/// Finder's column view: one list per folder, side by side, the selection in each column
/// opening the next, a preview at the end for a file. Arrow keys walk it (← → between
/// columns), typing selects by name, Space is Quick Look, ⌘↓ or a double-click opens,
/// ⌘↑ goes to the enclosing folder, ⇧⌘. shows hidden files. Drop files on a folder (rest
/// on it to open it) or paste them with ⌘V. Drag a column's edge to
/// resize it (⌥ for all), double-click the edge to fit. Built from `NSTableView`s so
/// keyboard, type-select, scrolling and drag-out are the system's.
struct ColumnBrowser: NSViewRepresentable {
    let state: AppState
    @ObservedObject var model: ColumnBrowserModel
    let counts: [FileRef: Int]

    func makeNSView(context: Context) -> ColumnBrowserView { ColumnBrowserView(state: state, model: model) }

    func updateNSView(_ view: ColumnBrowserView, context: Context) { view.apply(counts: counts) }
}

/// One item in a column.
struct ColumnEntry: Equatable, Sendable {
    let url: URL
    let name: String
    /// A folder Finder would open as a column: a directory that isn't a package (an app,
    /// a Keynote file), or a link to one.
    let isFolder: Bool
    let isHidden: Bool
    /// A Finder alias; resolved when selected.
    let isAlias: Bool
}

@MainActor
final class ColumnBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                               @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    /// Finder's column density: the low end of DESIGN.md's 24–28pt rows.
    static let rowHeight: CGFloat = 24
    static let defaultWidth: CGFloat = 230
    static let widthRange: ClosedRange<CGFloat> = 120...560
    static let previewWidth: CGFloat = Theme.Size.rail

    let state: AppState
    let model: ColumnBrowserModel
    private let scroll = NSScrollView()
    private let strip = ColumnStrip()
    private var columns: [BrowserColumn] = []
    private var preview: NSHostingView<ColumnPreview>?
    private var previewURL: URL?
    private var revision = -1
    private var focusRevision = -1
    private var showHidden: Bool
    private var counts: [FileRef: Int] = [:]
    /// Above zero while the code, not the user, moves a selection.
    private var suppress = 0
    /// A column the keyboard should land in once it has listed its folder.
    private var pendingFocus: Int?
    /// The folder row a drag is hovering, opening once the spring delay passes.
    private var spring: (table: NSTableView, row: Int, work: DispatchWorkItem)?

    init(state: AppState, model: ColumnBrowserModel) {
        self.state = state
        self.model = model
        self.showHidden = model.showHidden
        super.init(frame: .zero)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        addSubview(scroll)
        setAccessibilityRole(.browser)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutColumns()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { takePendingFocus() }
    }

    /// Every SwiftUI update lands here; it does work only when something moved.
    func apply(counts newCounts: [FileRef: Int]) {
        let moved = model.revision != revision, relist = model.showHidden != showHidden
        revision = model.revision
        showHidden = model.showHidden
        if moved { rebuild() } else if relist { for c in columns { load(c) } }
        if model.focusRevision != focusRevision {
            focusRevision = model.focusRevision
            takePendingFocus()
        }
        if newCounts != counts {
            counts = newCounts
            for c in columns where c.loaded {
                let visible = c.table.rows(in: c.table.visibleRect)
                guard visible.length > 0 else { continue }
                c.table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
            }
        }
    }

    // MARK: Columns

    /// From `model.root`, replaying `model.trail` one column at a time as each folder lists.
    private func rebuild() {
        removeColumns(after: -1)
        hidePreview()
        guard let root = model.root else { layoutColumns(); return }
        appendColumn(root)
        layoutColumns()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func appendColumn(_ url: URL) {
        let index = columns.count
        let column = BrowserColumn(url: url)
        let table = column.table
        table.browser = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL])
        table.setAccessibilityLabel(FileManager.default.displayName(atPath: url.path))
        column.grip.onDrag = { [weak self, weak column] dx, all in
            guard let self, let column, let i = self.columns.firstIndex(where: { $0 === column }) else { return }
            self.resize(i, by: dx, all: all)
        }
        column.grip.onDoubleClick = { [weak self, weak column] in
            guard let self, let column, let i = self.columns.firstIndex(where: { $0 === column }) else { return }
            self.fit(i)
        }
        column.watcher = DirectoryWatcher(url: url) { [weak self, weak column] in
            guard let self, let column, self.columns.contains(where: { $0 === column }) else { return }
            self.load(column)
        }
        columns.append(column)
        strip.addSubview(column.scroll)
        for c in columns { strip.addSubview(c.grip, positioned: .above, relativeTo: nil) }
        if model.widths.count <= index { model.widths.append(contentsOf: Array(repeating: Self.defaultWidth, count: index + 1 - model.widths.count)) }
        load(column)
    }

    private func removeColumns(after index: Int) {
        guard columns.count > index + 1 else { return }
        for c in columns[(index + 1)...] {
            c.watcher = nil
            c.scroll.removeFromSuperview()
            c.grip.removeFromSuperview()
        }
        columns.removeSubrange((index + 1)...)
        if let p = pendingFocus, p > index { pendingFocus = nil }
    }

    private func load(_ column: BrowserColumn) {
        column.generation += 1
        let generation = column.generation, url = column.url
        let hidden = showHidden, foldersFirst = FinderSettings.foldersFirst
        Task { [weak self, weak column] in
            let entries = await Task.detached(priority: .userInitiated) {
                Self.list(url, showHidden: hidden, foldersFirst: foldersFirst)
            }.value
            guard let self, let column, column.generation == generation,
                  self.columns.contains(where: { $0 === column }) else { return }
            self.fill(column, with: entries)
        }
    }

    /// New contents for a column. Keeps its selection by URL; on the first listing, carries
    /// on down the trail; when the selected item is gone, the columns after it go too.
    private func fill(_ column: BrowserColumn, with entries: [ColumnEntry]) {
        guard let i = columns.firstIndex(where: { $0 === column }) else { return }
        let first = !column.loaded
        column.entries = entries
        column.loaded = true
        suppress += 1
        column.table.reloadData()
        let wanted = i < model.trail.count ? model.trail[i] : nil
        let row = wanted.flatMap { w in entries.firstIndex { $0.url == w } }
        if let row {
            column.table.selectRowIndexes([row], byExtendingSelection: false)
            if first { column.table.scrollRowToVisible(row) }
        } else {
            column.table.deselectAll(nil)
        }
        suppress -= 1
        if let row, first, columns.last === column {
            descend(into: entries[row], after: i)
            publish()
        } else if wanted != nil, row == nil {
            select(column: i, row: -1)
        }
        if pendingFocus == i {
            pendingFocus = nil
            focus(column: i, selectFirst: true)
        } else if first, model.focusPending, columns.last === column {
            takePendingFocus()
        }
        layoutColumns()
    }

    /// The user (or the keyboard) chose `row` in column `i`; -1 clears that column.
    private func select(column i: Int, row: Int) {
        var trail = Array(model.trail.prefix(i))
        removeColumns(after: i)
        if row >= 0, row < columns[i].entries.count {
            let entry = columns[i].entries[row]
            trail.append(entry.url)
            model.trail = trail
            descend(into: entry, after: i)
        } else {
            model.trail = trail
            hidePreview()
        }
        publish()
        layoutColumns()
        revealEnd()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// A folder (or an alias of one) opens the next column; anything else gets the preview.
    private func descend(into entry: ColumnEntry, after i: Int) {
        if entry.isFolder {
            hidePreview()
            appendColumn(entry.url)
        } else if entry.isAlias, let target = Self.resolveFolderAlias(entry.url) {
            hidePreview()
            appendColumn(target)
        } else {
            showPreview(entry)
        }
    }

    private func publish() {
        model.columnsChanged(trail: model.trail, folder: columns.last?.url)
    }

    private func width(_ i: Int) -> CGFloat { i < model.widths.count ? model.widths[i] : Self.defaultWidth }

    private func layoutColumns() {
        let height = max(0, scroll.contentSize.height)
        var x: CGFloat = 0
        var separators: [CGFloat] = []
        for (i, c) in columns.enumerated() {
            let w = width(i)
            c.scroll.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w
            separators.append(x)
            c.grip.frame = NSRect(x: x - 4, y: 0, width: 9, height: height)
            x += Theme.Size.hairline
        }
        let visible = scroll.contentSize.width
        if let preview {
            let w = max(Self.previewWidth, visible - x)
            preview.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w
        }
        strip.separators = separators
        strip.frame = NSRect(x: 0, y: 0, width: max(x, visible), height: height)
    }

    /// Scrolls so the last column (and the preview, as far as it fits) is in view.
    private func revealEnd() {
        let visible = scroll.contentView.bounds
        let end: CGFloat
        if let preview { end = min(preview.frame.maxX, preview.frame.minX + Self.previewWidth) }
        else { end = columns.last?.scroll.frame.maxX ?? 0 }
        let start = columns.last?.scroll.frame.minX ?? 0
        var x = visible.minX
        if end > visible.maxX { x = end - visible.width }
        if start < x { x = start }
        x = max(0, min(x, strip.frame.width - visible.width))
        guard abs(x - visible.minX) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.fastSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func resize(_ i: Int, by dx: CGFloat, all: Bool) {
        let w = min(max(width(i) + dx, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        if all { model.widths = model.widths.map { _ in w } } else if i < model.widths.count { model.widths[i] = w }
        layoutColumns()
    }

    /// Wide enough for the longest name, like Finder's double-click on the column edge.
    private func fit(_ i: Int) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.NS.body]
        let longest = columns[i].entries.lazy.map { ($0.name as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let w = min(max(longest + ColumnCellView.chrome, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        if i < model.widths.count { model.widths[i] = w.rounded(.up) }
        layoutColumns()
    }

    // MARK: Preview

    private func showPreview(_ entry: ColumnEntry) {
        let ref = state.vault?.ref(for: entry.url)
        let view = ColumnPreview(url: entry.url, name: entry.name, thoughts: ref.flatMap { counts[$0] } ?? 0) { [weak self] in
            self?.state.openFromBrowser(entry.url, isFolder: false)
        }
        if let preview {
            if previewURL != entry.url { preview.rootView = view }
        } else {
            let hosting = NSHostingView(rootView: view)
            strip.addSubview(hosting, positioned: .below, relativeTo: nil)
            preview = hosting
        }
        previewURL = entry.url
    }

    private func hidePreview() {
        preview?.removeFromSuperview()
        preview = nil
        previewURL = nil
    }

    // MARK: Keyboard

    private func takePendingFocus() {
        guard model.focusPending, let window, !columns.isEmpty else { return }
        model.focusPending = false
        let deepest = columns.lastIndex { $0.table.selectedRow >= 0 } ?? 0
        window.makeFirstResponder(columns[deepest].table)
    }

    private func focus(column i: Int, selectFirst: Bool) {
        guard i < columns.count else { return }
        let table = columns[i].table
        window?.makeFirstResponder(table)
        if selectFirst, table.selectedRow < 0, !columns[i].entries.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    fileprivate func moveRight(from table: NSTableView) {
        guard let i = index(of: table) else { return }
        guard table.selectedRow >= 0 else {
            if !columns[i].entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            return
        }
        guard i + 1 < columns.count else { return }
        if columns[i + 1].loaded { focus(column: i + 1, selectFirst: true) } else { pendingFocus = i + 1 }
        revealEnd()
    }

    fileprivate func moveLeft(from table: NSTableView) {
        guard let i = index(of: table), i > 0 else { return }
        window?.makeFirstResponder(columns[i - 1].table)
        table.deselectAll(nil)
    }

    /// ⌘↑: the enclosing folder becomes the first column, with this one selected in it.
    fileprivate func enclosingFolder() {
        guard let root = model.root, root.path != "/" else { NSSound.beep(); return }
        let parent = root.deletingLastPathComponent()
        let trail = [root] + model.trail
        state.showFolder(parent, focus: true)
        model.trail = trail
        revision = -1
        apply(counts: counts)
    }

    fileprivate func openSelection(in table: NSTableView, externally: Bool = false) {
        guard let i = index(of: table), table.selectedRow >= 0, table.selectedRow < columns[i].entries.count else { return }
        open(columns[i].entries[table.selectedRow], externally: externally)
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard let i = index(of: sender), sender.clickedRow >= 0, sender.clickedRow < columns[i].entries.count else { return }
        open(columns[i].entries[sender.clickedRow])
    }

    private func open(_ entry: ColumnEntry, externally: Bool = false) {
        if externally {
            if !NSWorkspace.shared.open(entry.url) { NSSound.beep() }
        } else {
            state.openFromBrowser(entry.url, isFolder: entry.isFolder)
        }
    }

    fileprivate func trashSelection(in table: NSTableView) -> Bool {
        guard let i = index(of: table), table.selectedRow >= 0, table.selectedRow < columns[i].entries.count,
              let rel = vaultPath(columns[i].entries[table.selectedRow].url) else { return false }
        state.requestTrash(rel, in: window)
        return true
    }

    fileprivate func toggleHidden() { model.showHidden.toggle() }

    fileprivate func copySelection(in table: NSTableView) -> Bool {
        guard let url = selectedURL(in: table) else { return false }
        return FileHandoff.copy(urls: [url])
    }

    private func index(of table: NSTableView) -> Int? { columns.firstIndex { $0.table === table } }

    private func selectedURL(in table: NSTableView) -> URL? {
        guard let i = index(of: table), table.selectedRow >= 0, table.selectedRow < columns[i].entries.count else { return nil }
        return columns[i].entries[table.selectedRow].url
    }

    /// The vault-relative path of a user file, or nil outside the vault (and for its root
    /// and Flamingo's own state).
    private func vaultPath(_ url: URL) -> String? {
        guard let v = state.vault, let rel = v.relativePath(of: url), !rel.isEmpty, !v.isState(url) else { return nil }
        return rel
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let i = index(of: tableView) else { return 0 }
        return columns[i].entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let i = index(of: tableView), row < columns[i].entries.count else { return nil }
        let entry = columns[i].entries[row]
        let cell = (tableView.makeView(withIdentifier: ColumnCellView.id, owner: nil) as? ColumnCellView) ?? ColumnCellView()
        let thoughts = vaultPath(entry.url).flatMap { counts[FileRef(relativePath: $0)] } ?? 0
        cell.configure(entry, icon: ColumnIcons.icon(for: entry.url), thoughts: thoughts)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: ColumnRowView.id, owner: nil) as? ColumnRowView) ?? ColumnRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard suppress == 0, let table = notification.object as? NSTableView, let i = index(of: table) else { return }
        select(column: i, row: table.selectedRow)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let i = index(of: tableView), row < columns[i].entries.count else { return nil }
        return columns[i].entries[row].name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let i = index(of: tableView), row < columns[i].entries.count else { return nil }
        let url = columns[i].entries[row].url
        return FileHandoff.pasteboardItem(url: url, relativePath: vaultPath(url))
    }

    // MARK: Drop and paste

    /// Onto a folder's row, that folder; anywhere else in a column, the column's folder.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        springLoad(tableView, row: dropOperation == .on ? row : -1)
        let urls = FileHandoff.fileURLs(on: info.draggingPasteboard)
        guard let folder = dropFolder(in: tableView, row: dropOperation == .on ? row : -1), !urls.isEmpty,
              urls.allSatisfy({ FileDrop.canDrop($0, into: folder) }) else { return [] }
        if folder == index(of: tableView).map({ columns[$0].url }) { tableView.setDropRow(-1, dropOperation: .on) }
        return dragOperation(urls, into: folder, mask: info.draggingSourceOperationMask)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        cancelSpring()
        let urls = FileHandoff.fileURLs(on: info.draggingPasteboard)
        guard let folder = dropFolder(in: tableView, row: row), !urls.isEmpty else { return false }
        let operation = dragOperation(urls, into: folder, mask: info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        state.transfer(urls, into: folder, moving: operation == .move)
        return true
    }

    /// Finder's spring-loading: a drag that rests on a folder opens it, so you can go deeper
    /// without letting go. Even a folder that can't take the drop opens, to reach inside it.
    private func springLoad(_ table: NSTableView, row: Int) {
        if let spring, spring.table === table, spring.row == row { return }
        cancelSpring()
        guard row >= 0, row != table.selectedRow, let delay = FinderSettings.springDelay,
              let i = index(of: table), dropFolder(in: table, row: row) != columns[i].url else { return }
        let work = DispatchWorkItem { [weak self, weak table] in
            guard let self, let table, row < table.numberOfRows else { return }
            self.spring = nil
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        spring = (table, row, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    fileprivate func cancelSpring() {
        spring?.work.cancel()
        spring = nil
    }

    /// ⌘V copies the clipboard's files in, ⌥⌘V moves them, as Finder's Move Item Here:
    /// into the selected folder, or else this column's folder.
    fileprivate func paste(in table: NSTableView, moving: Bool) {
        guard let folder = dropFolder(in: table, row: table.selectedRow) else { return }
        paste(into: folder, moving: moving)
    }

    private func paste(into folder: URL, moving: Bool) {
        let urls = FileHandoff.fileURLs(on: .general)
        guard !urls.isEmpty else { NSSound.beep(); return }
        state.transfer(urls, into: folder, moving: moving && keepsThoughts(urls, into: folder))
    }

    private func dropFolder(in table: NSTableView, row: Int) -> URL? {
        guard let i = index(of: table) else { return nil }
        guard row >= 0, row < columns[i].entries.count else { return columns[i].url }
        let entry = columns[i].entries[row]
        if entry.isFolder { return entry.url }
        if entry.isAlias, let target = Self.resolveFolderAlias(entry.url) { return target }
        return columns[i].url
    }

    private func dragOperation(_ urls: [URL], into folder: URL, mask: NSDragOperation) -> NSDragOperation {
        FileDrop.operation(urls, into: folder, mask: mask, keepsThoughts: keepsThoughts(urls, into: folder))
    }

    /// False when a vault file would leave the vault, and its thoughts with it.
    private func keepsThoughts(_ urls: [URL], into folder: URL) -> Bool {
        !urls.contains { vaultPath($0) != nil } || state.vault?.relativePath(of: folder) != nil
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let column = columns.first(where: { $0.table.menu === menu }) else { return }
        let row = column.table.contextRow
        guard row >= 0, row < column.entries.count else {
            let pasted = FileHandoff.fileURLs(on: .general).count
            if pasted > 0 {
                menu.addItem(ActionItem(pasted == 1 ? "Paste Item" : "Paste \(pasted) Items") { [weak self] in
                    self?.paste(into: column.url, moving: false)
                })
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([column.url]) })
            menu.addItem(ActionItem(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { [weak self] in self?.toggleHidden() })
            return
        }
        let entry = column.entries[row]
        let rel = vaultPath(entry.url)
        menu.addItem(ActionItem("Open") { [weak self] in self?.open(entry) })
        if !entry.isFolder {
            if rel != nil {
                menu.addItem(ActionItem("Open Beside") { [weak self] in
                    if let rel { self?.state.openBeside(FileRef(relativePath: rel)) }
                })
            }
            menu.addItem(ActionItem("Open in Default App") { [weak self] in self?.open(entry, externally: true) })
        }
        menu.addItem(ActionItem("Quick Look") { [weak self, weak column] in
            guard let self, let column else { return }
            column.table.selectRowIndexes([row], byExtendingSelection: false)
            self.window?.makeFirstResponder(column.table)
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) })
        menu.addItem(ActionItem(entry.isFolder ? "Copy Folder" : "Copy File") { FileHandoff.copy(urls: [entry.url]) })
        menu.addItem(ActionItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        })
        if let rel {
            menu.addItem(.separator())
            let marked = state.isBookmarked(rel, folder: entry.isFolder)
            menu.addItem(ActionItem(marked ? "Remove Bookmark" : "Bookmark") { [weak self] in
                self?.state.toggleBookmark(path: rel, folder: entry.isFolder)
            })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Move to Trash") { [weak self] in self?.state.requestTrash(rel, in: self?.window) })
        }
    }

    // MARK: Quick Look

    fileprivate var focusedTable: ColumnTableView? {
        columns.first { $0.table === window?.firstResponder }?.table
            ?? columns.last { $0.table.selectedRow >= 0 }?.table
    }

    private var quickLookURL: URL? { focusedTable.flatMap(selectedURL(in:)) }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL.map { $0 as NSURL }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let table = focusedTable else { return false }
        table.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let table = focusedTable, table.selectedRow >= 0,
              let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? ColumnCellView,
              let window = cell.window else { return .zero }
        return window.convertToScreen(cell.convert(cell.iconFrame, to: nil))
    }

    // MARK: Listing

    nonisolated static func list(_ url: URL, showHidden: Bool, foldersFirst: Bool) -> [ColumnEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .localizedNameKey,
                                         .isSymbolicLinkKey, .isAliasFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                                                       options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        let entries = urls.map { u -> ColumnEntry in
            let v = try? u.resourceValues(forKeys: keys)
            var folder = v?.isDirectory == true && v?.isPackage != true
            if v?.isSymbolicLink == true {
                let target = try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                folder = target?.isDirectory == true && target?.isPackage != true
            }
            return ColumnEntry(url: ColumnBrowserModel.normal(u), name: v?.localizedName ?? u.lastPathComponent,
                               isFolder: folder,
                               isHidden: v?.isHidden == true || u.lastPathComponent.hasPrefix("."),
                               isAlias: v?.isAliasFile == true && v?.isSymbolicLink != true)
        }
        let sorted = FinderOrder.sorted(entries, by: \.name)
        return foldersFirst ? sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder } : sorted
    }

    nonisolated static func resolveFolderAlias(_ url: URL) -> URL? {
        guard let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
        let v = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true ? ColumnBrowserModel.normal(target) : nil
    }
}

// MARK: - Pieces

/// One column: its folder, what it lists, its table, its edge, its watcher.
@MainActor
private final class BrowserColumn {
    let url: URL
    var entries: [ColumnEntry] = []
    var loaded = false
    var generation = 0
    let table = ColumnTableView()
    let scroll = ColumnScrollView()
    let grip = ColumnGrip()
    var watcher: DirectoryWatcher?

    init(url: URL) {
        self.url = url
        table.headerView = nil
        table.rowHeight = ColumnBrowserView.rowHeight
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.allowsTypeSelect = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column.name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Theme.Space.xs, left: 0, bottom: Theme.Space.s, right: 0)
        scroll.documentView = table
        table.sizeLastColumnToFit()
    }
}

/// A column's scroller. Up and down is its own; a sideways pan (or ⇧ with a wheel) goes
/// to the strip, so the columns slide under the fingers as in Finder.
private final class ColumnScrollView: NSScrollView {
    private var sideways = false

    override func scrollWheel(with event: NSEvent) {
        // Decided once per gesture, so its momentum keeps going the same way.
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if sideways, let strip = enclosingScrollView { strip.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// The columns' backdrop: the content colour and a hairline after each column.
private final class ColumnStrip: NSView {
    var separators: [CGFloat] = [] { didSet { if separators != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.NS.bg.setFill()
        dirtyRect.fill()
        Theme.NS.hairline.setFill()
        for x in separators { NSRect(x: x, y: 0, width: Theme.Size.hairline, height: bounds.height).fill() }
    }
}

/// The column's right edge: drag to resize (⌥ resizes every column), double-click to fit.
private final class ColumnGrip: NSView {
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var lastX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX, event.modifierFlags.contains(.option))
        lastX = x
    }
}

/// A column's list. Finder's keys on top of the table's own (↑ ↓, type-select).
private final class ColumnTableView: NSTableView {
    weak var browser: ColumnBrowserView?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 124: browser?.moveRight(from: self); return                      // →
            case 123: browser?.moveLeft(from: self); return                       // ←
            case 36, 76: browser?.openSelection(in: self); return                 // ↩
            case 49: toggleQuickLook(); return                                    // Space
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (event.keyCode, modifiers) {
        case (125, .command), (31, .command): browser?.openSelection(in: self); return true        // ⌘↓ ⌘O
        case (36, .command), (76, .command): browser?.openSelection(in: self, externally: true); return true // ⌘↩
        case (126, .command): browser?.enclosingFolder(); return true                              // ⌘↑
        case (51, .command): if !event.isARepeat, browser?.trashSelection(in: self) == true { return true }  // ⌘⌫
        case (47, [.command, .shift]): browser?.toggleHidden(); return true                         // ⇧⌘.
        case (16, .command): toggleQuickLook(); return true                                         // ⌘Y
        case (9, [.command, .option]): browser?.paste(in: self, moving: true); return true          // ⌥⌘V
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard window?.firstResponder === self else { return }
        _ = browser?.copySelection(in: self)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        browser?.cancelSpring()
    }

    @objc func paste(_ sender: Any?) {
        guard window?.firstResponder === self else { return }
        browser?.paste(in: self, moving: false)
    }

    private func toggleQuickLook() {
        guard selectedRow >= 0, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        return ok
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = browser
        panel.delegate = browser
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // The context menu is presented here, so the right-clicked row gets a ring in the
    // selection's shape instead of the system's box around it.
    private(set) var contextRow = -1

    override func rightMouseDown(with event: NSEvent) { showContextMenu(for: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showContextMenu(for: event); return }
        super.mouseDown(with: event)
    }

    private func showContextMenu(for event: NSEvent) {
        guard let menu else { return }
        contextRow = row(at: convert(event.locationInWindow, from: nil))
        (rowView(atRow: contextRow, makeIfNecessary: false) as? ColumnRowView)?.isContextTarget = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        (rowView(atRow: contextRow, makeIfNecessary: false) as? ColumnRowView)?.isContextTarget = false
        contextRow = -1
    }
}

/// Selection as a squircle: coral in the column that has the keyboard, grey in the
/// columns it passes through, as Finder greys the path behind the focused column.
private final class ColumnRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("column.row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isContextTarget = false {
        didSet { if isContextTarget != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func rightMouseDown(with event: NSEvent) {
        if let table = superview as? ColumnTableView { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let table = superview as? ColumnTableView { table.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isContextTarget else { return }
        let ring = NSBezierPath(squircleIn: bounds.insetBy(dx: Theme.Space.s, dy: 0), radius: Theme.Radius.s, offset: 0.5)
        ring.lineWidth = 1
        Theme.NS.accent.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    /// A folder about to take a drop lights up like a selection.
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        Theme.NS.selection.setFill()
        NSBezierPath(squircleIn: bounds.insetBy(dx: Theme.Space.s, dy: 0), radius: Theme.Radius.s).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let table = superview as? NSTableView
        let focused = table != nil && table?.window?.firstResponder === table && table?.window?.isKeyWindow == true
        (focused ? Theme.NS.selection : Theme.NS.fill).setFill()
        NSBezierPath(squircleIn: bounds.insetBy(dx: Theme.Space.s, dy: 0), radius: Theme.Radius.s).fill()
    }
}

/// Icon, name, then a thought count (Flamingo's own) and Finder's chevron for folders.
private final class ColumnCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("column.cell")
    static let iconSize: CGFloat = 16
    /// Everything in a row that isn't the name, for fitting a column to its names.
    static let chrome: CGFloat = Theme.Space.m * 2 + iconSize + Theme.Space.s * 2 + 8 + Theme.Space.s

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let badge = NSTextField(labelWithString: "")

    var iconFrame: NSRect { icon.frame }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = Theme.NS.body
        name.textColor = Theme.NS.text
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.usesSingleLineMode = true
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = Theme.NS.textTertiary
        badge.font = Theme.NS.small
        badge.textColor = Theme.NS.textTertiary
        badge.alignment = .right
        for v in [icon, name, chevron, badge] as [NSView] { addSubview(v) }
        textField = name
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ entry: ColumnEntry, icon image: NSImage, thoughts: Int) {
        icon.image = image
        name.stringValue = entry.name
        name.alphaValue = entry.isHidden ? 0.5 : 1
        icon.alphaValue = entry.isHidden ? 0.5 : 1
        chevron.isHidden = !entry.isFolder
        badge.isHidden = thoughts == 0
        badge.stringValue = thoughts > 0 ? String(thoughts) : ""
        toolTip = entry.url.path
        setAccessibilityLabel(entry.name)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let s = Self.iconSize
        icon.frame = NSRect(x: Theme.Space.m + Theme.Space.xs, y: ((h - s) / 2).rounded(), width: s, height: s)
        var right = bounds.width - Theme.Space.m - Theme.Space.xs
        if !chevron.isHidden {
            chevron.frame = NSRect(x: right - 8, y: ((h - 12) / 2).rounded(), width: 8, height: 12)
            right -= 8 + Theme.Space.xs
        }
        if !badge.isHidden {
            badge.sizeToFit()
            let w = badge.frame.width
            badge.frame = NSRect(x: right - w, y: ((h - badge.frame.height) / 2).rounded(), width: w, height: badge.frame.height)
            right -= w + Theme.Space.xs
        }
        name.sizeToFit()
        let x = icon.frame.maxX + Theme.Space.s - 2
        let th = name.frame.height
        name.frame = NSRect(x: x, y: ((h - th) / 2).rounded(), width: max(0, right - x), height: th)
    }
}

/// Real Finder icons (apps, folders with their own icons, documents), at 16pt.
@MainActor
enum ColumnIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: ColumnCellView.iconSize, height: ColumnCellView.iconSize)
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

/// Tells a column when its folder's entries change on disk, wherever the folder is.
private final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            // A copy or an unzip writes many times; list once it settles.
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}

/// A context-menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runAction() { run() }
}
