import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// Wander: Flamingo's suggestions across the whole vault, one pair at a time. → connects,
/// ← dismisses, ↓ skips, Return opens both side by side. Strong suggestions come first,
/// with a little chance mixed in so a second wander isn't the same walk.
struct WanderPair: Identifiable, Equatable {
    let a: FileRef
    let b: FileRef
    let evidence: [ConnectionEvidence]
    let strength: Double
    var id: String { DismissedConnection.key(a.relativePath, b.relativePath) }
    var reasons: [ConnectionReason] { Array(Set(evidence.map(\.reason))).sorted { $0.rawValue < $1.rawValue } }
}

@MainActor
final class WanderDeck: ObservableObject {
    @Published private(set) var pairs: [WanderPair]
    @Published private(set) var index = 0
    @Published private(set) var excerpt: String?
    @Published private(set) var decided: [String: Bool] = [:]
    private var excerptTask: Task<Void, Never>?

    init(pairs: [WanderPair]) { self.pairs = pairs }

    var current: WanderPair? { pairs.indices.contains(index) ? pairs[index] : nil }

    func advance() {
        index += 1
        excerpt = nil
    }

    func record(_ pair: WanderPair, accepted: Bool) { decided[pair.id] = accepted }

    /// The written line behind a mention, read off the main thread.
    func loadExcerpt(index store: IndexStore?) {
        excerptTask?.cancel()
        guard let pair = current, let store,
              let mention = pair.evidence.first(where: { $0.reason == .mentioned }), let source = mention.source else { return }
        let target = source == pair.a ? pair.b : pair.a
        let shown = pair.id
        excerptTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                try? store.mentionExcerpt(in: source, naming: target)
            }.value
            guard let self, !Task.isCancelled, self.current?.id == shown else { return }
            self.excerpt = found?.text
        }
    }

    /// Inferred graph edges, one entry per pair that nobody has linked or connected.
    static func build(from graph: Graph, limit: Int = 60) -> [WanderPair] {
        var explicit = Set<String>()
        var evidence: [String: (a: String, b: String, items: [ConnectionEvidence])] = [:]
        for e in graph.edges where e.source != e.target && !e.source.hasSuffix("/") && !e.target.hasSuffix("/") {
            let key = DismissedConnection.key(e.source, e.target)
            if e.kind.isExplicit { explicit.insert(key); continue }
            let reason: ConnectionReason
            switch e.kind {
            case .mention: reason = .mentioned
            case .related: reason = .similar
            case .trail: reason = .together
            default: continue
            }
            var entry = evidence[key] ?? (min(e.source, e.target), max(e.source, e.target), [])
            entry.items.append(ConnectionEvidence(reason: reason, source: reason == .mentioned ? FileRef(relativePath: e.source) : nil,
                                                  weight: e.weight))
            evidence[key] = entry
        }
        var generator = SystemRandomNumberGenerator()
        return evidence.filter { !explicit.contains($0.key) }
            .map { _, v in
                WanderPair(a: FileRef(relativePath: v.a), b: FileRef(relativePath: v.b), evidence: v.items,
                           strength: FileConnections.strength(of: v.items))
            }
            .map { ($0, $0.strength * Double.random(in: 0.7...1, using: &generator)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

extension AppState {
    func startWander() {
        let pairs = WanderDeck.build(from: graph)
        guard !pairs.isEmpty else {
            showToast(ToastMessage(text: graph.edges.isEmpty ? "The graph is still being built" : "No suggestions left"))
            if graph.edges.isEmpty { Task { await refreshGraph() } }
            return
        }
        let deck = WanderDeck(pairs: pairs)
        wander = deck
        deck.loadExcerpt(index: session?.index)
    }

    func endWander() { wander = nil }

    func wanderDecide(_ accept: Bool?) {
        guard let deck = wander, let pair = deck.current else { endWander(); return }
        if let accept {
            if accept { connect(pair.a, pair.b) } else { dismissSuggestion(pair.a, pair.b) }
            deck.record(pair, accepted: accept)
        }
        deck.advance()
        if deck.current == nil { endWander() } else { deck.loadExcerpt(index: session?.index) }
    }

    func wanderOpen() {
        guard let pair = wander?.current else { return }
        endWander()
        jump(to: pair.a, anchor: nil)
        openBeside(pair.b)
    }
}

/// The card, centred over the work surface.
struct WanderPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var deck: WanderDeck
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { state.endWander() }
            if let pair = deck.current {
                PanelChrome(width: 440) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Spacer()
                            Text("\(deck.index + 1) / \(deck.pairs.count)")
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Color.textTertiary)
                        }
                        .padding(.bottom, Theme.Space.s)
                        end(pair.a)
                        connector(pair)
                        end(pair.b)
                        Hairline().padding(.top, Theme.Space.l)
                        HStack(spacing: Theme.Space.xs) {
                            IconButton("xmark", help: "Dismiss  ←") { state.wanderDecide(false) }
                            Spacer()
                            IconButton("arrow.down", help: "Skip  ↓") { state.wanderDecide(nil) }
                            IconButton("rectangle.split.2x1", help: "Open Both  ↩") { state.wanderOpen() }
                            Spacer()
                            IconButton("checkmark", help: "Connect  →") { state.wanderDecide(true) }
                        }
                        .padding(.top, Theme.Space.s)
                    }
                    .padding(Theme.Space.l)
                }
                .id(pair.id)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fast, value: deck.index)
        .onAppear(perform: install)
        .onDisappear(perform: remove)
    }

    private func end(_ file: FileRef) -> some View {
        Button { state.jump(to: file, anchor: nil) } label: {
            HStack(spacing: Theme.Space.m) {
                FileGlyph(ext: file.ext, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(Theme.Font.bodyMedium).foregroundStyle(Theme.Color.text).lineLimit(1)
                    if !file.directory.isEmpty {
                        Text(file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.relativePath)
    }

    /// A dashed line between the two files, with why they might belong together.
    private func connector(_ pair: WanderPair) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            DashedLine()
                .stroke(Theme.Color.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 22, height: max(34, deck.excerpt == nil ? 34 : 64))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(pair.reasons, id: \.self) { reason in
                        Label(reason.phrase(pair.evidence), systemImage: reason.symbol)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                if let excerpt = deck.excerpt {
                    Text(excerpt)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(3)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, Theme.Space.s)
            Spacer(minLength: 0)
        }
        .animation(Theme.Motion.fast, value: deck.excerpt)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
            guard let state, state.wander != nil else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 123: state.wanderDecide(false); return nil      // ←
            case 124: state.wanderDecide(true); return nil       // →
            case 125, 49: state.wanderDecide(nil); return nil    // ↓, space
            case 36: state.wanderOpen(); return nil              // ↩
            case 53: state.endWander(); return nil               // esc
            default: return event
            }
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}
