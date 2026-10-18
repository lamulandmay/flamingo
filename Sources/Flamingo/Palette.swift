import AppKit
import Combine
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// ⌘K / ⌘F share one search across names, folders, contents and thoughts.
/// Prefix with > to run application commands.
/// Plan 01 owns.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()
    private(set) var isVisible = false

    static let fieldHeight: CGFloat = 40
    static let statusHeight: CGFloat = 26
    static let recentLimit = 8
    static let matchLimit = 12
    static let hitLimit = 50
    /// Added to a command's score so "graph" finds the Graph mode above `graph.pdf`.
    static let commandBoost = 6
    static let debounce: UInt64 = 70_000_000

    private let model = PaletteModel()
    private var panel: PalettePanel?
    private weak var state: AppState?
    private weak var host: NSWindow?
    private var presentedFromAnyApp = false
    private var presentationScreen: NSScreen?
    private var commands: [PaletteCommand] = []
    private var table: Fuzzy.FileTable?
    private var tableFiles: [FileRef] = []
    /// `AppState.filesVersion` the table was built from; -1 before the first build.
    private var tableVersion = -1
    private var tableTask: Task<Void, Never>?
    private var rankTask: Task<Void, Never>?
    private var statusSubscription: AnyCancellable?
    private var catalogSubscription: AnyCancellable?
    private var wasIndexing = false
    /// Above this many files, building the table and ranking it run off the main thread.
    static let asyncTableThreshold = 20_000
    private var searchTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every show and hide so a stale fade-out never orders out a re-shown panel.
    private var generation = 0
    private var focusAttempts = 0
    private var requestedResult: UnifiedSearchResult?

    private override init() {
        super.init()
        model.queryDidChange = { [weak self] in self?.refreshItems() }
        model.onItems = { [weak self] in self?.layout() }
        model.onRun = { [weak self] item, externally in self?.run(item, externally: externally) }
        model.onList = { [weak self] in self?.showList() }
        model.onCancel = { [weak self] in self?.hide() }
    }

    // MARK: Showing

    /// ⌘K / ⌘F. While visible, the same mode toggles the panel away; the other mode switches
    /// in place and keeps what was typed.
    func show(mode: PaletteMode, state: AppState) {
        present(mode: mode, state: state, fromAnyApp: false)
    }

    /// Takes keyboard focus without activating Flamingo or covering the destination
    /// app with the main window. The native nonactivating panel returns focus on Esc.
    func showFromAnyApp(state: AppState) {
        present(mode: .search, state: state, fromAnyApp: true)
    }

    private func present(mode: PaletteMode, state: AppState, fromAnyApp: Bool) {
        if isVisible, presentedFromAnyApp != fromAnyApp { hide() }
        presentedFromAnyApp = fromAnyApp
        if isVisible {
            if model.mode == mode { panel?.makeKeyAndOrderFront(nil); focusField(); return }
            self.state = state
            commands = state.commands.filter(\.enabled)
            model.mode = mode
            refreshItems()
            return
        }
        self.state = state
        model.state = state
        model.vault = state.vault
        host = fromAnyApp ? nil : (state.hostWindow ?? NSApp.mainWindow)
        presentationScreen = fromAnyApp ? (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main) : nil
        commands = state.commands.filter(\.enabled)
        statusSubscription = state.indexing.$status.sink { [weak self] status in
            guard let self else { return }
            let completed = self.wasIndexing && status == nil
            self.wasIndexing = status != nil
            self.model.status = Self.statusLine(status)
            self.layout()
            if completed, self.isVisible { self.refreshItems() }
        }
        catalogSubscription = state.filesChanged.debounce(for: .milliseconds(800), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self, self.isVisible, self.model.items.isEmpty, !self.model.searching else { return }
            self.refreshItems()
        }
        let panel = self.panel ?? makePanel()
        panel.hidesOnDeactivate = !fromAnyApp
        panel.collectionBehavior = fromAnyApp
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            : [.fullScreenAuxiliary, .transient, .ignoresCycle]
        generation += 1
        isVisible = true
        model.mode = mode
        refreshItems()
        layout()

        panel.alphaValue = 0
        if let host, panel.parent !== host {
            panel.parent?.removeChildWindow(panel)
            host.addChildWindow(panel, ordered: .above)
        } else if host == nil {
            panel.parent?.removeChildWindow(panel)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        focusAttempts = 0
        focusField()
        installMonitors()
        PanelMotion.arrive(panel)
    }

    func showResult(_ result: UnifiedSearchResult, query: String, state: AppState) {
        requestedResult = result
        showQuery(query, state: state)
    }

    func showQuery(_ query: String, state: AppState) {
        model.query = query
        show(mode: .search, state: state)
        refreshItems()
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        model.submitPending = false
        generation += 1
        let gen = generation
        searchTask?.cancel()
        searchTask = nil
        semanticTask?.cancel()
        rankTask?.cancel()
        statusSubscription = nil
        catalogSubscription = nil
        removeMonitors()
        // Hand key status back only if we still hold it; another panel may have taken it.
        if panel.isKeyWindow, let host, host.isVisible { host.makeKey() }
        if NSApp.isActive {
            PanelMotion.leave(panel)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Motion.fastSeconds
                ctx.timingFunction = Theme.Motion.curve
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.orderOut(panel)
                }
            })
        } else {
            orderOut(panel)
        }
        // In Ask mode the question field claims focus itself; so do the folder columns when
        // the palette just showed a folder.
        if host?.isKeyWindow == true, state?.mode != .ask, state?.browser.focusPending != true { state?.focusSidebar?() }
    }

    private func orderOut(_ panel: PalettePanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onCommandReturn = { [weak self] in self?.model.runHighlighted(externally: true) }
        panel.onJump = { [weak self] toEnd in self?.model.jumpHighlight(toEnd: toEnd) }
        let hosting = NSHostingView(rootView: PaletteView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// The field takes focus with its text selected, so typing replaces it. SwiftUI builds the
    /// field lazily, so retry on the next run loop turns until it exists.
    private func focusField() {
        guard isVisible, let panel else { return }
        if let field = model.field, field.window === panel {
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            return
        }
        guard focusAttempts < 10 else { return }
        focusAttempts += 1
        DispatchQueue.main.async { [weak self] in self?.focusField() }
    }

    // MARK: Geometry

    /// 560pt wide, centred over the host, top edge at 18% of the host's content height. The
    /// top stays put while the panel grows with its rows, capped at 60% of the host height.
    private func layout() {
        guard isVisible, let panel else { return }
        let area = hostArea()
        let height = min(540, max(280, area.height - 120))
        let width = min(860, max(560, area.width - 80))
        // Spotlight's place: the top edge a little below the title bar, not dead centre.
        let top = area.maxY - min(area.height * 0.14, max(40, area.height - height - 20))
        let frame = NSRect(x: (area.midX - width / 2).rounded(), y: (top - height).rounded(),
                           width: width, height: height)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func hostArea() -> NSRect {
        if let host { return host.contentRect(forFrameRect: host.frame) }
        return (presentationScreen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 760)
    }

    // MARK: Dismissal

    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, event.window !== self.panel else { return }
                self.hide()
            }
            return event
        }
        let center = NotificationCenter.default
        if let host {
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        hide()
    }

    // MARK: Content

    /// Rebuilds the file table when the vault's file list changed since the last build. Big
    /// lists build off the main thread; the palette ranks against the old table meanwhile.
    private func refreshTable(state: AppState) {
        guard tableVersion != state.filesVersion else { return }
        let version = state.filesVersion
        let files = state.files
        tableTask?.cancel()
        if files.count < Self.asyncTableThreshold {
            tableVersion = version
            tableFiles = files
            table = Fuzzy.FileTable(paths: files.map(\.relativePath))
            return
        }
        tableTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { Fuzzy.FileTable(paths: files.map(\.relativePath)) }.value
            guard !Task.isCancelled, let self else { return }
            self.tableVersion = version
            self.tableFiles = files
            self.table = built
            if self.isVisible, self.model.mode == .commands, !self.model.query.isEmpty { self.refreshItems() }
        }
    }

    /// `Checking every file for changes  412,000 of 876,700  3,100/s  about 2m left  38 changed`,
    /// or nil when no indexing pass runs.
    static func statusLine(_ status: VaultSession.IndexStatus?) -> String? {
        guard let status else { return nil }
        return [status.headline, status.detail].compactMap { $0 }.joined(separator: "  ")
    }

    private func refreshItems() {
        searchTask?.cancel(); semanticTask?.cancel()
        guard let state else { model.setItems([]); return }
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        model.notice = nil
        model.filters = UnifiedSearchQuery(raw: query).summary
        if query.hasPrefix(">") || state.vault == nil {
            model.searching = false
            let commandQuery = Fuzzy.Query(query.hasPrefix(">") ? String(query.dropFirst()) : query)
            let ranked = commands.compactMap { command -> (Int, PaletteCommand)? in
                if commandQuery.isEmpty { return (0, command) }
                return Fuzzy.score(commandQuery, command.title).map { ($0, command) }
            }.sorted { $0.0 > $1.0 }
            model.setItems(ranked.map { .command($0.1) })
            return
        }
        model.searching = true
        // Keep the last results up, dimmed, until the new ones land: a list that blanks on
        // every keystroke reads as flicker. Commands never linger into a search.
        if model.items.contains(where: { if case .command = $0 { return true } else { return false } }) { model.setItems([]) }
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounce)
                let response = try await state.unifiedSearch(query)
                guard !Task.isCancelled, let self, self.isVisible, self.model.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.model.notice = response.notice
                self.model.searching = false
                var results = response.results
                if let requested = self.requestedResult, !results.contains(where: { $0.id == requested.id }) { results.insert(requested, at: 0) }
                self.model.setItems(PaletteItem.merged(results, response.thoughts))
                if let requested = self.requestedResult, let index = results.firstIndex(where: { $0.id == requested.id }) { self.model.select(index) }
                self.requestedResult = nil
                // ↩ pressed before these landed: decide now, on what it was asking for.
                if self.model.submitPending {
                    self.model.submitPending = false
                    self.model.submit()
                    if !self.isVisible { return }
                }
                // Meaning-based matches arrive later; the fast results remain usable and a
                // keyboard/mouse selection is preserved if additional evidence arrives.
                if !UnifiedSearchQuery(raw: query).text.isEmpty {
                    self.semanticTask = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: 550_000_000)
                            let enhanced = try await state.unifiedSearch(query, includeSemantic: true)
                            guard !Task.isCancelled, let self, self.isVisible, self.model.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                            self.model.notice = enhanced.notice
                            self.model.setItems(PaletteItem.merged(enhanced.results, enhanced.thoughts), preservingSelection: true)
                        } catch { /* Lexical results and their errors remain authoritative. */ }
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.model.searching = false
                self.model.submitPending = false
                self.model.notice = "Search unavailable: " + error.localizedDescription
                self.model.setItems([])
            }
        }
    }

    /// ↩ with several files found and none picked: the palette gives way to the list of them
    /// all in the content area (SearchResultsView.swift), which keeps what was shown here.
    private func showList() {
        let query = model.query
        let seed = model.items.compactMap { item -> UnifiedSearchResult? in
            if case .result(let result) = item { return result }
            return nil
        }
        model.query = ""
        hide()
        state?.showSearchResults(query, seed: seed)
    }

    /// Enter, ⌘↩, or a click. The typed text is consumed; Esc keeps it for next time.
    private func run(_ item: PaletteItem, externally: Bool) {
        let query = model.query
        let previewHitID = model.previewHitID
        model.query = ""
        hide()
        guard let state else { return }
        switch item {
        case .result(let result):
            state.openSearchResult(result, hit: result.hits.first { $0.id == previewHitID }, query: query, externally: externally)
        case .file(let ref):
            if externally { state.openExternally(ref) } else { state.jump(to: ref, anchor: nil) }
        case .command(let command):
            NSApp.activate(ignoringOtherApps: true)
            state.hostWindow?.makeKeyAndOrderFront(nil)
            command.run()
        case .thought(let hit):
            state.recordSearch(query)
            state.revealThought(in: hit.record.file, uid: hit.record.uid, commentID: hit.record.comment.id, anchor: hit.record.comment.anchor)
        case .hit(let hit):
            if externally {
                state.openExternally(hit.file)
            } else {
                state.recordSearch(query)
                state.jump(to: hit.file, anchor: hit.anchor)
                state.sourceHighlight = query
                state.selectedCommentID = hit.commentID
                if hit.commentID != nil { state.railVisible = true }
            }
        }
    }
}

// MARK: - Model

/// One row of the palette.
enum PaletteItem: Identifiable {
    case file(FileRef)
    case command(PaletteCommand)
    case hit(SearchHit)
    case result(UnifiedSearchResult)
    /// A thought the query found (kind glyph, first line, file, date). Return shows it in the rail.
    case thought(ThoughtHit)

    /// The files, with the first few thoughts of the response after the top three so they are in view.
    static func merged(_ results: [UnifiedSearchResult], _ thoughts: [ThoughtHit]) -> [PaletteItem] {
        let files = results.map(PaletteItem.result)
        let rows = thoughts.prefix(4).map(PaletteItem.thought)
        return Array(files.prefix(3)) + rows + Array(files.dropFirst(3))
    }

    var id: String {
        switch self {
        case .file(let ref): "file:" + ref.relativePath
        case .command(let command): "command:" + command.id
        case .hit(let hit): "hit:" + hit.id
        case .result(let result): "result:" + result.id
        case .thought(let hit): "thought:" + hit.id
        }
    }

    var rowHeight: CGFloat {
        if case .result = self { return 68 }
        if case .hit = self { return 44 }
        if case .thought = self { return 32 }
        return 28
    }
}

/// What the view shows. The controller fills it; the field and rows call back through it.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var mode: PaletteMode = .commands
    @Published var query = ""
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var highlight = 0 { didSet { if highlight != oldValue { previewHitID = nil } } }
    var previewHitID: String?
    /// Bumped whenever `items` are replaced, so the list scrolls back to the top.
    @Published private(set) var version = 0
    /// One tertiary line at the foot of the panel while the vault indexes.
    @Published var status: String?
    @Published var notice: String?
    @Published var searching = false
    @Published var filters: [String] = []
    @Published var vault: Vault?
    weak var state: AppState?

    var selectedResult: UnifiedSearchResult? {
        guard items.indices.contains(highlight), case .result(let result) = items[highlight] else { return nil }
        return result
    }
    /// Files and folders among the rows; thoughts and commands aren't counted.
    var resultCount: Int { items.reduce(0) { if case .result = $1 { return $0 + 1 } else { return $0 } } }
    /// ↩ came while a search was in flight; `submit` runs again when its rows land.
    var submitPending = false
    func select(_ index: Int) { if items.indices.contains(index) { highlight = index; highlightMoved = true } }
    /// The highlight was moved by hand since the results last changed. Only then does a
    /// late, better-ranked pass (meaning, after keywords) keep it; otherwise the new best
    /// result is what Return opens.
    private var highlightMoved = false
    func showCommands() { query = ">"; queryDidChange?(); field?.window?.makeFirstResponder(field) }

    weak var field: NSTextField?
    var queryDidChange: (() -> Void)?
    var onItems: (() -> Void)?
    var onRun: ((PaletteItem, Bool) -> Void)?
    /// Shows every file found as a list (`PaletteController.showList`).
    var onList: (() -> Void)?
    var onCancel: (() -> Void)?

    func setItems(_ new: [PaletteItem], preservingSelection: Bool = false) {
        if !preservingSelection { previewHitID = nil }
        let selectedID = preservingSelection && highlightMoved && items.indices.contains(highlight) ? items[highlight].id : nil
        if selectedID == nil { highlightMoved = false }
        var seen: Set<String> = []
        items = new.filter { seen.insert($0.id).inserted }
        Log.debug("palette: \(items.prefix(5).map(\.id))\(status.map { " | " + $0 } ?? "")")
        highlight = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        version &+= 1
        onItems?()
    }

    func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlight = min(max(highlight + delta, 0), items.count - 1)
        highlightMoved = true
    }

    func jumpHighlight(toEnd: Bool) {
        guard !items.isEmpty else { return }
        highlight = toEnd ? items.count - 1 : 0
        highlightMoved = true
    }

    func runHighlighted(externally: Bool) {
        guard items.indices.contains(highlight) else { return }
        onRun?(items[highlight], externally)
    }

    /// ↩ in the field. A row picked by hand (arrows or a click), a command, or a lone file
    /// opens as it always has. Several files found and none picked: the list of them all.
    /// While the search is still running, the answer waits for its rows.
    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if highlightMoved || text.isEmpty || text.hasPrefix(">") || vault == nil {
            runHighlighted(externally: false)
            return
        }
        if searching { submitPending = true; Log.debug("palette: return waits for results"); return }
        if resultCount > 1, let onList { onList() } else { runHighlighted(externally: false) }
    }

    func run(_ item: PaletteItem) { onRun?(item, false) }
    func cancel() { onCancel?() }
}

// MARK: - Panel

/// Borderless, non-activating, floating; a child of the main window so it follows it.
final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    /// ⌘↩: open the highlighted file outside Flamingo.
    var onCommandReturn: (() -> Void)?
    /// ⌘↑ ⌘↓ (and ⌥): first or last row.
    var onJump: ((Bool) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.Size.panel, height: PaletteController.fieldHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        level = .floating
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc that reaches the window (focus left the field) still dismisses.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Catches the shortcuts the main menu would otherwise act on behind the palette: ⌘↩ is
    /// "Open in Default App" there, ⌘/⌥ arrows step the preview's pages.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (event.keyCode, modifiers) {
        case (36, [.command]), (76, [.command]):
            onCommandReturn?()
            return true
        case (126, [.command]), (126, [.option]):
            onJump?(false)
            return true
        case (125, [.command]), (125, [.option]):
            onJump?(true)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
