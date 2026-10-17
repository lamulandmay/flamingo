import AppKit
import SwiftUI
import FlamingoCore

/// The fixed pool of four panes. Raw values never change: older snapshots hold `primary`
/// and `secondary`, and newer ones still write only those in their legacy fields.
enum DocumentPaneID: String, Codable, CaseIterable { case primary, secondary, third, fourth }

/// Navigation belongs to a document surface. The shell mirrors only the focused pane;
/// scrolling, loading or playing media in its neighbour cannot change the capture target.
@MainActor
final class DocumentPane: ObservableObject, Identifiable {
    let id: DocumentPaneID
    @Published private(set) var file: FileRef?
    @Published var anchor: FileAnchor? {
        didSet {
            guard anchor != oldValue else { return }
            if let file, let anchor { anchors[file.relativePath] = anchor }
            onLocationChanged?(self)
        }
    }
    @Published var jumpRequest: JumpRequest?
    @Published var sourceHighlight = ""
    @Published var readSource = false
    weak var navigator: AnchorNavigator?
    var anchors: [String: FileAnchor] = [:]
    /// Retained until startup identity reconciliation resolves an offline rename.
    var pendingFile: FileRef?
    private var focusPending = false
    var requestFocus: (() -> Void)? { didSet { fulfillFocusRequest() } }
    func focusWhenReady() { focusPending = true; fulfillFocusRequest() }
    func cancelFocusRequest() { focusPending = false }
    private func fulfillFocusRequest() {
        guard focusPending, requestFocus != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.focusPending, let focus = self.requestFocus else { return }
            self.focusPending = false
            focus()
        }
    }
    var onLocationChanged: ((DocumentPane) -> Void)?
    var onActivate: ((DocumentPaneID) -> Void)?

    init(id: DocumentPaneID) { self.id = id }
    func activate() { onActivate?(id) }

    func show(_ file: FileRef?) {
        guard self.file != file else { return }
        self.file = file
        pendingFile = nil
        navigator = nil
        focusPending = false
        requestFocus = nil
        jumpRequest = nil
        sourceHighlight = ""
        readSource = false
        anchor = nil
    }

    func reset() {
        cancelFocusRequest()
        show(nil); pendingFile = nil; anchors = [:]
        anchor = nil; jumpRequest = nil; sourceHighlight = ""; readSource = false; navigator = nil
    }

    var snapshot: SavedDocumentPane {
        SavedDocumentPane(file: file ?? pendingFile, anchor: anchor, anchors: anchors, readSource: readSource)
    }

    func restore(_ saved: SavedDocumentPane, in vault: Vault) {
        reset()
        anchors = saved.anchors
        if let file = saved.file, vault.exists(file) {
            show(file)
            anchor = saved.anchor ?? anchors[file.relativePath]
            jumpRequest = anchor.map { JumpRequest(file: file, anchor: $0) }
        } else { pendingFile = saved.file; anchor = saved.anchor }
        readSource = saved.readSource
    }

    func relocate(_ old: String, to new: String) {
        func moved(_ path: String) -> String { FileTree.contains(old, path) ? new + path.dropFirst(old.count) : path }
        anchors = Dictionary(anchors.map { (moved($0.key), $0.value) }, uniquingKeysWith: { _, next in next })
        if let pendingFile { self.pendingFile = FileRef(relativePath: moved(pendingFile.relativePath)) }
        if let file, FileTree.contains(old, file.relativePath) {
            let location = anchor, highlight = sourceHighlight, source = readSource
            show(FileRef(relativePath: moved(file.relativePath)))
            anchor = location; sourceHighlight = highlight; readSource = source
            jumpRequest = location.map { JumpRequest(file: self.file!, anchor: $0) }
        }
    }

    func remove(_ path: String) {
        anchors = anchors.filter { !FileTree.contains(path, $0.key) }
        if let file, FileTree.contains(path, file.relativePath) { show(nil) }
        if let pendingFile, FileTree.contains(path, pendingFile.relativePath) { self.pendingFile = nil; anchor = nil }
    }
}

/// Watches native events without consuming them, so PDFKit, Quick Look and NSTextView
/// keep their native selection/scroll behaviour while clicks and keyboard focus select a pane.
struct PaneActivationView: NSViewRepresentable {
    let pane: DocumentPane
    var fallbackFocus = false
    func makeNSView(context: Context) -> PaneActivationNSView {
        let view = PaneActivationNSView(); view.activate = { pane.activate() }
        view.pane = pane; view.fallbackFocus = fallbackFocus
        return view
    }
    func updateNSView(_ view: PaneActivationNSView, context: Context) {
        view.activate = { pane.activate() }; view.pane = pane; view.fallbackFocus = fallbackFocus
        if fallbackFocus, pane.requestFocus == nil { pane.requestFocus = { [weak view] in view?.focusContent() } }
    }
}

final class PaneActivationNSView: NSView {
    var activate: (() -> Void)?
    weak var pane: DocumentPane?
    var fallbackFocus = false
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { activate?(); return true }
    func focusContent() {
        guard let window else { return }
        // Quick Look can keep keyboard focus in a remote view. Clear the old pane’s
        // responder even when that service offers no local focusable child.
        window.makeFirstResponder(self)
    }
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        if fallbackFocus, pane?.requestFocus == nil { pane?.requestFocus = { [weak self] in self?.focusContent() } }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
            let point: NSPoint
            if event.type == .keyDown {
                guard let responder = window.firstResponder as? NSView, responder.window === window else { return event }
                point = self.convert(NSPoint(x: responder.bounds.midX, y: responder.bounds.midY), from: responder)
            } else { point = self.convert(event.locationInWindow, from: nil) }
            if self.bounds.contains(point) { self.activate?() }
            return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
