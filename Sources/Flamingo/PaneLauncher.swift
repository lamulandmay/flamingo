import AppKit
import Combine
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// One row a launcher shows: a file, and why it is here (nothing, for files picked by recency).
struct LauncherRow: Identifiable, Equatable {
    var file: FileRef
    var reasons: [ConnectionReason] = []
    var phrases: [String] = []
    var id: String { file.relativePath }
}

/// What every empty pane offers. Picks come from what is already on screen; they refresh only when
/// the layout, a pane's file or the connections change, and the old list stays up until the new
/// one is ready, so nothing jumps under the pointer.
@MainActor
final class PaneLauncherModel: ObservableObject {
    @Published private(set) var picks: [DocumentPaneID: [LauncherRow]] = [:]
    let tables = FileTableCache()
    private weak var state: AppState?
    private var pendingRefresh: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var signature = ""
    private var states: [DocumentPaneID: LauncherState] = [:]

    func attach(_ state: AppState) {
        self.state = state
        observe()
    }

    /// Watches what `refresh` keys on (which panes show, their files, the active one,
    /// connections) and refreshes 150 ms after the last change. Re-armed after each change.
    private func observe() {
        guard let state else { return }
        withObservationTracking {
            _ = state.vault; _ = state.activePaneID; _ = state.connectionsRevision
            for id in state.tiling.arrangement.visible { _ = state.pane(id).file }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.pendingRefresh?.cancel()
                self.pendingRefresh = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        }
    }

    func launcherState(for id: DocumentPaneID) -> LauncherState {
        if let existing = states[id] { return existing }
        let made = LauncherState(pane: id, model: self)
        states[id] = made
        return made
    }

    private func refresh() {
        guard let state else { return }
        let visible = state.tiling.arrangement.visible
        let launchers = visible.filter { state.pane($0).file == nil }
        guard !launchers.isEmpty else {
            signature = ""; task?.cancel()
            if !picks.isEmpty { picks = [:] }
            return
        }
        var seeds: [PaneSeed] = []
        for id in visible {
            guard let file = state.pane(id).file, !seeds.contains(where: { $0.file == file }) else { continue }
            seeds.append(PaneSeed(file: file, weight: id == state.activePaneID ? PaneSeed.activeWeight : PaneSeed.otherWeight))
        }
        let sig = launchers.map(\.rawValue).joined(separator: ",") + "|" + seeds.map { $0.file.relativePath + "@\($0.weight)" }.joined(separator: ",")
            + "|\(state.connectionsRevision)"
        guard sig != signature else { return }
        signature = sig
        let exclude = Set(seeds.map(\.file))
        let recents = state.recents.items.map { (file: $0.file, score: $0.score) }
        // Show recents at once; the evidence-based list replaces it when ready.
        apply(PaneSuggestions.rank(seeds: [], evidence: [:], recents: recents, exclude: exclude, launchers: launchers.count), launchers, keepExisting: true)
        guard let session = state.session, !seeds.isEmpty else { return }
        let edges = state.graph.edges
        task?.cancel()
        task = Task { [weak self] in
            let evidence = (try? await session.paneEvidence(for: seeds.map(\.file), edges: edges)) ?? [:]
            guard !Task.isCancelled, let self, self.signature == sig else { return }
            self.apply(PaneSuggestions.rank(seeds: seeds, evidence: evidence, recents: recents, exclude: exclude, launchers: launchers.count), launchers, keepExisting: false)
        }
    }

    private func apply(_ blocks: [[PaneSuggestion]], _ launchers: [DocumentPaneID], keepExisting: Bool) {
        var next: [DocumentPaneID: [LauncherRow]] = [:]
        for (k, id) in launchers.enumerated() where k < blocks.count {
            next[id] = blocks[k].map { LauncherRow(file: $0.file, reasons: $0.reasons, phrases: $0.phrases) }
            Log.debug("launcher: picks slot=\(k + 1) \(blocks[k].prefix(4).map { $0.file.relativePath }.joined(separator: ", "))")
        }
        if next != picks { picks = next }
    }

    /// Headless QA: `launch 2 #0` opens that launcher's pick; `launch 2 q3` types into it.
    func qaLaunch(_ id: DocumentPaneID, _ text: String, _ state: AppState) {
        let launcher = launcherState(for: id)
        if text.hasPrefix("#"), let n = Int(text.dropFirst()) {
            launcher.open(at: n)
        } else {
            launcher.query = text
        }
    }
}

/// One launcher's typing: fuzzy names at once, the unified search after 120 ms, meaning-based
/// results after 550 ms with the selection kept.
@MainActor
final class LauncherState: ObservableObject {
    let pane: DocumentPaneID
    private unowned let model: PaneLauncherModel
    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published private(set) var results: [LauncherRow] = []
    @Published var selection = 0
    /// How many rows fit; set by the view.
    var capacity = 8
    private var tasks: [Task<Void, Never>] = []

    init(pane: DocumentPaneID, model: PaneLauncherModel) { self.pane = pane; self.model = model }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var searching: Bool { !trimmed.isEmpty }

    func rows(in state: AppState) -> [LauncherRow] {
        let all = searching ? results : model.picks[pane] ?? []
        return Array(all.prefix(max(1, min(8, capacity))))
    }

    func move(_ step: Int, in state: AppState) {
        let count = rows(in: state).count
        guard count > 0 else { return }
        selection = min(max(selection + step, 0), count - 1)
    }

    func open(at index: Int? = nil, in state: AppState? = nil) {
        guard let state = state ?? (NSApp.delegate as? AppDelegate)?.state else { return }
        let rows = rows(in: state)
        let i = index ?? selection
        guard rows.indices.contains(i) else { return }
        query = ""
        state.open(rows[i].file, inPane: pane)
    }

    private func queryChanged() {
        tasks.forEach { $0.cancel() }; tasks = []
        selection = 0
        let q = trimmed
        guard !q.isEmpty else { results = []; return }
        guard let state = (NSApp.delegate as? AppDelegate)?.state else { return }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let names = await self.model.tables.rank(q, in: state, limit: 8)
            guard !Task.isCancelled, self.trimmed == q else { return }
            self.results = names.map { LauncherRow(file: $0) }
            Log.debug("launcher: results phase=fuzzy q=\(q) n=\(names.count) \(names.prefix(3).map(\.relativePath).joined(separator: ", "))")
        })
        tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await self?.unified(q, state: state, semantic: false)
        })
        tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            await self?.unified(q, state: state, semantic: true)
        })
    }

    private func unified(_ q: String, state: AppState, semantic: Bool) async {
        guard !Task.isCancelled, let response = try? await state.unifiedSearch(q, includeSemantic: semantic, limit: 30),
              !Task.isCancelled, trimmed == q else { return }
        let keep = rows(in: state).indices.contains(selection) ? rows(in: state)[selection].id : nil
        let found = response.results.filter { !$0.isDirectory }.map { LauncherRow(file: $0.file) }
        guard !found.isEmpty else { return }
        results = found
        // The selection follows its file when it is still listed (and only moves when the list changed under it).
        if let keep, let at = rows(in: state).firstIndex(where: { $0.id == keep }) { selection = at } else { selection = 0 }
        Log.debug("launcher: results phase=\(semantic ? "semantic" : "unified") q=\(q) n=\(found.count) \(found.prefix(3).map(\.file.relativePath).joined(separator: ", "))")
    }
}

/// An empty pane in a tiled layout: a field with no placeholder, then the files most related to
/// what is already on screen. Return opens the highlighted one here.
struct PaneLauncher: View {
    @Environment(AppState.self) var state
    var pane: DocumentPane
    var body: some View {
        LauncherBody(pane: pane, launcher: state.launcher.launcherState(for: pane.id), model: state.launcher)
    }
}

private struct LauncherBody: View {
    @Environment(AppState.self) var state
    var pane: DocumentPane
    @ObservedObject var launcher: LauncherState
    @ObservedObject var model: PaneLauncherModel
    @State private var focused = false

    var body: some View {
        GeometryReader { proxy in
            let capacity = Int((proxy.size.height - 28 - 2 * Theme.Space.m) / Theme.Size.row)
            let rows = rows(capacity)
            VStack(spacing: 0) {
                CommandField(text: $launcher.query, label: "Find a file", fontSize: 13, autofocus: false, onCreate: { field in
                    pane.requestFocus = { [weak field] in field?.window?.makeFirstResponder(field) }
                }) { command($0) }
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 28)
                    .background(Squircle(radius: Theme.Radius.m - 2).fill(Theme.Color.fill))
                    .focusRing(focused, radius: Theme.Radius.m - 2)
                    .padding(Theme.Space.m)
                    .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidBeginEditingNotification)) { _ in focused = true }
                    .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in focused = false }
                Hairline()
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        launcherRow(row, selected: i == launcher.selection && state.activePaneID == pane.id, folder: proxy.size.width >= 300, reasons: proxy.size.width >= 340)
                            .pressFeedback(shade: Theme.Radius.s)
                            .onTapGesture { launcher.open(at: i, in: state) }
                    }
                }
                .padding(.horizontal, Theme.Space.xs).padding(.top, Theme.Space.xs)
                Spacer(minLength: 0)
            }
            .onChange(of: capacity) { _, new in launcher.capacity = new }
            .onAppear { launcher.capacity = capacity }
        }
        .background(PaneActivationView(pane: pane))
    }

    private func rows(_ capacity: Int) -> [LauncherRow] {
        launcher.capacity = capacity
        return launcher.rows(in: state)
    }

    private func launcherRow(_ row: LauncherRow, selected: Bool, folder: Bool, reasons: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            FileGlyph(ext: row.file.ext)
            Text(row.file.name).font(Theme.Font.body).foregroundStyle(Theme.Color.text).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if folder {
                Text(row.file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: Theme.Space.xs)
            ForEach(Array((reasons ? row.reasons : []).enumerated()), id: \.offset) { i, reason in
                Image(systemName: reason.symbol).font(.system(size: Theme.Size.iconSmall - 2))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .help(row.phrases.indices.contains(i) ? row.phrases[i] : "")
            }
        }
        .flamingoRow(selected: selected)
    }

    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): launcher.move(1, in: state); return true
        case #selector(NSResponder.moveUp(_:)): launcher.move(-1, in: state); return true
        case #selector(NSResponder.insertNewline(_:)): launcher.open(in: state); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if launcher.query.isEmpty { state.leaveLauncher(pane.id) } else { launcher.query = "" }
            return true
        default: return false
        }
    }
}
