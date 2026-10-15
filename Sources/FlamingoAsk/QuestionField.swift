import AppKit
import SwiftUI
import FlamingoDesign

/// The Ask field, as a real `NSTextField`.
///
/// A SwiftUI `TextField` with `@FocusState` can't take first responder from the shell's
/// sidebar (an `NSOutlineView`), so ⌘4 left the keys going to the sidebar's type-to-select.
/// This field claims first responder itself: when it lands in a window, whenever that window
/// becomes key, and whenever `focusRequest` changes.
struct QuestionField: NSViewRepresentable {
    @Binding var text: String
    var secure = false
    var font: NSFont = Theme.NS.title
    var accessibility: String
    /// Bump to pull focus back into the field.
    var focusRequest = 0
    /// Learns the field, so the key monitor can tell when it has the keys.
    var host: HostWindow?
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? FocusingSecureField() : FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = Theme.NS.text
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = secure
        field.cell?.wraps = !secure
        field.cell?.isScrollable = secure
        field.maximumNumberOfLines = secure ? 1 : 4
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(accessibility)
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.lastRequest = focusRequest
        host?.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            field.invalidateIntrinsicContentSize()
        }
        if context.coordinator.lastRequest != focusRequest {
            context.coordinator.lastRequest = focusRequest
            DispatchQueue.main.async { (field as? FocusClaiming)?.claimFocus() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        let line = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: width, height: min(max(height ?? line, line), line * 4))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuestionField
        var lastRequest = 0
        init(parent: QuestionField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            field.invalidateIntrinsicContentSize()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) where !parent.secure:
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}

extension NSTextField {
    /// True while this field's editor has the keys.
    var isEditingNow: Bool {
        guard let window, let editor = currentEditor() else { return false }
        return window.firstResponder === editor
    }
}

private protocol FocusClaiming: NSTextField {}

extension FocusClaiming {
    func claimFocus() {
        guard let window, !isEditingNow, !isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(self)
        // Put the caret at the end rather than selecting the whole question.
        (currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (stringValue as NSString).length, length: 0))
    }
}

/// Shared behaviour of the two field classes: claim focus on arrival and when the window
/// becomes key. Async so it runs after the shell's own focus handling for the same event.
private final class FocusObserver {
    private var token: NSObjectProtocol?

    func watch(_ field: FocusClaiming) {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        guard let window = field.window else { return }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak field] _ in
            DispatchQueue.main.async { field?.claimFocus() }
        }
        DispatchQueue.main.async { [weak field] in field?.claimFocus() }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

private final class FocusingField: NSTextField, FocusClaiming {
    private let observer = FocusObserver()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer.watch(self)
    }
}

private final class FocusingSecureField: NSSecureTextField, FocusClaiming {
    private let observer = FocusObserver()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer.watch(self)
    }
}
