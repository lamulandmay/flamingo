import AppKit
import Combine
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// ⌘K / ⌘F: one floating panel over the main window with one text field. Command mode
/// fuzzy-matches file names and commands; search mode runs the index's full-text search.
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
    private var commands: [PaletteCommand] = []
    private var table: Fuzzy.FileTable?
    private var tableFiles: [FileRef] = []
    /// `AppState.filesVersion` the table was built from; -1 before the first build.
    private var tableVersion = -1
    private var tableTask: Task<Void, Never>?
    private var rankTask: Task<Void, Never>?
    private var statusSubscription: AnyCancellable?
    /// Above this many files, building the table and ranking it run off the main thread.
    static let asyncTableThreshold = 20_000
    private var searchTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every show and hide so a stale fade-out never orders out a re-shown panel.
    private var generation = 0
    private var focusAttempts = 0

    private override init() {
        super.init()
        model.queryDidChange = { [weak self] in self?.refreshItems() }
        model.onItems = { [weak self] in self?.layout() }
        model.onRun = { [weak self] item, externally in self?.run(item, externally: externally) }
        model.onCancel = { [weak self] in self?.hide() }
    }

    // MARK: Showing

    /// ⌘K / ⌘F. While visible, the same mode toggles the panel away; the other mode switches
    /// in place and keeps what was typed.
    func show(mode: PaletteMode, state: AppState) {
        if isVisible {
            if model.mode == mode { hide(); return }
            self.state = state
            commands = state.commands.filter(\.enabled)
            model.mode = mode
            refreshItems()
            return
        }
        self.state = state
        host = state.hostWindow ?? NSApp.mainWindow
        commands = state.commands.filter(\.enabled)
        refreshTable(state: state)
        statusSubscription = state.indexing.$status.sink { [weak self] status in
            self?.model.status = Self.statusLine(status)
            self?.layout()
        }
        let panel = self.panel ?? makePanel()
        generation += 1
        isVisible = true
        model.mode = mode
        refreshItems()
        layout()

        panel.alphaValue = 0
        if let host, panel.parent !== host {
            panel.parent?.removeChildWindow(panel)
            host.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        focusAttempts = 0
        focusField()
        installMonitors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.fastSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        generation += 1
        let gen = generation
        searchTask?.cancel()
        searchTask = nil
        rankTask?.cancel()
        statusSubscription = nil
        removeMonitors()
        // Hand key status back only if we still hold it; another panel may have taken it.
        if panel.isKeyWindow, let host, host.isVisible { host.makeKey() }
        if NSApp.isActive {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Motion.fastSeconds
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        // In Ask mode the question field claims focus itself.
        if host?.isKeyWindow == true, state?.mode != .ask { state?.focusSidebar?() }
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
        var height = Self.fieldHeight
        let items = model.items
        if !items.isEmpty {
            height += Theme.Size.hairline + Theme.Space.xs * 2 + items.reduce(0) { $0 + $1.rowHeight }
        }
        if model.status != nil { height += Theme.Size.hairline + PaletteController.statusHeight }
        height = min(height, (area.height * 0.6).rounded(.down))
        let top = area.maxY - (area.height * 0.18).rounded()
        let frame = NSRect(x: (area.midX - Theme.Size.panel / 2).rounded(), y: (top - height).rounded(),
                           width: Theme.Size.panel, height: height)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func hostArea() -> NSRect {
        if let host { return host.contentRect(forFrameRect: host.frame) }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 760)
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

    /// `Indexing  12,345 files  410/s`, or nil when no reindex runs.
    static func statusLine(_ status: VaultSession.IndexStatus?) -> String? {
        guard let status else { return nil }
        if let f = status.fraction { return "Reindexing  \(Int(f * 100))%" }
        guard status.files > 0 else { return "Indexing" }
        let n = status.files.formatted(.number)
        let rate = Int(status.perSecond.rounded()).formatted(.number)
        return "Indexing  \(n) files  \(rate)/s"
    }

    private func refreshItems() {
        guard let state else { model.setItems([]); return }
        switch model.mode {
        case .commands:
            searchTask?.cancel()
            rankTask?.cancel()
            let query = model.query
            if let table, table.count >= Self.asyncTableThreshold, !Fuzzy.Query(query).isEmpty {
                // Commands show at once; files join when the ranking lands.
                let files = tableFiles
                let q = Fuzzy.Query(query)
                let limit = Self.matchLimit
                rankTask = Task { [weak self] in
                    let matches = await Task.detached(priority: .userInitiated) { table.rank(q, limit: limit) }.value
                    guard !Task.isCancelled, let self, self.isVisible, self.model.query == query else { return }
                    self.model.setItems(self.commandItems(for: query, state: state,
                                                          files: matches.map { (files[$0.index], $0.score) }))
                }
                model.setItems(commandItems(for: query, state: state, files: []))
            } else {
                model.setItems(commandItems(for: query, state: state, files: nil))
            }
        case .search:
            scheduleSearch(state: state)
        }
    }

    /// Empty query: recent files, newest first, or the commands when nothing is recent yet
    /// (a fresh launch offers Open Vault… and the recent vaults). Otherwise the best file and
    /// command matches merged by score; ties go to the shorter name, then alphabetical.
    /// `files`: ranked matches computed elsewhere; `nil` ranks the table here.
    private func commandItems(for query: String, state: AppState, files: [(FileRef, Int)]?) -> [PaletteItem] {
        let q = Fuzzy.Query(query)
        if q.isEmpty {
            var seen: Set<FileRef> = []
            var recents: [PaletteItem] = []
            for entry in state.history.entries.reversed() {
                guard let file = entry.file else { continue }
                if file == state.selected || !seen.insert(file).inserted { continue }
                recents.append(.file(file))
                if recents.count == Self.recentLimit { break }
            }
            return recents.isEmpty ? commands.map(PaletteItem.command) : recents
        }
        var scored: [(score: Int, name: String, item: PaletteItem)] = []
        if let files {
            for (ref, score) in files { scored.append((score, ref.name, .file(ref))) }
        } else if let table {
            for match in table.rank(q, limit: Self.matchLimit) {
                let ref = tableFiles[match.index]
                scored.append((match.score, ref.name, .file(ref)))
            }
        }
        for command in commands {
            if let s = Fuzzy.score(q, command.title) {
                scored.append((s + Self.commandBoost, command.title, .command(command)))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return scored.prefix(Self.matchLimit).map(\.item)
    }

    private func scheduleSearch(state: AppState) {
        searchTask?.cancel()
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { model.setItems([]); return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let hits = await state.search(query)
            guard !Task.isCancelled, self.isVisible, self.model.mode == .search,
                  self.model.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.model.setItems(hits.prefix(Self.hitLimit).map(PaletteItem.hit))
        }
    }

    /// Enter, ⌘↩, or a click. The typed text is consumed; Esc keeps it for next time.
    private func run(_ item: PaletteItem, externally: Bool) {
        let query = model.query
        model.query = ""
        hide()
        guard let state else { return }
        switch item {
        case .file(let ref):
            if externally { state.openExternally(ref) } else { state.jump(to: ref, anchor: nil) }
        case .command(let command):
            command.run()
        case .hit(let hit):
            if externally {
                state.openExternally(hit.file)
            } else {
                state.recordSearch(query)
                state.jump(to: hit.file, anchor: hit.anchor)
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

    var id: String {
        switch self {
        case .file(let ref): "file:" + ref.relativePath
        case .command(let command): "command:" + command.id
        case .hit(let hit): "hit:" + hit.id
        }
    }

    var rowHeight: CGFloat {
        if case .hit = self { return 44 }
        return 28
    }
}

/// What the view shows. The controller fills it; the field and rows call back through it.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var mode: PaletteMode = .commands
    @Published var query = ""
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var highlight = 0
    /// Bumped whenever `items` are replaced, so the list scrolls back to the top.
    @Published private(set) var version = 0
    /// One tertiary line at the foot of the panel while the vault indexes.
    @Published var status: String?

    weak var field: NSTextField?
    var queryDidChange: (() -> Void)?
    var onItems: (() -> Void)?
    var onRun: ((PaletteItem, Bool) -> Void)?
    var onCancel: (() -> Void)?

    func setItems(_ new: [PaletteItem]) {
        var seen: Set<String> = []
        items = new.filter { seen.insert($0.id).inserted }
        Log.debug("palette: \(items.prefix(5).map(\.id))\(status.map { " | " + $0 } ?? "")")
        highlight = 0
        version &+= 1
        onItems?()
    }

    func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlight = min(max(highlight + delta, 0), items.count - 1)
    }

    func jumpHighlight(toEnd: Bool) {
        guard !items.isEmpty else { return }
        highlight = toEnd ? items.count - 1 : 0
    }

    func runHighlighted(externally: Bool) {
        guard items.indices.contains(highlight) else { return }
        onRun?(items[highlight], externally)
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
