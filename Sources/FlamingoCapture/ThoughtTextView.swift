import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

enum ThoughtStyle {
    static let maxLines = 8
    static var font: NSFont { Theme.NS.body }
    static var text: NSColor { Theme.NS.text }
    static var accent: NSColor { Theme.NS.accent }
}

/// State shared by the text view and the `[[` completion list.
@MainActor
final class ThoughtEditorModel: ObservableObject {
    @Published var text = "" { didSet { onTextChange?(text) } }
    var onTextChange: ((String) -> Void)?
    @Published var textHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: ThoughtStyle.font))
    @Published private(set) var results: [LinkCandidate] = []
    @Published private(set) var selection = 0
    /// Whether the text view has the keyboard, for a focus ring drawn around it.
    @Published var isFocused = false

    private(set) var query: LinkQuery?
    private var matcher = LinkMatcher.empty
    private var prepareTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var revision = 0
    /// Esc hides the list for the link being typed; a new `[[` brings it back.
    private var dismissedStart: Int?
    weak var textView: NSTextView?

    var isCompleting: Bool { query != nil && !results.isEmpty }

    func setCandidates(_ candidates: [FileRef], recent: [FileRef]) {
        prepareTask?.cancel()
        revision += 1
        let version = revision
        prepareTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { LinkMatcher(candidates: candidates, recent: recent) }.value
            guard !Task.isCancelled, let self, self.revision == version else { return }
            self.matcher = prepared
            self.refreshCompletion()
        }
    }

    func refreshCompletion() {
        guard let tv = textView, tv.selectedRange().length == 0, !tv.hasMarkedText() else { return clear() }
        let q = LinkQuery.active(in: tv.string as NSString, cursor: tv.selectedRange().location)
        guard let q, q.start != dismissedStart else {
            if q == nil { dismissedStart = nil }
            return clear()
        }
        let changed = q != query
        query = q
        matchTask?.cancel()
        let matcher = matcher
        matchTask = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) { matcher.matches(q.text) }.value
            guard !Task.isCancelled, let self, self.query == q else { return }
            if next != self.results { self.results = next }
            if changed || self.selection >= self.results.count { self.selection = 0 }
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func select(_ index: Int) { if results.indices.contains(index) { selection = index } }

    func dismissCompletion() {
        dismissedStart = query?.start
        clear()
    }

    /// Completes the link being typed with the selected (or given) candidate.
    func accept(_ index: Int? = nil, suffix: String? = nil) {
        guard let tv = textView, let q = query else { return }
        let i = index ?? selection
        guard results.indices.contains(i) else { return }
        let edit = LinkInsertion.make(results[i], query: q, in: tv.string as NSString,
                                      cursor: tv.selectedRange().location, suffix: suffix)
        if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
            tv.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: edit.cursor, length: 0))
        tv.window?.makeFirstResponder(tv)
        refreshCompletion()
    }

    private func clear() {
        matchTask?.cancel()
        query = nil
        if !results.isEmpty { results = [] }
        selection = 0
    }
}

/// The multi-line field in the capture panel. Enter submits, Shift- or Option-Enter
/// breaks the line, Esc cancels. `[[` opens completion; arrows and Enter drive it.
struct ThoughtTextView: NSViewRepresentable {
    @ObservedObject var model: ThoughtEditorModel
    var editable = true
    /// Takes the keyboard as soon as it's on screen. A panel wants that; a field that sits
    /// beside a document (the inspector's) must not steal focus from it.
    var autofocus = true
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ThoughtScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = ThoughtNSTextView(frame: .zero, textContainer: container)
        tv.autofocus = autofocus
        let model = self.model
        tv.onFocus = { [weak model] in if model?.isFocused != $0 { model?.isFocused = $0 } }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFindBar = false
        tv.font = ThoughtStyle.font
        tv.textColor = ThoughtStyle.text
        tv.insertionPointColor = ThoughtStyle.accent
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.typingAttributes = context.coordinator.baseAttributes
        tv.string = model.text
        tv.delegate = context.coordinator

        let scroll = ThoughtScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = tv
        scroll.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.layoutChanged() }

        model.textView = tv
        context.coordinator.textView = tv
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: ThoughtScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView?.isEditable = editable
        guard let tv = context.coordinator.textView, tv.string != model.text, !tv.hasMarkedText() else { return }
        tv.string = model.text
        context.coordinator.textChanged()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ThoughtTextView
        weak var textView: ThoughtNSTextView?
        init(_ parent: ThoughtTextView) { self.parent = parent }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: ThoughtStyle.font, .foregroundColor: ThoughtStyle.text]
        }

        func textDidChange(_ notification: Notification) { textChanged() }

        func textViewDidChangeSelection(_ notification: Notification) { parent.model.refreshCompletion() }

        func textChanged() {
            guard let tv = textView else { return }
            if parent.model.text != tv.string { parent.model.text = tv.string }
            highlight()
            measure()
            parent.model.refreshCompletion()
        }

        func layoutChanged() { measure() }

        /// Colors `[[links]]` as they're typed. Skipped mid-composition so input methods
        /// keep their marked text.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage, !tv.hasMarkedText() else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes(baseAttributes, range: full)
            for r in WikilinkRanges.find(in: tv.string) {
                storage.addAttribute(.foregroundColor, value: ThoughtStyle.accent, range: r)
            }
            storage.endEditing()
            tv.typingAttributes = baseAttributes
        }

        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = ceil(lm.defaultLineHeight(for: ThoughtStyle.font))
            let used = ceil(lm.usedRect(for: tc).height)
            let h = min(max(used, line), line * CGFloat(ThoughtStyle.maxLines))
            if parent.model.textHeight != h { parent.model.textHeight = h }
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            let model = parent.model
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if model.isCompleting { model.accept() } else { parent.onSubmit() }
                return true
            case #selector(NSResponder.insertTab(_:)):
                if model.isCompleting { model.accept() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if model.isCompleting { model.dismissCompletion() } else { parent.onCancel() }
                return true
            case #selector(NSResponder.moveUp(_:)) where model.isCompleting:
                model.move(-1); return true
            case #selector(NSResponder.moveDown(_:)) where model.isCompleting:
                model.move(1); return true
            default:
                return false
            }
        }

        /// Typing `#` or `|` while the list is up completes the name and stays inside the link.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            let model = parent.model
            if let text, text == "#" || text == "|", model.isCompleting, !(model.query?.text.isEmpty ?? true) {
                model.accept(suffix: text)
                return false
            }
            return true
        }
    }
}

final class ThoughtNSTextView: NSTextView {
    var autofocus = true
    var onFocus: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard autofocus, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), !flags.isDisjoint(with: [.shift, .option]) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// The panel can be key while another app owns the menu bar, so the standard editing
    /// shortcuts can't rely on the main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.isKeyWindow == true, window?.firstResponder === self,
              flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, flags.contains(.shift)) {
        case ("x", false): cut(nil)
        case ("c", false): copy(nil)
        case ("v", false): pasteAsPlainText(nil)
        case ("a", false): selectAll(nil)
        case ("z", false): undoManager?.undo()
        case ("z", true): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class ThoughtScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        if contentSize.width != lastWidth {
            lastWidth = contentSize.width
            onWidthChange?()
        }
    }
}
