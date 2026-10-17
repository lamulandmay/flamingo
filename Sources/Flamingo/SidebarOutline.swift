import AppKit
import SwiftUI
import FlamingoDesign

/// The outline view behind the file explorer and the bookmarks. Leaves `Space.s` on the
/// left so disclosure triangles sit inside the selection shape, presents the context menu
/// itself (so the clicked row gets a ring that matches the selection shape instead of the
/// system's full-width box), renames rows in place, and takes keyboard focus when nothing
/// else has it. Plan 01 owns.
final class SidebarOutlineView: NSOutlineView, NSTextFieldDelegate {
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
        return false
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

    /// `scrollRowToVisible` ignores the content insets; this keeps the row clear of them,
    /// with a short ease-out when the distance is small enough to follow.
    func scrollRowIntoView(_ row: Int) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let rowRect = rect(ofRow: row)
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
        let lowest = max(-insets.top, bounds.height + insets.bottom - visible.height)
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

    // MARK: Rename in place

    private var editor: NSTextField?
    private var commitEdit: ((String) -> Void)?

    /// A text field over the row's name: ↩ or clicking away commits, Esc cancels. `leading`
    /// is where the name starts in the cell (after the glyph).
    func beginEditing(row: Int, text: String, selecting range: NSRange,
                      leading: CGFloat = Theme.Size.icon + Theme.Space.s, commit: @escaping (String) -> Void) {
        finishEditing(commit: false)
        guard row >= 0, row < numberOfRows else { return }
        scrollRowIntoView(row)
        let cell = frameOfCell(atColumn: 0, row: row)
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
        let x = cell.minX + leading - 3
        field.frame = NSRect(x: x, y: cell.minY + 3, width: max(60, cell.maxX - Theme.Space.s - x), height: cell.height - 6)
        field.layer?.applySquircle(radius: Theme.Radius.s - 1, border: Theme.NS.accent)
        field.delegate = self
        addSubview(field)
        editor = field
        commitEdit = commit
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = range
    }

    private func finishEditing(commit: Bool) {
        guard let field = editor else { return }
        let action = commitEdit
        editor = nil
        commitEdit = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit { action?(text) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        default:
            return false
        }
    }

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
