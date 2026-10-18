import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign

/// Force-directed graph of the vault. Plan 06 owns.
///
/// Drag to pan, scroll or pinch to zoom, double-click empty space to fit. Drag a node to pin
/// it; ⌥-drag from one file to another connects them. Hover shows neighbors; click selects,
/// double-click opens. Arrows walk the graph, Return opens. Typing filters: `ext:pptx`,
/// `orphans`, or any part of a path. Right-click for Fit All, Reset Layout and the node list.
///
/// Lines: solid when someone linked or connected the two files, dashed when Flamingo only
/// noticed them together (a mention, similar content, the same work session), faint between
/// a folder and what it contains. The selected file's connections, with their evidence, are
/// in the inspector's Connections tab.
public struct GraphView: View {
    public var graph: Graph
    public var selected: FileRef?
    public var onSelect: (FileRef) -> Void
    public var onSelectionChange: (FileRef?) -> Void
    public var onScopeChange: (String?) -> Void
    public var onConnectionsChanged: () -> Void
    var vault: Vault?
    var history: ActionHistory?
    var firstSeen: (() async -> [String: Date])?
    var replayRequest = 0
    var celebration: GraphCelebration?
    var onCelebrationMissed: (GraphCelebration) -> Void = { _ in }
    /// When set, a new graph is noticed by this number changing, not by comparing graphs:
    /// a whole-disk graph is too big to compare on every render of the window.
    var revision: Int?
    /// Folder to scope to (relative path, "" for the root); nil shows everything. Double-click
    /// a folder node to scope into it.
    public var scope: String?

    @StateObject private var model: GraphModel
    @State private var filter = ""
    @State private var fieldShown = false
    @FocusState private var filterFocused: Bool

    public init(graph: Graph, selected: FileRef? = nil, onSelect: @escaping (FileRef) -> Void) {
        self.init(graph: graph, selected: selected, vault: nil, onSelect: onSelect)
    }

    /// Pass the vault so the layout persists in `<vault>/.flamingo/graph-layout.json`: reopening
    /// shows the graph exactly as it was left, pins included. Without it the layout lives only
    /// for the life of the process.
    public init(graph: Graph, selected: FileRef? = nil, vault: Vault?, scope: String? = nil,
                onSelectionChange: @escaping (FileRef?) -> Void = { _ in },
                onScopeChange: @escaping (String?) -> Void = { _ in },
                onConnectionsChanged: @escaping () -> Void = {},
                onSelect: @escaping (FileRef) -> Void) {
        self.graph = graph; self.selected = selected; self.vault = vault; self.scope = scope; self.onSelect = onSelect
        self.onSelectionChange = onSelectionChange; self.onScopeChange = onScopeChange
        self.onConnectionsChanged = onConnectionsChanged
        _model = StateObject(wrappedValue: GraphModel(graph: graph, vault: vault))
    }

    public func actionHistory(_ history: ActionHistory?) -> GraphView {
        var v = self; v.history = history; return v
    }

    /// Pass the owner's revision counter for `graph` (bumped whenever it is replaced).
    public func graphRevision(_ revision: Int) -> GraphView {
        var v = self; v.revision = revision; return v
    }

    /// Turns on Replay History: `dates` says when each file (by path) was first touched.
    /// Bump `request` to start a replay from outside, e.g. a palette command.
    public func replay(firstSeen dates: @escaping () async -> [String: Date], request: Int = 0) -> GraphView {
        var v = self; v.firstSeen = dates; v.replayRequest = request; return v
    }

    /// Shows `celebration` off when its `id` changes: the camera settles on the connection and
    /// draws it in. `missed` gets it back when its files aren't in this graph (another folder).
    public func celebrating(_ celebration: GraphCelebration?, missed: @escaping (GraphCelebration) -> Void = { _ in }) -> GraphView {
        var v = self; v.celebration = celebration; v.onCelebrationMissed = missed; return v
    }

    public var body: some View {
        let _ = bindCallbacks()
        ZStack(alignment: .topLeading) {
            GraphCanvas(model: model, redraw: model.redraw)
                .overlay(GraphInputLayer(target: model))
                .overlay {
                    if model.topology.count == 0 && !model.isPreparing {
                        Button { model.setScope(""); onScopeChange("") } label: {
                            Label("Whole vault", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Color.textTertiary)
                        }
                        .buttonStyle(.press(shade: nil))
                    }
                }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if fieldShown || !filter.isEmpty {
                    SearchField(text: $filter, focused: $filterFocused,
                                onSubmit: { model.openBestMatch() },
                                onExit: { filter = ""; fieldShown = false; model.focusCanvas() })
                    // Up and down walk the matches without leaving the field.
                    .onKeyPress(.upArrow) { model.moveSelection(.up); return .handled }
                    .onKeyPress(.downArrow) { model.moveSelection(.down); return .handled }
                    .frame(width: 200)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { model.occludedRect = proxy.frame(in: .named(Self.space)) }
                            .onChange(of: proxy.frame(in: .named(Self.space))) { _, r in model.occludedRect = r }
                    })
                    .onChange(of: filterFocused) { _, focused in if !focused && filter.isEmpty { fieldShown = false } }
                    .transition(.opacity)
                } else {
                    IconButton("magnifyingglass", help: "Filter") { showField() }
                        .onAppear { model.occludedRect = .null }
                }
                if let error = model.connectionError {
                    Text(error)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(maxWidth: 280, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(Theme.Space.m)
            .popover(isPresented: $model.showsNodeList, arrowEdge: .bottom) { nodeList }
            .animation(Theme.Motion.fast, value: fieldShown || !filter.isEmpty)
        }
        .coordinateSpace(name: Self.space)
        .background(Theme.Color.bgSunken)
        .onAppear {
            model.setScope(scope)
            model.select(selected)
            model.resume()
            model.refreshScope()
            model.loadConnections()
        }
        .onDisappear { model.suspend() }
        .onChange(of: GraphChange(revision: revision, graph: revision == nil ? graph : nil)) { _, _ in
            model.update(graph: graph); model.loadConnections()
        }
        .onChange(of: selected) { _, new in model.select(new) }
        .onChange(of: scope) { _, new in model.setScope(new) }
        .onChange(of: vault) { _, new in model.reset(graph: graph, vault: new) }
        .onChange(of: filter) { _, new in model.setFilter(new) }
        .onChange(of: replayRequest) { _, _ in model.onReplayRequested?() }
        .onChange(of: celebration?.id) { _, _ in
            guard let c = celebration else { return }
            model.celebrate(from: c.source, to: c.targets, level: c.level, zoom: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: GraphUndoNotification.layout)) { notification in
            guard notification.object as? String == (vault?.root.path ?? "") else { return }
            model.reloadRestoredLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: GraphUndoNotification.camera)) { notification in
            guard notification.object as? String == (vault?.root.path ?? ""),
                  let camera = notification.userInfo?["camera"] as? GraphCamera else { return }
            model.applyRestoredCamera(camera)
        }
    }

    private static let space = "graph"

    private struct GraphChange: Equatable { var revision: Int?; var graph: Graph? }

    private func showField() {
        fieldShown = true
        DispatchQueue.main.async { filterFocused = true }
    }

    private func bindCallbacks() {
        model.actionHistory = history
        model.onSelect = onSelect
        model.onSelectionChange = onSelectionChange
        model.onScopeChange = onScopeChange
        model.onConnectionsChanged = onConnectionsChanged
        model.onType = { text in
            filter += text
            fieldShown = true
            guard !filterFocused else { return }
            DispatchQueue.main.async {
                filterFocused = true
                Self.placeCaretAtEndSoon()
            }
        }
        model.onEscape = { if !filter.isEmpty { filter = "" }; fieldShown = false }
        let missed = onCelebrationMissed, id = celebration?.id ?? 0
        model.onCelebrationMissed = { source, targets, level in
            missed(GraphCelebration(id: id, source: source, targets: targets, level: level))
        }
        model.onReplayRequested = firstSeen.map { load in
            { [weak model] in Task { @MainActor in model?.startReplay(firstSeen: await load()) } }
        }
    }

    private var nodeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.topology.ids.indices.filter { model.filterMask?[$0] ?? true }, id: \.self) { i in
                    Button {
                        model.click(i)
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            if model.topology.isFolder[i] { FolderGlyph() } else { FileGlyph(ext: model.topology.exts[i]) }
                            Text(model.topology.ids[i]).font(Theme.Font.body).foregroundStyle(Theme.Color.text)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .flamingoRow(selected: model.selectionPath == model.topology.ids[i])
                    .accessibilityLabel("Select " + model.topology.ids[i])
                    .accessibilityAction(named: "Open") { model.activate(i); model.showsNodeList = false }
                    .onTapGesture(count: 2) { model.activate(i); model.showsNodeList = false }
                }
            }
            .padding(Theme.Space.s)
        }
        .frame(width: 380, height: 360)
    }
}

/// Redraws on every display frame while something moves, otherwise only when told.
struct GraphCanvas: View {
    let model: GraphModel
    @ObservedObject var redraw: GraphRedraw

    var body: some View {
        let revision = redraw.revision
        TimelineView(.animation(paused: !redraw.isAnimating)) { timeline in
            // The closure must capture something that changes. A closure over `model` alone
            // compares equal to the last one and SwiftUI skips the redraw.
            let stamp = GraphModel.DrawStamp(date: timeline.date, revision: revision)
            Canvas { context, size in model.draw(in: &context, size: size, stamp: stamp) }
        }
        .accessibilityElement()
        .accessibilityLabel("Graph")
    }
}

extension GraphView {
    /// Focusing a text field selects all of it, so the next keystroke would replace the
    /// character that started the filter. Collapse the selection once focus has landed.
    static func placeCaretAtEndSoon() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }
}
