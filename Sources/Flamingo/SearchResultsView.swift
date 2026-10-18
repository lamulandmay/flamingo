import AppKit
import Quartz
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// Every file a search found, as Finder's list view: the query in a field at the top (edit it
/// and the list follows), Finder's columns, a click on a header to sort and again to turn it
/// around, a Kind filter and a quiet sort menu. ↩, ⌘↓ or a double-click opens a file here,
/// ⌘↩ in its app, Space is Quick Look, Esc goes back. It is a place in history, so ⌘[ from a
/// file opened out of it comes back to it as it was left. Plan 01 owns.
struct SearchResultsSurface: View {
    @Environment(AppState.self) var state
    @ObservedObject var model: SearchResultsModel
    @FocusState private var fieldFocused: Bool
    @State private var metaRefresh: Task<Void, Never>?

    /// The palette's dimming while a search is in flight.
    static let searchingOpacity = 0.55
    static let barHeight: CGFloat = 40
    static let fieldWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            bar
            Hairline()
                .overlay(alignment: .top) {
                    ProgressHairline(value: nil)
                        .opacity(model.searching ? 1 : 0)
                        .animation(Theme.Motion.fast, value: model.searching)
                }
            ZStack {
                SearchResultsTable(state: state, model: model)
                    .opacity(model.searching && !model.rows.isEmpty ? Self.searchingOpacity : 1)
                    .animation(Theme.Motion.fast, value: model.searching)
                empty
            }
        }
        .background(Theme.Color.bg)
        // Trashed, renamed or edited files: dates, sizes and vanished rows catch up.
        .onChange(of: state.treeRevision) { _, _ in
            metaRefresh?.cancel()
            metaRefresh = Task { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { model.refreshMeta() } }
        }
        // Icons or columns from the toolbar or the View menu: the folder, in that style.
        .onReceive(state.browser.$style.dropFirst()) { _ in state.leaveResults() }
    }

    private var bar: some View {
        HStack(spacing: Theme.Space.s) {
            SidebarSearchInput(text: $model.query, focused: $fieldFocused, focusToken: model.fieldFocusRequest, focusOnAppear: false,
                               onSubmit: { model.focusList() }, onExit: { model.focusList() },
                               onMove: { delta in
                                   guard delta > 0 else { return false }
                                   model.focusList()
                                   return true
                               })
                .frame(maxWidth: Self.fieldWidth)
            Text(count)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if model.kind != .all {
                Chip(model.kind.title, mono: false) { model.setKind(.all) }
                    .help("Show All Kinds")
                    .transition(.opacity)
            }
            Spacer(minLength: Theme.Space.s)
            IconMenu(systemName: model.kind == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                     help: "Kind") {
                ForEach(ResultsKind.allCases) { kind in
                    if kind == .folders || kind == .other { Divider() }
                    Toggle(kind.title, isOn: Binding(get: { model.kind == kind }, set: { _ in model.setKind(kind) }))
                }
            }
            IconMenu(systemName: "arrow.up.arrow.down", help: "Sort By") {
                ForEach(Array(ResultsSort.menu.enumerated()), id: \.offset) { index, column in
                    if index == 1 { Divider() }
                    Toggle(column?.title ?? "Relevance", isOn: Binding(get: { model.sort.column == column }, set: { _ in model.pickSort(column) }))
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Self.barHeight)
        .animation(Theme.Motion.fast, value: model.kind)
    }

    /// How many rows show: the user's data, not a sentence. `500+` when the search stopped there.
    private var count: String {
        guard !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.rows.isEmpty else { return "" }
        return model.rows.count.formatted() + (model.truncated && model.kind == .all ? "+" : "")
    }

    @ViewBuilder private var empty: some View {
        if model.rows.isEmpty, !model.searching {
            if let failure = model.failure {
                Text(failure)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyState("No matches")
            }
        }
    }
}

// MARK: - The table

struct SearchResultsTable: NSViewRepresentable {
    let state: AppState
    @ObservedObject var model: SearchResultsModel

    func makeNSView(context: Context) -> SearchResultsView { SearchResultsView(state: state, model: model) }

    func updateNSView(_ view: SearchResultsView, context: Context) { view.apply() }
}

/// The list itself: an `NSTableView`, so headers, resizing, reordering, type-select,
/// scrolling and drag-out are the system's, drawn with Flamingo's tokens.
@MainActor
final class SearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                               @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let rowHeight = Theme.Size.row
    static let headerHeight: CGFloat = 24
    /// Space before the first column's content and after the last one's, so text clears the
    /// selection's rounded ends.
    static let edgeInset = Theme.Space.m + Theme.Space.xs
    /// Order, natural widths and hidden columns, as Finder's list view keeps them. Not the
    /// table's autosave: that would keep widths squeezed to fit a narrow pane.
    static let columnsKey = "searchResults.columns"

    let state: AppState
    let model: SearchResultsModel
    private let scroll = NSScrollView()
    let table = ResultsTableView()
    private let headerMenu = NSMenu()
    private var rows: [ResultRow] = []
    private var revision = -1
    private var revealRevision = -1
    private var listFocusRevision: Int
    private(set) var sort = ResultsSort.relevance
    /// Above zero while the code, not the user, moves the selection.
    private var suppress = 0
    /// The width the columns were last fitted to.
    private var fittedWidth: CGFloat = 0
    /// Each column's width when there is room: its default, or where the user dragged it.
    private var natural: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    /// Above zero while `fitColumns` sets widths, so they aren't taken for the user's.
    private var fitting = 0

    init(state: AppState, model: SearchResultsModel) {
        self.state = state
        self.model = model
        self.listFocusRevision = model.listFocusRequest
        super.init(frame: .zero)
        configureTable()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = table
        addSubview(scroll)
        setAccessibilityRole(.group)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidResizeNotification, object: table)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidMoveNotification, object: table)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        if width > 0, abs(width - fittedWidth) > 0.5 { fitColumns(to: width) }
    }

    /// Name takes the pane's width, as in Finder. The other columns keep their natural widths
    /// while Name has a good share; past that they give way together, none below its minimum,
    /// and past those the list scrolls sideways. A drag on an edge sets that column's natural
    /// width and grows the table, as Finder's list does.
    private func fitColumns(to width: CGFloat) {
        fittedWidth = width
        guard width > 0, let name = table.tableColumn(withIdentifier: Self.identifier(.name)) else { return }
        let others = table.tableColumns.filter { !$0.isHidden && $0 !== name }
        let widths = Self.fit(width: width, nameMin: name.minWidth,
                              others: others.map { (natural[$0.identifier] ?? $0.width, $0.minWidth) })
        fitting += 1
        for (column, w) in zip(others, widths.others) { column.width = w }
        name.width = widths.name
        fitting -= 1
    }

    private struct SavedColumn: Codable {
        var id: String
        var width: CGFloat
        var hidden: Bool
    }

    private func restoreColumns() {
        guard let data = UserDefaults.standard.data(forKey: Self.columnsKey),
              let saved = try? JSONDecoder().decode([SavedColumn].self, from: data) else { return }
        var target = 0
        for column in saved {
            let id = NSUserInterfaceItemIdentifier(column.id)
            let from = table.column(withIdentifier: id)
            guard from >= 0, let c = table.tableColumn(withIdentifier: id) else { continue }
            c.isHidden = column.hidden && Self.column(of: id) != .name
            let width = max(c.minWidth, column.width)
            natural[id] = width
            c.width = width
            if from != target { table.moveColumn(from, toColumn: target) }
            target += 1
        }
    }

    private func saveColumns() {
        let saved = table.tableColumns.map { SavedColumn(id: $0.identifier.rawValue, width: natural[$0.identifier] ?? $0.width, hidden: $0.isHidden) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.columnsKey) }
    }

    /// Name's good share of the width, before the others give way.
    static let nameShare: CGFloat = 0.4

    /// The arithmetic of `fitColumns`: Name's width and the others', in order.
    static func fit(width: CGFloat, nameMin: CGFloat, others: [(natural: CGFloat, min: CGFloat)]) -> (name: CGFloat, others: [CGFloat]) {
        let naturalTotal = others.reduce(0) { $0 + $1.natural }
        let nameWanted = max(nameMin, (width * nameShare).rounded(.down))
        guard naturalTotal > 0, width - naturalTotal < nameWanted else {
            return (max(nameMin, width - naturalTotal), others.map(\.natural))
        }
        let room = max(others.reduce(0) { $0 + $1.min }, width - nameWanted)
        // Shrink in proportion; a column that reaches its minimum stays there and the rest
        // share what is left, until every column fits.
        var atMinimum = Set<Int>()
        var fitted = others.map(\.natural)
        while true {
            let free = others.indices.filter { !atMinimum.contains($0) }
            let freeNatural = free.reduce(0) { $0 + others[$1].natural }
            let freeRoom = room - atMinimum.reduce(0) { $0 + others[$1].min }
            guard freeNatural > 0 else { break }
            let scale = freeRoom / freeNatural
            var clamped = false
            for i in free {
                let w = (others[i].natural * scale).rounded(.down)
                if w < others[i].min { atMinimum.insert(i); fitted[i] = others[i].min; clamped = true } else { fitted[i] = w }
            }
            if !clamped { break }
        }
        return (max(nameMin, width - fitted.reduce(0, +)), fitted)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { takePendingFocus() }
    }

    private func configureTable() {
        table.host = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.rowHeight = Self.rowHeight
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsTypeSelect = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.usesAutomaticRowHeights = false
        // `fitColumns` shares the width out; the table's own autoresizing would fight it.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.cornerView = nil
        let header = ResultsHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: Self.headerHeight))
        header.host = self
        headerMenu.delegate = self
        header.menu = headerMenu
        table.headerView = header
        for column in ResultsColumn.allCases {
            let c = NSTableColumn(identifier: Self.identifier(column))
            c.title = column.title
            c.headerCell = ResultsHeaderCell(textCell: column.title)
            c.width = Self.width(column)
            c.minWidth = Self.minWidth(column)
            c.maxWidth = 2_000
            c.resizingMask = [.autoresizingMask, .userResizingMask]
            c.isHidden = !column.visibleByDefault
            c.headerToolTip = nil
            table.addTableColumn(c)
        }
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        table.menu = rowMenu
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        for c in table.tableColumns { natural[c.identifier] = c.width }
        restoreColumns()
        table.setAccessibilityLabel("Search Results")
    }

    static func identifier(_ column: ResultsColumn) -> NSUserInterfaceItemIdentifier { .init("results." + column.rawValue) }

    static func column(of identifier: NSUserInterfaceItemIdentifier?) -> ResultsColumn? {
        guard let raw = identifier?.rawValue, raw.hasPrefix("results.") else { return nil }
        return ResultsColumn(rawValue: String(raw.dropFirst("results.".count)))
    }

    private static func width(_ column: ResultsColumn) -> CGFloat {
        switch column {
        case .name: 260
        case .location: 140
        case .size: 84
        case .kind: 120
        case .modified, .added, .lastOpened, .created: 150
        }
    }

    private static func minWidth(_ column: ResultsColumn) -> CGFloat {
        switch column {
        case .name: 160
        case .size: 84
        case .kind: 96
        default: 72
        }
    }

    // MARK: Updates

    /// Every SwiftUI update lands here; it does work only when something moved.
    func apply() {
        if model.revision != revision {
            revision = model.revision
            rows = model.rows
            suppress += 1
            table.reloadData()
            restoreSelection()
            suppress -= 1
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }
        if model.sort != sort {
            sort = model.sort
            // An order picked from the menu shows its column, so its values can be read.
            if let column = sort.column, let c = table.tableColumn(withIdentifier: Self.identifier(column)), c.isHidden {
                c.isHidden = false
                fitColumns(to: scroll.contentSize.width)
                saveColumns()
            }
            table.headerView?.needsDisplay = true
        }
        if model.revealRevision != revealRevision {
            revealRevision = model.revealRevision
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
            else if !rows.isEmpty { table.scrollRowToVisible(0) }
        }
        if model.listFocusRequest != listFocusRevision {
            listFocusRevision = model.listFocusRequest
        }
        takePendingFocus()
    }

    /// The place's selection, by id; the first row when the list has just opened.
    private func restoreSelection() {
        var index = model.selection.flatMap { id in rows.firstIndex { $0.id == id } }
        if index == nil, model.wantsFirstRow, !rows.isEmpty {
            index = 0
            model.select(rows[0].id)
        }
        if let index { table.selectRowIndexes([index], byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    private func takePendingFocus() {
        guard model.focusPending, let window else { return }
        model.focusPending = false
        window.makeFirstResponder(table)
        if table.selectedRow < 0, model.wantsFirstRow, !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    @objc private func columnsChanged(_ note: Notification) {
        // A drag on an edge: that width is the column's own from now on.
        if fitting == 0, note.name == NSTableView.columnDidResizeNotification,
           let column = note.userInfo?["NSTableColumn"] as? NSTableColumn {
            natural[column.identifier] = column.width
        }
        if fitting == 0 { saveColumns() }
        // Dates shorten in narrow columns, and the edge insets follow the first and last.
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { table.headerView?.needsDisplay = true; return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        table.headerView?.needsDisplay = true
    }

    /// Leading and trailing insets for a column's content: wider at the table's two edges.
    func insets(for tableColumn: NSTableColumn?) -> (leading: CGFloat, trailing: CGFloat) {
        let shown = table.tableColumns.filter { !$0.isHidden }
        let leading = shown.first === tableColumn ? Self.edgeInset : Theme.Space.s
        let trailing = shown.last === tableColumn ? Self.edgeInset : Theme.Space.s
        return (leading, trailing)
    }

    // MARK: Actions

    fileprivate func openSelection(externally: Bool) {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { NSSound.beep(); return }
        model.open(rows[row], externally: externally)
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard rows.indices.contains(row) else { return }
        model.open(rows[row], externally: false)
    }

    fileprivate func goBack() {
        if state.canGoBack { state.goBack() } else { NSSound.beep() }
    }

    fileprivate func focusField() {
        model.focusField()
    }

    fileprivate func copySelection() -> Bool {
        guard let url = url(ofRow: table.selectedRow) else { return false }
        return FileHandoff.copy(urls: [url])
    }

    fileprivate func trashSelection() -> Bool {
        guard rows.indices.contains(table.selectedRow) else { return false }
        state.requestTrash(rows[table.selectedRow].result.file.relativePath, in: window)
        return true
    }

    /// A field over the row's name, the name without its extension selected, as in Finder.
    private func beginRename(_ item: ResultRow) {
        guard let row = rows.firstIndex(where: { $0.id == item.id }), let url = url(ofRow: row),
              let column = table.tableColumns.firstIndex(where: { Self.column(of: $0.identifier) == .name }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window?.makeFirstResponder(table)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? ResultsCellView else { return }
        let rowRect = table.rect(ofRow: row), cellRect = cell.convert(cell.bounds, to: table)
        // The field insets its text as the label does: at the label's x, the name stays put.
        let x = cell.convert(cell.labelFrame, to: table).minX
        // The field draws its text at its top; this puts it on the label's line.
        let frame = NSRect(x: x, y: rowRect.minY + 4.5, width: max(60, cellRect.maxX - Theme.Space.s - x), height: rowRect.height - 9)
        let name = url.lastPathComponent, path = item.result.file.relativePath
        table.renamer.begin(frame: frame, text: name, selecting: RenameField.stem(of: name, isFolder: item.result.isDirectory)) { [weak self] new in
            guard let self, new != name else { return }
            self.state.rename(path, to: new)
        }
    }

    private func url(ofRow row: Int) -> URL? {
        guard rows.indices.contains(row), let vault = state.vault else { return nil }
        return vault.url(for: rows[row].result.file)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = Self.column(of: tableColumn?.identifier) else { return nil }
        let item = rows[row]
        let (leading, trailing) = insets(for: tableColumn)
        if column == .name {
            let cell = (tableView.makeView(withIdentifier: ResultsCellView.nameID, owner: nil) as? ResultsCellView) ?? ResultsCellView(identifier: ResultsCellView.nameID)
            cell.configureName(item, selected: tableView.isRowSelected(row), leading: leading, trailing: trailing)
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: ResultsCellView.textID, owner: nil) as? ResultsCellView) ?? ResultsCellView(identifier: ResultsCellView.textID)
        let width = tableColumn?.width ?? 0
        switch column {
        case .location:
            let path = item.location
            cell.configureText(path.isEmpty ? (state.vault?.name ?? "") : path, alignment: .left, truncation: .byTruncatingHead,
                               leading: leading, trailing: trailing, tip: path.isEmpty ? state.vault?.root.path : path)
        case .size:
            cell.configureText(ResultsFormat.size(item), alignment: .right, truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .kind:
            cell.configureText(item.meta?.kind ?? "", alignment: .left, truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .modified:
            cell.configureText(ResultsFormat.date(item.meta?.modified ?? item.result.modified, width: width), alignment: .left,
                               truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .added:
            cell.configureText(ResultsFormat.date(item.meta?.added, width: width), alignment: .left, truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .lastOpened:
            cell.configureText(ResultsFormat.date(item.meta?.lastOpened, width: width), alignment: .left, truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .created:
            cell.configureText(ResultsFormat.date(item.meta?.created, width: width), alignment: .left, truncation: .byTruncatingTail, leading: leading, trailing: trailing)
        case .name:
            break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: ResultsRowView.id, owner: nil) as? ResultsRowView) ?? ResultsRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // The name's glyph turns accent with its row: redraw the rows whose state changed.
        let nameColumn = table.column(withIdentifier: Self.identifier(.name))
        if nameColumn >= 0 {
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [nameColumn])
            }
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        guard suppress == 0 else { return }
        let row = table.selectedRow
        model.select(rows.indices.contains(row) ? rows[row].id : nil)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row), Self.column(of: tableColumn?.identifier) == .name else { return nil }
        return rows[row].name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let url = url(ofRow: row) else { return nil }
        return FileHandoff.pasteboardItem(url: url, relativePath: rows[row].result.file.relativePath)
    }

    /// A click on a header sorts by it; again turns it around. Drags (resize, reorder) aren't clicks.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = Self.column(of: tableColumn.identifier) else { return }
        model.clickSort(column)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === headerMenu {
            // Finder's header menu: which columns show. Name always does.
            for column in ResultsColumn.allCases where column != .name {
                guard let c = table.tableColumn(withIdentifier: Self.identifier(column)) else { continue }
                let item = ActionItem(column.title) { [weak self, weak c] in
                    guard let c else { return }
                    c.isHidden.toggle()
                    if let self { self.fitColumns(to: self.scroll.contentSize.width) }
                    self?.columnsChanged(Notification(name: NSTableView.columnDidMoveNotification))
                }
                item.state = c.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        let row = table.contextRow
        guard rows.indices.contains(row), let url = url(ofRow: row) else { return }
        let item = rows[row]
        FileMenu.build(menu, url: url, isFolder: item.result.isDirectory, state: state, host: FileMenu.Host(
            open: { [weak self] in self?.model.open(item, externally: false) },
            rename: state.canRename(url) ? { [weak self] in self?.beginRename(item) } : nil,
            quickLook: { [weak self] in
                guard let self, let index = self.rows.firstIndex(where: { $0.id == item.id }) else { return }
                self.table.selectRowIndexes([index], byExtendingSelection: false)
                self.window?.makeFirstResponder(self.table)
                QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
            },
            window: window))
    }

    // MARK: Quick Look

    private var quickLookURL: URL? { url(ofRow: table.selectedRow) }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL.map { $0 as NSURL }
    }

    /// ↑ ↓ (and Space) in the Quick Look panel walk the list, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [125, 126, 49].contains(event.keyCode) else { return false }
        table.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        let column = table.column(withIdentifier: Self.identifier(.name))
        guard table.selectedRow >= 0, column >= 0,
              let cell = table.view(atColumn: column, row: table.selectedRow, makeIfNecessary: false) as? ResultsCellView,
              let window = cell.window else { return .zero }
        return window.convertToScreen(cell.convert(cell.iconFrame, to: nil))
    }
}

// MARK: - Pieces

/// Finder's keys on top of the table's own (↑ ↓, type-select).
final class ResultsTableView: NSTableView {
    weak var host: SearchResultsView?
    lazy var renamer = RowRenamer(table: self)

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 36, 76: host?.openSelection(externally: false); return       // ↩ opens here
            case 49: toggleQuickLook(); return                                // Space
            case 53: host?.goBack(); return                                   // Esc
            case 126 where selectedRow <= 0: host?.focusField(); return      // ↑ off the top: the field
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (event.keyCode, modifiers) {
        case (125, .command), (31, .command): host?.openSelection(externally: false); return true    // ⌘↓ ⌘O
        case (36, .command), (76, .command): host?.openSelection(externally: true); return true     // ⌘↩
        case (16, .command): toggleQuickLook(); return true                                         // ⌘Y
        case (51, .command): if !event.isARepeat, host?.trashSelection() == true { return true }   // ⌘⌫
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard window?.firstResponder === self else { return }
        _ = host?.copySelection()
    }

    private func toggleQuickLook() {
        guard selectedRow >= 0, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
        Log.debug("results: quick look \(panel.isVisible ? "shown" : "closed") \(panel.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "-")")
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
        panel.dataSource = host
        panel.delegate = host
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
        // The row swells under the pointer while the button is down, as a SwiftUI press does.
        let row = row(at: convert(event.locationInWindow, from: nil))
        let pressed = row >= 0 ? rowView(atRow: row, makeIfNecessary: false) : nil
        if let pressed { PressAnimator.press(pressed) }
        super.mouseDown(with: event)
        if let pressed { PressAnimator.release(pressed) }
    }

    private func showContextMenu(for event: NSEvent) {
        guard let menu else { return }
        contextRow = row(at: convert(event.locationInWindow, from: nil))
        guard contextRow >= 0 else { contextRow = -1; return }
        (rowView(atRow: contextRow, makeIfNecessary: false) as? ResultsRowView)?.isContextTarget = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        (rowView(atRow: contextRow, makeIfNecessary: false) as? ResultsRowView)?.isContextTarget = false
        contextRow = -1
    }
}

/// Selection as a squircle: coral while the list has the keyboard, grey when it doesn't.
final class ResultsRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("results.row")

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
        if let table = superview as? ResultsTableView { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    private var shape: NSRect { bounds.insetBy(dx: Theme.Space.s, dy: 0) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isContextTarget else { return }
        let ring = NSBezierPath(squircleIn: shape, radius: Theme.Radius.s, offset: 0.5)
        ring.lineWidth = 1
        Theme.NS.accent.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let table = superview as? NSTableView
        let focused = table != nil && table?.window?.firstResponder === table && table?.window?.isKeyWindow == true
        (focused ? Theme.NS.selection : Theme.NS.fill).setFill()
        NSBezierPath(squircleIn: shape, radius: Theme.Radius.s).fill()
    }
}

/// A name with its family glyph, or one quiet value.
final class ResultsCellView: NSTableCellView {
    static let nameID = NSUserInterfaceItemIdentifier("results.cell.name")
    static let textID = NSUserInterfaceItemIdentifier("results.cell.text")
    /// `FileGlyph`'s fixed width at the small icon size, so names line up.
    static let glyphWidth = (Theme.Size.iconSmall * 1.35).rounded()
    /// Theme's secondary size with even digits, so dates and sizes line up.
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: Theme.NS.small.pointSize, weight: .regular)

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var leading: CGFloat = Theme.Space.s
    private var trailing: CGFloat = Theme.Space.s
    private var showsIcon = false

    var iconFrame: NSRect { icon.frame }
    var labelFrame: NSRect { label.frame }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleNone
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configureName(_ row: ResultRow, selected: Bool, leading: CGFloat, trailing: CGFloat) {
        showsIcon = true
        icon.isHidden = false
        let ext = row.result.file.ext
        if row.result.isDirectory {
            icon.image = FileGlyph.nsFolderImage(size: Theme.Size.iconSmall)
            icon.contentTintColor = selected ? Theme.NS.accent : Theme.NS.textSecondary
        } else {
            icon.image = FileGlyph.nsImage(ext: ext, size: Theme.Size.iconSmall)
            icon.contentTintColor = Theme.NS.family(ext: ext, selected: selected)
        }
        label.stringValue = row.name
        label.font = Theme.NS.body
        label.textColor = Theme.NS.text
        label.alignment = .left
        label.lineBreakMode = .byTruncatingMiddle
        toolTip = row.result.file.relativePath
        setAccessibilityLabel(row.name)
        self.leading = leading
        self.trailing = trailing
        needsLayout = true
    }

    func configureText(_ text: String, alignment: NSTextAlignment, truncation: NSLineBreakMode,
                       leading: CGFloat, trailing: CGFloat, tip: String? = nil) {
        showsIcon = false
        icon.isHidden = true
        label.stringValue = text
        label.font = Self.valueFont
        label.textColor = Theme.NS.textSecondary
        label.alignment = alignment
        label.lineBreakMode = truncation
        toolTip = tip
        setAccessibilityLabel(text)
        self.leading = leading
        self.trailing = trailing
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = leading
        if showsIcon {
            let size = Self.glyphWidth
            icon.frame = NSRect(x: x, y: ((h - size) / 2).rounded(), width: size, height: size)
            x = icon.frame.maxX + Theme.Space.s - 2
        }
        let th = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: ((h - th) / 2).rounded(), width: max(0, bounds.width - trailing - x), height: th)
    }
}

/// The header: the content colour, a hairline under it, nothing else of the system's.
final class ResultsHeaderView: NSTableHeaderView {
    weak var host: SearchResultsView?

    override func draw(_ dirtyRect: NSRect) {
        Theme.NS.bg.setFill()
        dirtyRect.fill()
        guard let table = tableView else { return }
        for i in 0..<table.numberOfColumns {
            let column = table.tableColumns[i]
            guard !column.isHidden else { continue }
            let rect = headerRect(ofColumn: i)
            guard rect.intersects(dirtyRect), let cell = column.headerCell as? ResultsHeaderCell else { continue }
            cell.drawHeader(in: rect, of: column, host: host)
        }
        Theme.NS.hairline.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.maxY - Theme.Size.hairline, width: dirtyRect.width, height: Theme.Size.hairline).fill()
    }
}

/// A column's title in the secondary size, Finder's chevron on the column the list is sorted
/// by, and a short hairline between columns.
final class ResultsHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let header = controlView as? ResultsHeaderView, let table = header.tableView else { return }
        let index = table.column(at: NSPoint(x: cellFrame.midX, y: 0))
        guard index >= 0 else { return }
        drawHeader(in: cellFrame, of: table.tableColumns[index], host: header.host)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}

    func drawHeader(in rect: NSRect, of tableColumn: NSTableColumn, host: SearchResultsView?) {
        let column = SearchResultsView.column(of: tableColumn.identifier)
        let sorted = column != nil && host?.sort.column == column
        let (leading, trailing) = host?.insets(for: tableColumn) ?? (Theme.Space.s, Theme.Space.s)
        let right = column == .size
        var textRect = rect
        textRect.origin.x += leading
        textRect.size.width -= leading + trailing
        // The chevron sits at the column's trailing edge, as in Finder.
        if sorted, let ascending = host?.sort.ascending,
           let chevron = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            let tinted = chevron.tinted(Theme.NS.textSecondary)
            let size = tinted.size
            let x = right ? textRect.minX : textRect.maxX - size.width
            tinted.draw(in: NSRect(x: x, y: (rect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if right { textRect.origin.x += size.width + Theme.Space.xs }
            textRect.size.width -= size.width + Theme.Space.xs
        }
        let style = NSMutableParagraphStyle()
        style.alignment = right ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: sorted ? NSFont.systemFont(ofSize: Theme.NS.small.pointSize, weight: .medium) : Theme.NS.small,
            .foregroundColor: sorted ? Theme.NS.text : Theme.NS.textSecondary,
            .paragraphStyle: style,
        ]
        let title = tableColumn.title as NSString
        let height = title.size(withAttributes: attributes).height
        title.draw(in: NSRect(x: textRect.minX, y: rect.midY - height / 2, width: max(0, textRect.width), height: height), withAttributes: attributes)
        // A short hairline after every column but the last on show.
        if let table = tableColumn.tableView, table.tableColumns.last(where: { !$0.isHidden }) !== tableColumn {
            Theme.NS.hairline.setFill()
            NSRect(x: rect.maxX - Theme.Size.hairline, y: rect.minY + 6, width: Theme.Size.hairline, height: rect.height - 12).fill()
        }
    }
}

private extension NSImage {
    /// A template symbol drawn in one colour.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
