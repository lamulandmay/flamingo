import AppKit
import Quartz
import SwiftUI
import FlamingoDesign

/// The outline view behind the file explorer and the bookmarks. Leaves `Space.s` on the
/// left so disclosure triangles sit inside the selection shape, presents the context menu
/// itself (so the clicked row gets a ring that matches the selection shape instead of the
/// system's full-width box), renames rows in place, and takes keyboard focus when nothing
/// else has it. Plan 01 owns.
final class SidebarOutlineView: NSOutlineView, QLPreviewPanelDataSource {
    /// The row a context menu is open for, else -1.
    private(set) var contextRow = -1
    /// ⌫ / ⌦ with nothing held. Returns `false` to let the key through (it beeps).
    var onDelete: (() -> Bool)?
    /// ⌘⌫ in the focused outline. Kept separate from bookmark removal.
    var onCommandDelete: (() -> Bool)?
    /// Called after Escape or Space clears the focused outline's selection.
    var onClearSelection: (() -> Void)?
    /// ↩ with nothing held. Returns `false` to let the key through.
    var onReturn: (() -> Bool)?
    /// File copy when this outline owns focus; editors retain their text clipboard.
    var onCopy: (() -> Bool)?
    /// ⌘V copies the clipboard's files in, ⌥⌘V moves them. Returns `false` to let it through.
    var onPaste: ((_ moving: Bool) -> Bool)?
    /// What ⌘Y shows in Quick Look; nil leaves the key alone.
    var quickLookURL: (() -> URL?)?
    /// The pointer or the wheel moved over the list, for the explorer's idle timer.
    var onActivity: (() -> Void)?
    /// A context menu for empty space too, with `contextRow` -1.
    var menuOnEmptySpace = false

    /// One configured the way both sidebar lists want it.
    static func make(label: String) -> SidebarOutlineView {
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
        outline.setAccessibilityLabel(label)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar.name"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 40
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        return outline
    }

    /// A clear scroll view around `outline`, so the sidebar material shows through.
    static func scroll(_ outline: SidebarOutlineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Theme.Space.xs, left: 0, bottom: Theme.Space.s, right: 0)
        scroll.documentView = outline
        outline.sizeLastColumnToFit()
        return scroll
    }

    override func keyDown(with event: NSEvent) {
        if handleSelectionKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty {
            if event.keyCode == 51 || event.keyCode == 117, onDelete?() == true { return }
            if event.keyCode == 36 || event.keyCode == 76, onReturn?() == true { return }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSelectionKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard window?.firstResponder === self, editor == nil else { return }
        _ = onCopy?()
    }

    @objc func paste(_ sender: Any?) {
        guard window?.firstResponder === self, editor == nil else { return }
        if onPaste?(false) != true { NSSound.beep() }
    }

    /// Edit → Copy and Paste only where this list does them (not in the bookmarks).
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): onCopy != nil && selectedRow >= 0
        case #selector(paste(_:)): onPaste != nil && !FileHandoff.fileURLs(on: .general).isEmpty
        default: true
        }
    }

    private func handleSelectionKey(_ event: NSEvent) -> Bool {
        // Key equivalents visit views outside the responder chain. A document editor,
        // search field, or in-place rename must retain its own editing shortcuts.
        guard window?.firstResponder === self, editor == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.keyCode == 51, modifiers == .command {
            // Holding the shortcut must not trash the next row that becomes selected.
            if event.isARepeat { return true }
            return onCommandDelete?() == true
        }
        if modifiers.isEmpty, event.keyCode == 53 || event.keyCode == 49, selectedRow >= 0 {
            deselectAll(nil)
            onClearSelection?()
            return true
        }
        if event.keyCode == 9, modifiers == [.command, .option], let onPaste { return onPaste(true) }   // ⌥⌘V
        if event.keyCode == 16, modifiers == .command, quickLookURL?() != nil { toggleQuickLook(); return true } // ⌘Y
        return false
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL?() == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURL?().map { $0 as NSURL }
    }

    override func scrollWheel(with event: NSEvent) {
        onActivity?()
        super.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["activity"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["activity": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        onActivity?()
        super.mouseMoved(with: event)
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

    /// Keeps the row clear of the content insets (`scrollRowToVisible` ignores them), moving
    /// only as far as the nearest edge. For rows the list's own keys and renames reach.
    func scrollRowIntoView(_ row: Int) { bringRowIntoView(row, placement: .nearestEdge) }

    /// How far `bringRowIntoView` moves the list.
    enum RowPlacement {
        /// Just inside the nearest edge, only if the row is hidden.
        case nearestEdge
        /// About the middle, only if the row is hidden: the list following the open file.
        case centredIfHidden
        /// About the middle unless the row already sits comfortably inside: "reveal".
        case centredIfCramped
        /// A folder just opened, with what it holds: the list following the columns into it.
        case opened
    }

    /// The scroll position that shows `row` the way `placement` asks, or nil to stay put.
    /// `visible` is the clip's bounds; `insets` the scroll view's content insets; `contents`
    /// how far an opened folder's rows run below its own.
    static func scrollTarget(row rowRect: NSRect, visible: NSRect, insets: NSEdgeInsets, contentHeight: CGFloat,
                             placement: RowPlacement, contents: CGFloat = 0) -> CGFloat? {
        let top = visible.minY + insets.top, bottom = visible.maxY - insets.bottom
        let usable = max(rowRect.height, bottom - top)
        let shown = rowRect.minY >= top - 0.5 && rowRect.maxY <= bottom + 0.5
        let margin = min(rowRect.height * 1.5, usable / 4)
        let roomy = rowRect.minY >= top + margin - 0.5 && rowRect.maxY <= bottom - margin + 0.5
        var y: CGFloat
        switch placement {
        case .nearestEdge:
            if shown { return nil }
            y = rowRect.minY < top ? rowRect.minY - insets.top : rowRect.maxY + insets.bottom - visible.height
        case .centredIfHidden, .centredIfCramped:
            if placement == .centredIfHidden ? shown : roomy { return nil }
            // A little above the middle, where the eye starts reading a list.
            y = rowRect.midY - insets.top - usable * 0.45
        case .opened:
            // The folder and its rows, the folder first: no move while all of it shows, the
            // least move when only its rows run off the bottom, about the middle when the
            // folder itself is out of sight. Never so far that the folder leaves the top.
            let blockMaxY = rowRect.maxY + contents
            if rowRect.minY >= top - 0.5 && blockMaxY <= bottom + 0.5 { return nil }
            let folderAtTop = rowRect.minY - insets.top - margin
            let endAtBottom = blockMaxY + insets.bottom - visible.height
            y = shown ? max(visible.minY, min(folderAtTop, endAtBottom))
                : min(folderAtTop, max(endAtBottom, (rowRect.minY + blockMaxY) / 2 - insets.top - usable * 0.45))
        }
        let lowest = max(-insets.top, contentHeight + insets.bottom - visible.height)
        y = min(max(y, -insets.top), lowest)
        return abs(y - visible.minY) < 0.5 ? nil : y
    }

    /// Scrolls `row` into view as `placement` asks: smoothly, a long way by jumping to a screen
    /// short of it first. `completion` runs once it rests (at once when nothing moves).
    func bringRowIntoView(_ row: Int, placement: RowPlacement, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard row >= 0, row < numberOfRows, let scroll = enclosingScrollView else { completion?(); return }
        let clip = scroll.contentView
        let visible = clip.bounds
        var last = row
        if placement == .opened {
            let level = level(forRow: row)
            while last + 1 < numberOfRows, self.level(forRow: last + 1) > level { last += 1 }
        }
        guard let y = Self.scrollTarget(row: rect(ofRow: row), visible: visible, insets: scroll.contentInsets,
                                        contentHeight: bounds.height, placement: placement,
                                        contents: rect(ofRow: last).maxY - rect(ofRow: row).maxY) else { completion?(); return }
        let target = NSPoint(x: visible.origin.x, y: y)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            completion?()
            return
        }
        let distance = y - visible.minY
        if abs(distance) > visible.height * 2 {
            clip.setBoundsOrigin(NSPoint(x: target.x, y: y - (distance > 0 ? 1 : -1) * visible.height))
            scroll.reflectScrolledClipView(clip)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.normalSeconds
            context.timingFunction = SidebarMotion.timing
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            MainActor.assumeIsolated {
                scroll.reflectScrolledClipView(clip)
                completion?()
            }
        }
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Rename in place

    private lazy var renamer = RowRenamer(table: self)
    private var editor: NSTextField? { renamer.field }
    var isEditing: Bool { editor != nil }

    /// A text field over the row's name: ↩ or clicking away commits, Esc cancels. `leading`
    /// is where the name starts in the cell (after the glyph).
    func beginEditing(row: Int, text: String, selecting range: NSRange,
                      leading: CGFloat = Theme.Size.icon + Theme.Space.s, commit: @escaping (String) -> Void) {
        renamer.finish(commit: false)
        guard row >= 0, row < numberOfRows else { return }
        scrollRowIntoView(row)
        let cell = frameOfCell(atColumn: 0, row: row)
        let x = cell.minX + leading - 3
        let frame = NSRect(x: x, y: cell.minY + 3, width: max(60, cell.maxX - Theme.Space.s - x), height: cell.height - 6)
        renamer.begin(frame: frame, text: text, selecting: range, commit: commit)
    }

    private func finishEditing(commit: Bool) { renamer.finish(commit: commit) }

    override func reloadData() {
        finishEditing(commit: false)
        super.reloadData()
    }

    // MARK: Context menu

    // Never let NSTableView run the menu: its clicked-row highlight is a square box.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        if !showContextMenu(for: event) { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if editor != nil { finishEditing(commit: true) }
        if event.modifierFlags.contains(.control), showContextMenu(for: event) { return }
        // The row swells under the pointer while the button is down, as a SwiftUI press does.
        let row = row(at: convert(event.locationInWindow, from: nil))
        let pressed = row >= 0 ? rowView(atRow: row, makeIfNecessary: false) : nil
        if let pressed { PressAnimator.press(pressed) }
        super.mouseDown(with: event)
        if let pressed { PressAnimator.release(pressed) }
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 || menuOnEmptySpace, let menu else { return false }
        contextRow = row
        if row >= 0 { (rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isContextTarget = true }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        endContextMenu()
        contextRow = -1
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

/// A hosted row that turns accent when its row is selected.
@MainActor
protocol SidebarSelectableCell: AnyObject {
    var rowSelected: Bool { get set }
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
        NSBezierPath(squircleIn: rect, radius: Theme.Radius.s).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isContextTarget else { return }
        // The selection's outline offset half a stroke inward: concentric with the fill.
        let ring = NSBezierPath(squircleIn: bounds.insetBy(dx: Theme.Space.s, dy: 0), radius: Theme.Radius.s, offset: 0.5)
        ring.lineWidth = 1
        Theme.NS.accent.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    private func push(selectionTo view: NSView) {
        guard let cell = view as? SidebarSelectableCell, cell.rowSelected != isSelected else { return }
        cell.rowSelected = isSelected
    }

    /// An accent squircle in the selection's shape that blooms a little past it and fades, so
    /// the eye lands on a row the list was just led to. Under the name and glyph, over the fill.
    func pulse() {
        wantsLayer = true
        guard let layer else { return }
        layer.sublayers?.filter { $0.name == SidebarMotion.pulseName }.forEach { $0.removeFromSuperlayer() }
        let rect = bounds.insetBy(dx: Theme.Space.s, dy: 0)
        let bloom = CAShapeLayer()
        bloom.name = SidebarMotion.pulseName
        bloom.frame = rect
        bloom.path = SquircleGeometry.path(in: CGRect(origin: .zero, size: rect.size), radius: Theme.Radius.s)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bloom.fillColor = Theme.NS.accent.withAlphaComponent(0.5).cgColor
        }
        bloom.opacity = 0
        layer.insertSublayer(bloom, at: 0)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.2, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        var animations: [CAAnimation] = [fade]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.97
            grow.toValue = 1.05
            grow.timingFunction = SidebarMotion.timing
            animations.append(grow)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = SidebarMotion.pulseSeconds
        CATransaction.begin()
        CATransaction.setCompletionBlock { bloom.removeFromSuperlayer() }
        bloom.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}

/// The sidebar's AppKit motion: one curve for scrolling to a row and the reveal pulse. Theme's
/// SwiftUI tokens can't drive `NSAnimationContext`, so the curve lives here, beside
/// `Theme.Motion.normalSeconds`, until Theme has an AppKit one.
enum SidebarMotion {
    static var timing: CAMediaTimingFunction { Theme.Motion.curve }
    /// About 0.6 s: long enough to be seen after the list settles, gone before it is read.
    static var pulseSeconds: TimeInterval { 0.6 * slowdown }
    static let pulseName = "flamingo.pulse"
    /// `FLAMINGO_SLOWMO=6` plays the pulse six times slower, for screenshots.
    static let slowdown = max(1, Double(ProcessInfo.processInfo.environment["FLAMINGO_SLOWMO"] ?? "") ?? 1)
}

/// Hosts one `SidebarRow`. Transparent to hit-testing, so clicks, double-clicks and
/// right-clicks reach the outline view; hover still tracks through its tracking area.
final class SidebarCellView: NSHostingView<SidebarRowHost>, SidebarSelectableCell {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var rowSelected: Bool {
        get { rootView.selected }
        set { rootView.selected = newValue }
    }
}

/// A text field over a row's name, for renaming in place: ↩ or clicking away commits, Esc
/// cancels. The sidebar's lists and the columns share it.
@MainActor
final class RowRenamer: NSObject, NSTextFieldDelegate {
    private weak var table: NSTableView?
    private(set) var field: NSTextField?
    private var commit: ((String) -> Void)?
    /// After the field goes, committed or not.
    var onEnd: (() -> Void)?

    init(table: NSTableView) { self.table = table }

    var isEditing: Bool { field != nil }

    /// `frame` is in the table's coordinates.
    func begin(frame: NSRect, text: String, selecting range: NSRange, commit: @escaping (String) -> Void) {
        finish(commit: false)
        guard let table else { return }
        let field = NSTextField(string: text)
        field.font = Theme.NS.body
        field.textColor = Theme.NS.text
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Theme.NS.bg
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.wantsLayer = true
        field.frame = frame
        field.layer?.applySquircle(radius: Theme.Radius.s - 1, border: Theme.NS.accent)
        field.delegate = self
        table.addSubview(field)
        self.field = field
        self.commit = commit
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = range
    }

    func finish(commit shouldCommit: Bool) {
        guard let field else { return }
        let action = commit
        self.field = nil
        commit = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        if let table { table.window?.makeFirstResponder(table) }
        if shouldCommit { action?(text) }
        onEnd?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            finish(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finish(commit: true)
            return true
        default:
            return false
        }
    }
}
