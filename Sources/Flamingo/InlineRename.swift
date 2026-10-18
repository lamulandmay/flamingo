import AppKit
import SwiftUI
import FlamingoDesign

/// A name made editable where it is shown: a tab, the title, a pane's header, a folder tile,
/// a search result. It opens with the name selected up to its extension, as Finder's rename
/// does, and grows as you type. ↩ or clicking away keeps the new name, Esc the old one.
/// Lists made of table rows use `RowRenamer` (SidebarOutline.swift) instead.
struct RenameField: View {
    let name: String
    /// A folder's whole name is selected; a file's up to its extension.
    var isFolder = false
    var font: NSFont = Theme.NS.body
    var alignment: NSTextAlignment = .natural
    var maxWidth: CGFloat = 320
    /// More than one: a name too long for `maxWidth` wraps onto up to this many lines, as
    /// under an icon in Finder. One: it scrolls.
    var lines = 1
    /// The new name, trimmed, when it differs from `name`.
    let commit: (String) -> Void
    /// After the field goes, renamed or not.
    let end: () -> Void
    @State private var draft: String

    init(name: String, isFolder: Bool = false, font: NSFont = Theme.NS.body, alignment: NSTextAlignment = .natural,
         maxWidth: CGFloat = 320, lines: Int = 1, commit: @escaping (String) -> Void, end: @escaping () -> Void) {
        self.name = name; self.isFolder = isFolder; self.font = font; self.alignment = alignment
        self.maxWidth = maxWidth; self.lines = lines; self.commit = commit; self.end = end
        _draft = State(initialValue: name)
    }

    var body: some View {
        RenameTextField(text: $draft, original: name, selection: Self.stem(of: name, isFolder: isFolder),
                        font: font, alignment: alignment, lines: lines, commit: commit, end: end)
            // As wide as the name, narrower only when there isn't the room.
            .frame(minWidth: 40, idealWidth: width, maxWidth: width)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Squircle(radius: Theme.Radius.s).fill(Theme.Color.bg))
            .overlay(Squircle(radius: Theme.Radius.s).strokeBorder(Theme.Color.accent, lineWidth: 1))
            // Sized before its neighbours in a stack, or a spacer beside it leaves it the minimum.
            .layoutPriority(1)
    }

    private var width: CGFloat {
        let text = (draft as NSString).size(withAttributes: [.font: font]).width
        return min(maxWidth, max(40, ceil(text) + 6))
    }

    /// What Finder selects when a rename starts: a file's name without its extension.
    static func stem(of name: String, isFolder: Bool) -> NSRange {
        let stem = isFolder ? name : (name as NSString).deletingPathExtension
        return NSRange(location: 0, length: (stem as NSString).length)
    }
}

private struct RenameTextField: NSViewRepresentable {
    @Binding var text: String
    let original: String
    let selection: NSRange
    let font: NSFont
    let alignment: NSTextAlignment
    let lines: Int
    let commit: (String) -> Void
    let end: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RenameNSTextField {
        let field = RenameNSTextField(string: original)
        field.font = font
        field.textColor = Theme.NS.text
        field.alignment = alignment
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        if lines > 1 {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = lines
            field.cell?.wraps = true
            field.cell?.isScrollable = false
        } else {
            field.lineBreakMode = .byClipping
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        field.selection = selection
        field.setAccessibilityLabel("Name")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: RenameNSTextField, context: Context) {
        context.coordinator.parent = self
    }

    /// As tall as the text needs at the width given: one line, or as many as it wraps onto.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: RenameNSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, let probe = field.cell?.copy() as? NSCell else { return nil }
        probe.stringValue = text
        let height = probe.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
        let line = probe.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
        return CGSize(width: width, height: min(ceil(height), ceil(line) * CGFloat(lines)))
    }

    static func dismantleNSView(_ field: RenameNSTextField, coordinator: Coordinator) {
        // Gone for some other reason than an edit ending (its row went): nothing is renamed.
        coordinator.done = true
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        var done = false
        init(_ parent: RenameTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Clicking away keeps the name, as in Finder.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? RenameNSTextField else { return }
            finish(field, commit: true, refocus: false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? RenameNSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(field, commit: true, refocus: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(field, commit: false, refocus: true)
                return true
            default:
                return false
            }
        }

        private func finish(_ field: RenameNSTextField, commit: Bool, refocus: Bool) {
            guard !done else { return }
            done = true
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if refocus { field.returnFocus() }
            let keep = commit && !name.isEmpty && name != parent.original
            if keep, refocus { parent.commit(name) }
            // A click elsewhere took the keyboard: rename once that hand-over is done, not in it.
            else if keep { let commit = parent.commit; DispatchQueue.main.async { commit(name) } }
            parent.end()
        }
    }
}

/// Takes the keyboard once it is in a window, and gives it back to whatever had it.
final class RenameNSTextField: NSTextField {
    var selection = NSRange()
    private weak var previous: NSResponder?
    private var focused = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !focused else { return }
        focused = true
        // Once SwiftUI has placed it, so the field editor opens where it shows.
        DispatchQueue.main.async { [weak self] in self?.takeFocus() }
    }

    private func takeFocus() {
        guard let window else { return }
        var before = window.firstResponder
        // A field being edited answers through its field editor; it is the field that gets it back.
        if let editor = before as? NSTextView, editor.isFieldEditor { before = editor.delegate as? NSResponder }
        previous = before === window ? nil : before
        guard window.makeFirstResponder(self) else { return }
        currentEditor()?.selectedRange = selection
    }

    func returnFocus() {
        guard let window else { return }
        if let view = previous as? NSView, view.window === window { window.makeFirstResponder(view) }
        else { window.makeFirstResponder(nil) }
    }
}
