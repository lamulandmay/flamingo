import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The ask surface. Plan 09 owns.
///
/// One field; the answer streams in below it with inline citations, and the files it cites
/// sit under the answer. Earlier questions stack above the field, faded; ⌘↑ ⌘↓ recall them.
/// Without a key, the field takes the key instead.
public struct AskView: View {
    public var engine: AskEngine
    public var onOpen: (FileRef, FileAnchor?) -> Void
    public init(engine: AskEngine, onOpen: @escaping (FileRef, FileAnchor?) -> Void) { self.engine = engine; self.onOpen = onOpen }
    public var body: some View {
        AskSurface(session: AskSession.session(for: engine), onOpen: onOpen)
            .id(ObjectIdentifier(engine))
    }
}

/// One question and what came back.
struct Exchange: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var text = ""
    var sources: [Int: Citation] = [:]
    var citations: [Citation] = []
    var error: String?
    var done = false
}

/// Questions and answers for one engine. Outlives the view, so leaving Ask mode doesn't
/// lose the history or cut off an answer that is still streaming.
@MainActor
final class AskSession: ObservableObject {
    @Published var hasKey = AskEngine.hasKey
    @Published var draft = ""
    @Published private(set) var history: [Exchange] = []
    @Published private(set) var current: Exchange?
    @Published private(set) var waiting = false
    @Published var keyError: String?

    private weak var engine: AskEngine?
    private var task: Task<Void, Never>?
    private var recall: Int?
    /// The question that was waiting when the key turned out to be missing or rejected.
    private var pending: String?
    /// Where a pasted key goes. Tests swap it so they never touch the Keychain.
    var storeKey: (String) throws -> Void = { try AskEngine.setKey($0) }

    private static var sessions: [ObjectIdentifier: AskSession] = [:]

    static func session(for engine: AskEngine) -> AskSession {
        let id = ObjectIdentifier(engine)
        if let s = sessions[id], s.engine === engine { return s }
        sessions = sessions.filter { $0.value.engine != nil }
        let s = AskSession(engine: engine)
        sessions[id] = s
        return s
    }

    init(engine: AskEngine) { self.engine = engine }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let engine else { return }
        interrupt()
        let exchange = Exchange(question: question)
        current = exchange
        recall = nil
        waiting = true
        task = Task { [weak self] in
            do {
                for try await delta in engine.askStreaming(question) {
                    guard let self, self.current?.id == exchange.id else { return }
                    self.apply(delta)
                }
                self?.finish(exchange.id)
            } catch is CancellationError {
            } catch {
                self?.fail(error, in: exchange.id)
            }
        }
    }

    /// Stops the exchange in flight, if any, and files the current one into history, answered
    /// or not, so ⌘↑ can bring back a question that failed.
    private func interrupt() {
        task?.cancel()
        task = nil
        waiting = false
        if var current {
            current.done = true
            history.append(current)
        }
        current = nil
    }

    private func apply(_ delta: Delta) {
        switch delta {
        case .passages(let passages):
            for p in passages { current?.sources[p.id] = p.citation }
        case .text(let text):
            waiting = false
            current?.text += text
        case .discard:
            current?.text = ""
        case .searching:
            waiting = true
        case .answer(let answer):
            current?.text = answer.text
            current?.citations = answer.citations
            current?.done = true
        }
    }

    /// Only for the exchange that asked: a cancelled task must not touch the next one.
    private func finish(_ id: UUID) {
        guard current?.id == id else { return }
        current?.done = true
        waiting = false
    }

    private func fail(_ error: Error, in id: UUID) {
        guard current?.id == id else { return }
        waiting = false
        let ask = error as? AskError
        current?.error = ask?.errorDescription ?? error.localizedDescription
        current?.done = true
        if ask == .noKey || (ask == .keyRejected && !KeyStore.fromEnvironment) {
            pending = current?.question
            current = nil
            draft = ""
            keyError = ask == .keyRejected ? ask?.errorDescription : nil
            hasKey = false
        }
    }

    func saveKey() {
        do {
            try storeKey(draft)
            keyError = nil
            hasKey = true
            draft = pending ?? ""
            if pending != nil { pending = nil; submit() }
        } catch {
            keyError = (error as? AskError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Shows an earlier exchange again without asking.
    func show(_ exchange: Exchange) {
        guard let i = history.firstIndex(of: exchange) else { return }
        history.remove(at: i)
        interrupt()
        current = exchange
        draft = exchange.question
        recall = nil
    }

    /// ⌘↑ walks back through earlier questions, ⌘↓ forward again to an empty field.
    func recall(_ step: Int) -> Bool {
        let questions = history.map(\.question) + (current.map { [$0.question] } ?? [])
        guard !questions.isEmpty else { return false }
        var next = (recall ?? questions.count) + step
        // The field keeps the question just asked; recalling it again would change nothing.
        while recall == nil, questions.indices.contains(next), questions[next] == draft { next += step }
        if next < 0, recall == nil { return false }
        if next >= questions.count {
            guard recall != nil else { return false }
            recall = nil
            draft = ""
            return true
        }
        recall = max(0, next)
        draft = questions[recall!]
        return true
    }

    var isRecalling: Bool { recall != nil }
}

struct AskSurface: View {
    @ObservedObject var session: AskSession
    var onOpen: (FileRef, FileAnchor?) -> Void

    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?
    @State private var host = HostWindow()

    /// A comfortable reading measure.
    private let measure: CGFloat = 680
    private let visibleHistory = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if session.hasKey {
                    previousQuestions
                    questionField
                    StreamHairline(active: session.waiting)
                        .padding(.top, Theme.Space.s)
                    if let current = session.current { answer(current) }
                } else {
                    keyField
                }
            }
            .frame(maxWidth: measure, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Theme.Color.bg)
        .background(HostWindowReader(host: host))
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: session.hasKey) { focused = true }
    }

    // MARK: Pieces

    private var previousQuestions: some View {
        let shown = Array(session.history.suffix(visibleHistory))
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, exchange in
                PreviousQuestion(text: exchange.question,
                                 opacity: Theme.Opacity.dimmed + (Theme.Opacity.rest - Theme.Opacity.dimmed) * Double(i + 1) / Double(shown.count)) {
                    session.show(exchange)
                    focused = true
                }
            }
        }
        .padding(.bottom, shown.isEmpty ? 0 : Theme.Space.m)
    }

    private var questionField: some View {
        TextField("", text: $session.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.Font.title)
            .foregroundStyle(Theme.Color.text)
            .lineLimit(1...4)
            .focused($focused)
            .onSubmit { session.submit() }
            .accessibilityLabel("Question")
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SecureField("", text: $session.draft)
                .textFieldStyle(.plain)
                .font(Theme.Font.mono)
                .focused($focused)
                .onSubmit { session.saveKey() }
                .accessibilityLabel("Anthropic API key")
            Hairline()
            if let error = session.keyError { ErrorLine(text: error) }
        }
    }

    @ViewBuilder
    private func answer(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !exchange.text.isEmpty {
                AnswerText(markdown: exchange.text, streaming: !exchange.done, sources: exchange.sources) {
                    onOpen($0.file, $0.anchor)
                }
                .transition(.opacity)
            }
            if exchange.done, !exchange.citations.isEmpty {
                FlowLayout(spacing: Theme.Space.xs) {
                    ForEach(Self.files(exchange.citations), id: \.id) { citation in
                        Chip(citation.file.name, mono: false) { onOpen(citation.file, citation.anchor) }
                            .help(citation.file.relativePath)
                    }
                }
                .transition(.opacity)
            }
            if let error = exchange.error { ErrorLine(text: error) }
        }
        .padding(.top, Theme.Space.l)
        .animation(Theme.Motion.normal, value: exchange.done)
    }

    /// One chip per cited file, opening at the first place the answer cites in it.
    static func files(_ citations: [Citation]) -> [Citation] {
        var seen = Set<FileRef>()
        return citations.filter { seen.insert($0.file).inserted }
    }

    // MARK: Keys

    /// A local monitor rather than `onKeyPress`, so ⌘↑ ⌘↓ reach the field before any menu
    /// item that uses them for preview anchors.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [session, host] event in
            // Local monitors see every window's keys; only this window's field is ours.
            guard focused, session.hasKey, let window = host.window, event.window === window else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = mods == .command || mods == [.command, .numericPad, .function]
            let plain = mods.subtracting([.numericPad, .function]).isEmpty
            let free = session.draft.isEmpty || session.isRecalling
            switch event.keyCode {
            case 126 where command || (plain && free): return session.recall(-1) ? nil : event   // ↑
            case 125 where command || (plain && session.isRecalling): return session.recall(1) ? nil : event  // ↓
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Small views

/// The window this view lives in, for scoping the key monitor.
final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView { Reader(host: host) }
    func updateNSView(_ view: NSView, context: Context) { host.window = view.window }

    private final class Reader: NSView {
        let host: HostWindow
        init(host: HostWindow) { self.host = host; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}

private struct PreviousQuestion: View {
    var text: String
    var opacity: Double
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(hovering ? 1 : opacity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(Theme.Motion.fast, value: hovering)
    }
}

private struct ErrorLine: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
    }
}

/// The hairline under the field. While the question is out and nothing has come back yet,
/// it pulses in the accent color instead of showing a spinner.
private struct StreamHairline: View {
    var active: Bool

    var body: some View {
        Hairline()
            .overlay(alignment: .top) {
                if active { ProgressHairline(value: nil).transition(.opacity) }
            }
            .animation(Theme.Motion.normal, value: active)
    }
}

/// Wraps chips onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
