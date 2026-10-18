import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex
import FlamingoGraph

extension ConnectionReason {
    var symbol: String {
        switch self {
        case .yours: "pin"
        case .linked: "link"
        case .version: "doc.on.doc"
        case .mentioned: "quote.opening"
        case .similar: "square.on.square"
        case .together: "clock"
        }
    }

    /// For tooltips and VoiceOver.
    func phrase(_ evidence: [ConnectionEvidence]) -> String {
        let mine = evidence.filter { $0.reason == self }
        switch self {
        case .yours: return mine.first?.note.map { "Connected by you · " + $0 } ?? "Connected by you"
        case .linked: return mine.contains(where: \.inThought) ? "Linked in a thought" : "Linked in the text"
        case .version: return mine.first?.note ?? "Version"
        case .mentioned: return "Mentioned by name"
        case .similar: return "Similar content"
        case .together:
            let n = Int(mine.map(\.weight).max() ?? 1)
            return n > 1 ? "Opened together in \(n) sessions" : "Opened together"
        }
    }
}

/// Everything the open file is connected to: what people linked or connected first, then
/// what Flamingo noticed. A suggestion is accepted or dismissed on hover; either way it
/// leaves the suggestions.
struct ConnectionsTab: View {
    @EnvironmentObject var state: AppState
    let file: FileRef?

    @State private var snapshot = FileConnectionsSnapshot()
    /// Drag the handle under the local graph; drag it to the top to put the graph away.
    @AppStorage("localGraphHeight") private var localGraphHeight = 180.0
    @State private var loadedFile: FileRef?
    @State private var failure: String?

    private struct Request: Hashable {
        let vault: URL?
        let file: FileRef?
        let revision: Int
        let graphEdges: Int
        let comments: Int
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let failure {
                    Text(failure).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                        .padding(Theme.Space.m)
                }
                if let file, loadedFile == file {
                    if !snapshot.isEmpty {
                        if localGraphHeight >= 40 {
                            LocalGraphView(graph: localGraph, center: file, revision: localRevision) { state.jump(to: $0, anchor: nil) }
                                .frame(height: localGraphHeight)
                                .background(Theme.Color.bgSunken, in: Squircle(radius: Theme.Radius.m))
                        }
                        HeightHandle(height: $localGraphHeight, range: 0...520, defaultHeight: 180)
                    }
                    ForEach(snapshot.explicit) { c in
                        ConnectionRow(connection: c, from: file, suggested: false)
                    }
                    if !snapshot.explicit.isEmpty && !snapshot.suggested.isEmpty {
                        Hairline().padding(.vertical, Theme.Space.s).padding(.horizontal, Theme.Space.s)
                    }
                    ForEach(snapshot.suggested) { c in
                        ConnectionRow(connection: c, from: file, suggested: true)
                    }
                }
            }
            .padding(Theme.Space.s)
            .animation(Theme.Motion.fast, value: snapshot)
        }
        .task(id: Request(vault: state.vault?.root, file: file, revision: state.connectionsRevision,
                          graphEdges: state.graphRevision, comments: state.comments.count)) { await reload() }
        .onChange(of: state.graphRevision, initial: true) { rebuildLocalGraph() }
    }

    /// The graph without folder structure, for the local view. Rebuilt when the graph is,
    /// not on every redraw: a home folder's graph has tens of thousands of edges.
    @State private var localGraph = Graph()
    @State private var localRevision = 0

    private func rebuildLocalGraph() {
        let g = state.graph
        localGraph = Graph(nodes: g.nodes.filter { !$0.id.hasSuffix("/") }, edges: g.edges.filter { $0.kind != .folder })
        localRevision &+= 1
    }

    @MainActor private func reload() async {
        guard let file, let session = state.session else { snapshot = FileConnectionsSnapshot(); loadedFile = nil; return }
        // Let a burst of selection changes (arrowing down the sidebar) settle first.
        try? await Task.sleep(nanoseconds: loadedFile == nil ? 0 : 80_000_000)
        guard !Task.isCancelled else { return }
        do {
            let result = try await session.fileConnections(of: file, edges: state.graph.edges)
            guard !Task.isCancelled, state.session === session, self.file == file else { return }
            snapshot = result
            loadedFile = file
            failure = nil
            // Copies and versions read files, so they arrive second and never hold up the rest.
            let family = try? await state.searchFamily(for: file)
            guard !Task.isCancelled, self.file == file, let family else { return }
            let versions = family.members.compactMap { m -> (file: FileRef, identical: Bool, note: String)? in
                switch m.kind {
                case .identicalCopy: return (m.file, true, "")
                case .possibleVersion: return (m.file, false, m.reason)
                case .relatedContent: return nil
                }
            }
            let dismissed = session.dismissed
            let keys = await Task.detached { dismissed.keys() }.value
            guard !Task.isCancelled, self.file == file else { return }
            snapshot = FileConnections.adding(versions: versions, to: snapshot, for: file, dismissed: keys)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

/// One connected file: its name, the line of evidence worth reading, and why, as glyphs.
private struct ConnectionRow: View {
    @EnvironmentObject var state: AppState
    let connection: FileConnection
    let from: FileRef
    let suggested: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            FileGlyph(ext: connection.file.ext)
                .opacity(suggested ? Theme.Opacity.rest : 1)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(connection.file.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(suggested ? Theme.Color.textSecondary : Theme.Color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if !hovering, let anchor = connection.anchor {
                        Text(anchor.displayLabel)
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(1)
                    }
                }
                if let line = headline, !line.isEmpty {
                    Text(line)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: Theme.Space.s) {
                    ForEach(connection.reasons, id: \.self) { reason in
                        Image(systemName: reason.symbol)
                            .font(.system(size: 9.5))
                            .help(reason.phrase(connection.evidence))
                            .accessibilityLabel(reason.phrase(connection.evidence))
                    }
                    if !connection.file.directory.isEmpty {
                        Text(connection.file.directory)
                            .font(Theme.Font.small)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .foregroundStyle(Theme.Color.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.s)
        .background(Squircle(radius: Self.radius)
            .fill(Theme.Color.hover).opacity(hovering ? 1 : 0))
        .overlay(alignment: .topTrailing) {
            if hovering { actions.padding(Theme.Space.xs).transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .onTapGesture { state.jump(to: connection.file, anchor: connection.anchor) }
        .onDrag {
            guard let url = state.url(for: connection.file) else { return NSItemProvider() }
            return FileHandoff.itemProvider(url: url, relativePath: connection.file.relativePath)
        }
        .contextMenu { menu }
        .help(connection.file.relativePath)
    }

    /// The written evidence, else a hand-made connection's note.
    private var headline: String? {
        guard let h = connection.headline else { return nil }
        if !h.excerpt.isEmpty { return h.excerpt }
        return h.note
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 0) {
            if suggested {
                IconButton("checkmark", help: "Connect") { state.connect(from, connection.file) }
                IconButton("xmark", help: "Dismiss") { state.dismissSuggestion(from, connection.file) }
            } else if connection.reasons.contains(.yours) {
                IconButton("rectangle.split.2x1", help: "Open Beside") { state.openBeside(connection.file, anchor: connection.anchor) }
                IconButton("xmark", help: "Remove Connection") { state.disconnect(from, connection.file) }
            } else {
                IconButton("rectangle.split.2x1", help: "Open Beside") { state.openBeside(connection.file, anchor: connection.anchor) }
            }
        }
        // Tucked into the row's corner: the row's own outline, offset inward by the padding.
        .background(ConcentricSquircle(parentRadius: Self.radius, padding: Theme.Space.xs).fill(Theme.Color.bgRaised))
    }

    private static let radius = Theme.Radius.m

    @ViewBuilder private var menu: some View {
        Button("Open") { state.jump(to: connection.file, anchor: connection.anchor) }
        Button("Open Beside") { state.openBeside(connection.file, anchor: connection.anchor) }
        if let written = connection.evidence.first(where: { $0.source != nil && $0.source != from }), let source = written.source {
            Button("Show Where It's Written") { state.jump(to: source, anchor: written.anchor) }
        }
        Divider()
        if suggested {
            Button("Connect") { state.connect(from, connection.file) }
            Button("Dismiss Suggestion") { state.dismissSuggestion(from, connection.file) }
        } else if connection.reasons.contains(.yours) {
            Button("Remove Connection") { state.disconnect(from, connection.file) }
        }
        Divider()
        Button("Copy File") { state.copyFiles([connection.file]) }
        Button("Reveal in Finder") { state.revealInFinder(connection.file) }
    }
}

// MARK: - Connect to…

/// Type part of a name, Return connects the open file to the highlighted match.
struct ConnectPicker: View {
    @EnvironmentObject var state: AppState
    let source: FileRef
    let onPick: (FileRef) -> Void
    @State private var query = ""
    @State private var matches: [FileRef] = []
    @State private var highlight = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SearchField(text: $query, focused: $focused, onSubmit: pick, onExit: { onPick(source) })
                .onKeyPress(.downArrow) { highlight = min(highlight + 1, max(0, matches.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlight = max(highlight - 1, 0); return .handled }
            ForEach(Array(matches.enumerated()), id: \.element) { i, file in
                Button { onPick(file) } label: {
                    HStack(spacing: Theme.Space.s) {
                        FileGlyph(ext: file.ext, selected: i == highlight)
                        Text(file.name).font(Theme.Font.body).foregroundStyle(Theme.Color.text).lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        Text(file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .flamingoRow(selected: i == highlight)
            }
        }
        .padding(Theme.Space.s)
        .frame(width: 340)
        .onAppear { focused = true }
        .task(id: query) { await rank() }
    }

    private func pick() {
        guard matches.indices.contains(highlight) else { return }
        onPick(matches[highlight])
    }

    private func rank() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { matches = []; return }
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        let files = state.files, me = source
        let ranked = await Task.detached(priority: .userInitiated) { () -> [FileRef] in
            var scored: [(Int, FileRef)] = []
            let query = Fuzzy.Query(q)
            for f in files where f != me {
                if let s = Fuzzy.score(query, f.name) { scored.append((s, f)) }
            }
            return scored.sorted { $0.0 > $1.0 }.prefix(8).map(\.1)
        }.value
        guard !Task.isCancelled else { return }
        matches = ranked
        highlight = 0
    }
}
