import SwiftUI
import PDFKit
import FlamingoCore
import FlamingoDesign

/// `PDFView` for `.pdf`. Publishes the current page as the anchor and is the shell's
/// `AnchorNavigator` while on screen, so ⌘↑/⌘↓ turn pages and a chip for page 4 lands
/// on page 4. Plan 01 owns.
struct PDFPreview: NSViewRepresentable {
    let pane: DocumentPane
    let file: FileRef
    let url: URL
    let modified: Date?
    let jump: JumpRequest?

    init(pane: DocumentPane, file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        self.pane = pane; self.file = file; self.url = url; self.modified = modified; self.jump = jump
    }
    init(state: AppState, file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        self.init(pane: state.activePane, file: file, url: url, modified: modified, jump: jump)
    }

    func makeCoordinator() -> PDFPreviewCoordinator { PDFPreviewCoordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = ThemedPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = Theme.NS.bg
        context.coordinator.attach(view, pane: pane)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.show(file, url: url, modified: modified, jump: jump)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: PDFPreviewCoordinator) {
        coordinator.detach()
    }
}

/// `PDFView` whose background follows the appearance.
final class ThemedPDFView: PDFView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = Theme.NS.bg
    }
}

@MainActor
final class PDFPreviewCoordinator: NSObject, AnchorNavigator {
    /// Last page per file, 1-based, for the lifetime of the process.
    private var lastPages: [URL: Int] = [:]

    private weak var pane: DocumentPane?
    private weak var pdfView: PDFView?
    private var file: FileRef?
    private var url: URL?
    private var modified: Date?
    private var lastAppliedJumpID: UUID?
    private var inViewUpdate = false
    private var syncScheduled = false

    var anchorKind: FileAnchor.Kind { .page }

    func attach(_ view: PDFView, pane: DocumentPane) {
        self.pane = pane
        pdfView = view
        pane.requestFocus = { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let pane, pane.navigator === self { pane.navigator = nil }
        pdfView?.document = nil
        pdfView = nil
    }

    /// From `updateNSView`: swaps the document when the file (or its contents) changed,
    /// restores the remembered page, and applies a pending jump request exactly once.
    func show(_ file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        guard let pane, let pdfView else { return }
        inViewUpdate = true
        defer { inViewUpdate = false }
        if pane.navigator !== self { pane.navigator = self }

        let firstPresentation = self.url == nil
        let pending = jump.flatMap { $0.file == file && $0.id != lastAppliedJumpID ? $0 : nil }
        if url != self.url || modified != self.modified {
            self.file = file
            self.url = url
            self.modified = modified
            let remembered = lastPages[url]
            pdfView.document = modified == nil ? nil : PDFDocument(url: url)
            var moved = false
            if let pending {
                lastAppliedJumpID = pending.id
                moved = go(to: firstPresentation ? (pane.anchor ?? pending.anchor) : pending.anchor)
            }
            if !moved, firstPresentation, let anchor = pane.anchor { moved = go(to: anchor) }
            if !moved, let remembered { go(toPage: remembered) }
            scheduleSync()
        } else if let pending {
            lastAppliedJumpID = pending.id
            go(to: pending.anchor)
        }
    }

    // MARK: AnchorNavigator

    func step(_ delta: Int) {
        guard let pdfView, let doc = pdfView.document, doc.pageCount > 0 else { return }
        let current = pdfView.currentPage.map { doc.index(for: $0) } ?? 0
        let target = min(max(current + delta, 0), doc.pageCount - 1)
        if target != current { go(toPage: target + 1) }
    }

    func jump(to anchor: FileAnchor) {
        // A stale navigator (selection just changed, view not yet swapped) must not move.
        guard let pane, pane.file == file else { return }
        // `AppState.jumpToAnchor` publishes the same request; mark it applied so
        // `updateNSView` does not apply it a second time.
        if let request = pane.jumpRequest, request.file == file, request.anchor == anchor {
            lastAppliedJumpID = request.id
        }
        go(to: anchor)
    }

    @discardableResult
    private func go(to anchor: FileAnchor) -> Bool {
        guard anchor.kind == .page, let n = anchor.number else { return false }
        return go(toPage: n)
    }

    /// 1-based, clamped to the document.
    @discardableResult
    private func go(toPage n: Int) -> Bool {
        guard let pdfView, let doc = pdfView.document, doc.pageCount > 0,
              let page = doc.page(at: min(max(n - 1, 0), doc.pageCount - 1)) else { return false }
        pdfView.go(to: page)
        return true
    }

    // MARK: Anchor

    @objc private func pageChanged(_ note: Notification) { syncAnchor() }

    /// Publishes the current page and remembers it. Deferred while SwiftUI is updating
    /// the view: publishing from inside an update is not allowed.
    private func syncAnchor() {
        if inViewUpdate { scheduleSync(); return }
        guard let pane, let pdfView, let file, pane.file == file, pane.navigator === self else { return }
        var anchor: FileAnchor?
        if let doc = pdfView.document, doc.pageCount > 0, let page = pdfView.currentPage {
            let n = doc.index(for: page) + 1
            anchor = .page(n)
            if let url { lastPages[url] = n }
        }
        if pane.anchor != anchor { pane.anchor = anchor }
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncAnchor()
        }
    }
}
