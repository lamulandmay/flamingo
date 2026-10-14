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

    private static var sessions: [ObjectIdentifier: AskSession] = [:]

    static func session(for engine: AskEngine) -> AskSession {
        let id = ObjectIdentifier(engine)
        if let s = sessions[id], s.engine === engine { return s }
        let s = AskSession(engine: engine)
        sessions[id] = s
        return s
    }

    init(engine: AskEngine) { self.engine = engine }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let engine else { return }
        task?.cancel()
        if let current { history.append(current) }
        current = Exchange(question: question)
        recall = nil
        waiting = true
        task = Task { [weak self] in
            do {
                for try await delta in engine.askStreaming(question) {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(delta)
                }
                self?.current?.done = true
            } catch is CancellationError {
            } catch {
                self?.fail(error)
            }
            self?.waiting = false
        }
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

    private func fail(_ error: Error) {
        let ask = error as? AskError
        current?.error = ask?.errorDescription ?? error.localizedDescription
        current?.done = true
        if ask == .noKey || (ask == .keyRejected && !KeyStore.fromEnvironment) {
            hasKey = false
        }
    }

    func saveKey() {
        do {
            try AskEngine.setKey(draft)
            draft = ""
            keyError = nil
            hasKey = true
        } catch {
            keyError = (error as? AskError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Shows an earlier exchange again without asking.
    func show(_ exchange: Exchange) {
        guard let i = history.firstIndex(of: exchange) else { return }
        task?.cancel()
        waiting = false
        history.remove(at: i)
        if let current { history.append(current) }
        current = exchange
        draft = exchange.question
        recall = nil
    }

    /// ⌘↑ walks back through earlier questions, ⌘↓ forward again to an empty field.
    func recall(_ step: Int) -> Bool {
        let questions = history.map(\.question) + (current.map { [$0.question] } ?? [])
        guard !questions.isEmpty else { return false }
        let next = (recall ?? questions.count) + step
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
                                 opacity: 0.35 + 0.45 * Double(i + 1) / Double(shown.count)) {
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
                        FileChip(file: citation.file) { onOpen(citation.file, citation.anchor) }
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [session] event in
            guard focused, session.hasKey else { return event }
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

private struct FileChip: View {
    var file: FileRef
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                FileGlyph(ext: file.ext, size: 11)
                Text(file.name)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Theme.Color.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Theme.Color.hairline, lineWidth: 1))
            .opacity(hovering ? 1 : 0.85)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .help(file.relativePath)
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
/// it breathes in the accent color instead of showing a spinner.
private struct StreamHairline: View {
    var active: Bool
    @State private var lit = false

    var body: some View {
        Hairline()
            .overlay(
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(height: 1)
                    .opacity(active ? (lit ? 0.9 : 0.25) : 0)
            )
            .onChange(of: active, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
                } else {
                    withAnimation(Theme.Motion.normal) { lit = false }
                }
            }
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
