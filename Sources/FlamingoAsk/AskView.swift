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
    private var saveThought: ((Comment) async throws -> Void)?
    private var saveScopedThought: ((Comment, FileRef?) async throws -> Void)?
    private var openCitation: ((Citation) -> Void)?
    private var selected: FileRef?
    private var sharedHistory: ActionHistory?
    public init(engine: AskEngine, onOpen: @escaping (FileRef, FileAnchor?) -> Void) { self.engine = engine; self.onOpen = onOpen }
    public func onSaveThought(_ handler: @escaping (Comment) async throws -> Void) -> AskView {
        var view = self; view.saveThought = handler; return view
    }
    public func onSaveScopedThought(_ handler: @escaping (Comment, FileRef?) async throws -> Void) -> AskView {
        var view = self; view.saveScopedThought = handler; return view
    }
    public func onOpenCitation(_ handler: @escaping (Citation) -> Void) -> AskView {
        var view = self; view.openCitation = handler; return view
    }
    public func selectedFile(_ file: FileRef?) -> AskView {
        var view = self; view.selected = file; return view
    }
    public func actionHistory(_ history: ActionHistory?) -> AskView {
        var view = self; view.sharedHistory = history; return view
    }
    public var body: some View {
        AskSurface(session: AskSession.session(for: engine), onOpen: onOpen, saveThought: saveThought,
                   saveScopedThought: saveScopedThought, openCitation: openCitation, selected: selected,
                   actionHistory: sharedHistory)
            .id(ObjectIdentifier(engine))
    }
}

/// One question and what came back.
struct Exchange: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var question: String
    var text = ""
    var sources: [Int: Citation] = [:]
    var citations: [Citation] = []
    var error: String?
    var done = false
    var fileScope: FileRef?
    var saveTarget: FileRef?
    var model: String?
}

/// Questions and answers for one engine. Outlives the view, so leaving Ask mode doesn't
/// lose the history or cut off an answer that is still streaming.
@MainActor
final class AskSession: ObservableObject {
    /// False only when Claude is the chosen provider and there's no key: then the field takes one.
    @Published var hasKey = AskSession.keyReady
    /// `loading qwen3.8-27b` while the local model loads; cleared when text arrives.
    @Published private(set) var status: String?
    @Published var draft = ""
    @Published private(set) var history: [Exchange] = []
    @Published private(set) var current: Exchange?
    @Published private(set) var waiting = false
    @Published var keyError: String?
    @Published var keyDraft = ""
    @Published var persistenceError: String?
    @Published var readiness = "Checking model…"
    @Published var coverageHint = ""
    @Published var currentFileOnly = false
    let scope: String
    private let historyURL: URL
    private var historyWritable = true
    private var persistTask: Task<Void, Never>?
    private var persistRevision = 0
    private var lastCheckpoint = Date.distantPast

    private weak var engine: AskEngine?
    private var task: Task<Void, Never>?
    private var streamRevision = 0
    private var recall: Int?
    weak var actionHistory: ActionHistory?
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

    private var observer: NSObjectProtocol?

    static var keyReady: Bool { AskProvider.preferred != .claude || AskEngine.claudeReady }

    init(engine: AskEngine) {
        self.engine = engine
        scope = engine.index.vault.root.path
        historyURL = engine.index.vault.stateDir.appendingPathComponent("ask-history.json")
        do {
            let stored = try AskHistoryStore.load(historyURL)
            history = stored.exchanges.map { saved in
                var saved = saved
                if !saved.done { saved.done = true; saved.error = "Interrupted when Flamingo closed; retry the question to finish." }
                return saved
            }
            if let last = history.popLast() { current = last }
            draft = stored.draft
            currentFileOnly = stored.currentFileOnly ?? false
        } catch {
            persistenceError = "Saved questions could not be read. The original history is preserved. " + error.localizedDescription
            historyWritable = false
        }
        observer = NotificationCenter.default.addObserver(forName: AskProvider.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasKey = AskSession.keyReady; self?.refreshReadiness() }
        }
        refreshReadiness()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func submit(file: FileRef? = nil, saveTarget: FileRef? = nil, context: AskContext = .empty) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let engine else { return }
        let before = snapshot()
        interrupt()
        let revision = streamRevision
        var exchange = Exchange(question: question)
        exchange.fileScope = file
        exchange.saveTarget = file ?? saveTarget
        current = exchange
        recall = nil
        waiting = true
        persist()
        recordChange("Ask Question", before: before)
        let prior = history.filter { $0.done && $0.error == nil && $0.fileScope == file }.suffix(4).map { ConversationTurn(question: $0.question, answer: $0.text) }
        task = Task { [weak self] in
            guard !Task.isCancelled, self?.streamRevision == revision else { return }
            do {
                for try await delta in engine.askStreaming(question, history: prior, file: file, context: context) {
                    guard let self, self.streamRevision == revision, self.current?.id == exchange.id else { return }
                    self.apply(delta)
                }
                guard self?.streamRevision == revision else { return }
                self?.finish(exchange.id)
            } catch is CancellationError {
            } catch {
                guard self?.streamRevision == revision else { return }
                self?.fail(error, in: exchange.id)
            }
        }
    }

    /// Stops the exchange in flight, if any, and files the current one into history, answered
    /// or not, so ⌘↑ can bring back a question that failed.
    private func interrupt() {
        flushText()
        streamRevision += 1
        task?.cancel()
        task = nil
        waiting = false
        status = nil
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
        case .status(let line):
            status = line
        case .text(let text):
            waiting = false
            status = nil
            // Tokens arrive far faster than anyone reads; re-rendering the whole answer per
            // token is quadratic. Gather them and show at most ~30 updates a second.
            pendingText += text
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in self?.flushText() }
            }
        case .discard:
            pendingText = ""
            current?.text = ""
        case .searching:
            waiting = true
        case .answer(let answer):
            pendingText = ""
            current?.text = answer.text
            current?.citations = answer.citations
            current?.sources = answer.sources
            current?.model = answer.model
            current?.done = true
        }
    }

    private var pendingText = ""
    private var flushScheduled = false

    private func flushText() {
        flushScheduled = false
        guard !pendingText.isEmpty else { return }
        current?.text += pendingText
        pendingText = ""
        if Date().timeIntervalSince(lastCheckpoint) > 2 { lastCheckpoint = Date(); persist() }
    }

    /// Only for the exchange that asked: a cancelled task must not touch the next one.
    private func finish(_ id: UUID) {
        guard current?.id == id else { return }
        flushText()
        current?.done = true
        waiting = false
        status = nil
        refreshReadiness()
        persist()
    }

    private func fail(_ error: Error, in id: UUID) {
        guard current?.id == id else { return }
        flushText()
        waiting = false
        status = nil
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
        persist()
    }

    func saveKey() {
        do {
            try storeKey(keyDraft)
            keyDraft = ""
            keyError = nil
            hasKey = true
            refreshReadiness()
            draft = pending ?? ""
            if pending != nil { pending = nil; submit() }
        } catch {
            keyError = (error as? AskError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Shows an earlier exchange again without asking.
    func show(_ exchange: Exchange) {
        guard let i = history.firstIndex(of: exchange) else { return }
        let before = snapshot()
        history.remove(at: i)
        interrupt()
        current = exchange
        draft = exchange.question
        recall = nil
        persist()
        recordChange("Show Previous Answer", before: before)
    }

    /// ⌘↑ walks back through earlier questions, ⌘↓ forward again to an empty field.
    func recall(_ step: Int) -> Bool {
        let previousDraft = draft, previousRecall = recall
        defer { recordRecallChange(draft: previousDraft, recall: previousRecall) }
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

    func stop() {
        guard waiting || current?.done == false else { return }
        flushText()
        let before = snapshot()
        streamRevision += 1
        task?.cancel(); task = nil
        waiting = false; status = nil
        current?.done = true
        current?.error = "Stopped; partial answer retained"
        persist()
        recordChange("Stop Answer", before: before)
    }

    /// Empties the conversation. Undoable like every other change to it.
    func clear() {
        let before = snapshot()
        pendingText = ""
        streamRevision += 1
        task?.cancel(); task = nil
        waiting = false; status = nil
        history = []
        current = nil
        draft = ""
        recall = nil
        persist()
        recordChange("Clear Conversation", before: before)
    }

    func setCurrentFileOnly(_ enabled: Bool) {
        guard enabled != currentFileOnly else { return }
        let previous = currentFileOnly
        currentFileOnly = enabled
        persist()
        actionHistory?.register(name: "Change Ask Scope", undo: { [weak self] in
            self?.currentFileOnly = previous; self?.persist()
        }, redo: { [weak self] in
            self?.currentFileOnly = enabled; self?.persist()
        })
    }

    func setProvider(_ provider: AskProvider) {
        let previous = AskProvider.preferred
        guard previous != provider else { return }
        AskProvider.preferred = provider
        actionHistory?.register(name: "Change Answer Provider", undo: {
            AskProvider.preferred = previous
        }, redo: {
            AskProvider.preferred = provider
        })
    }

    private struct Snapshot {
        var history: [Exchange]
        var current: Exchange?
        var draft: String
        var recall: Int?
        var pending: String?
    }

    private final class Change {
        var before: Snapshot
        var after: Snapshot
        init(before: Snapshot, after: Snapshot) { self.before = before; self.after = after }
    }

    private func snapshot() -> Snapshot {
        Snapshot(history: history, current: current, draft: draft, recall: recall, pending: pending)
    }

    /// Restoring a previous state never sends a question again. Retain any partial answer,
    /// and invalidate the old stream even when the restored exchange has the same ID.
    private func restore(_ snapshot: Snapshot) {
        pendingText = ""
        streamRevision += 1
        task?.cancel(); task = nil
        waiting = false; status = nil
        history = snapshot.history
        current = snapshot.current
        if current?.done == false {
            current?.done = true
            current?.error = "Request stopped; partial answer retained"
        }
        draft = snapshot.draft
        recall = snapshot.recall
        // A question removed by undo must not be silently retried after entering a key.
        pending = snapshot.pending
        persist()
    }

    private func recordChange(_ name: String, before: Snapshot) {
        guard let actionHistory else { return }
        let change = Change(before: before, after: snapshot())
        actionHistory.register(name: name, undo: { [weak self] in
            guard let self else { return }
            // Capture the newest streamed content, not only the empty exchange at submit.
            change.after = self.snapshot()
            self.restore(change.before)
        }, redo: { [weak self] in
            guard let self else { return }
            self.restore(change.after)
        })
    }

    private func recordRecallChange(draft previousDraft: String, recall previousRecall: Int?) {
        guard draft != previousDraft || recall != previousRecall else { return }
        let nextDraft = draft, nextRecall = recall
        actionHistory?.register(name: "Recall Question", undo: { [weak self] in
            self?.draft = previousDraft; self?.recall = previousRecall; self?.persist()
        }, redo: { [weak self] in
            self?.draft = nextDraft; self?.recall = nextRecall; self?.persist()
        })
        persist()
    }

    func enterKey() { pending = draft; keyDraft = ""; hasKey = false }

    func persist(debounce: Bool = false) {
        guard hasKey, historyWritable else { return }
        persistTask?.cancel()
        persistRevision += 1
        let revision = persistRevision
        let state = AskHistory(exchanges: Array((history + (current.map { [$0] } ?? [])).suffix(100)), draft: draft,
                               currentFileOnly: currentFileOnly)
        let url = historyURL
        persistTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            AskHistoryStore.enqueue(state, to: url) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.persistRevision == revision else { return }
                    self.persistenceError = error.map { "Questions are not saved: " + $0 }
                }
            }
        }
    }

    func refreshReadiness() {
        switch AskProvider.preferred {
        case .claude:
            readiness = AskEngine.hasKey ? "Claude · API key configured · retrieved passages are sent to Claude"
                : AskEngine.claudeReady ? "Claude · through Claude Code · retrieved passages are sent to Claude" : "Claude · API key required"
        case .auto where AskEngine.hasKey:
            readiness = "Automatic · retrieved passages go to Claude when online; local when offline"
        case .ollama:
            readiness = "Ollama · " + AskProvider.ollamaModel + " · requires Ollama running locally"
        default:
            if let files = try? LlamaServer.shared.files(), LlamaServer.binaries.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                readiness = "Local · " + files.0.lastPathComponent + (LlamaServer.shared.isRunning ? " · running" : " · installed; loads on first question")
            } else {
                readiness = "Local model unavailable. Choose a GGUF folder, start Ollama, or select Claude and add a key."
            }
        }
    }

    func refreshCoverage(file: FileRef?) async {
        guard let index = engine?.index else { return }
        do {
            let text = try await Task.detached {
                if let file {
                    guard let value = try index.coverage(for: file) else { return "This file has not been indexed yet. Answers can only use its indexed thoughts." }
                    if value.coverage.state == .complete { return "File content indexed. Answers use selected passages; open Sources to inspect them." }
                    return "Content coverage: " + value.coverage.state.rawValue + ". " + (value.coverage.reason ?? "Some content may be missing.")
                }
                let health = try index.health()
                return "\(health.files) indexed files · \(health.complete) fully read · \(health.partial) partial · \(health.failed + health.metadataOnly + health.unsupported) without complete readable content"
            }.value
            guard !Task.isCancelled else { return }
            coverageHint = text
        } catch { coverageHint = "Index coverage unavailable: " + error.localizedDescription }
    }

    func expand(_ citation: Citation) async throws -> String {
        guard let engine else { throw AskError.stream("Workspace is closed") }
        return try await Task.detached { try engine.sourceText(for: citation) }.value
    }
}

struct AskSurface: View {
    @ObservedObject var session: AskSession
    var onOpen: (FileRef, FileAnchor?) -> Void
    var saveThought: ((Comment) async throws -> Void)?
    var saveScopedThought: ((Comment, FileRef?) async throws -> Void)?
    var openCitation: ((Citation) -> Void)?
    var selected: FileRef?
    var actionHistory: ActionHistory?
    @State private var provider = AskProvider.preferred
    @State private var saveStatus: String?
    @State private var savingThought = false
    @State private var expandedSources: [String: String] = [:]

    @State private var focusRequest = 0
    @State private var keyMonitor: Any?
    @State private var host = HostWindow()

    /// A comfortable reading measure.
    private let measure: CGFloat = 640
    private let visibleHistory = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                setup
                if let error = session.persistenceError { ErrorLine(text: error).padding(.bottom, Theme.Space.s) }
                if session.hasKey {
                    previousQuestions
                    questionField
                    if session.current != nil || !session.history.isEmpty {
                        StreamHairline(active: session.waiting)
                            .padding(.top, Theme.Space.s)
                    }
                    if let status = session.status { ErrorLine(text: status).padding(.top, Theme.Space.s) }
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
            session.actionHistory = actionHistory
            if selected == nil { session.currentFileOnly = false }
            installKeyMonitor()
        }
        .onChange(of: actionHistory.map(ObjectIdentifier.init)) { session.actionHistory = actionHistory }
        .onDisappear { removeKeyMonitor(); session.persist() }
        .onChange(of: session.hasKey) { focusRequest += 1 }
        .onChange(of: session.draft) { session.persist(debounce: true) }
        .onChange(of: selected) { if selected == nil { session.currentFileOnly = false } }
        .onChange(of: session.currentFileOnly) { session.persist() }
        .onReceive(NotificationCenter.default.publisher(for: AskProvider.didChange)) { _ in provider = AskProvider.preferred }
        .task(id: session.currentFileOnly ? selected?.relativePath : nil) { await session.refreshCoverage(file: session.currentFileOnly ? selected : nil) }
    }

    // MARK: Pieces

    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Search scope", selection: Binding(get: { session.currentFileOnly }, set: session.setCurrentFileOnly)) {
                Text("Entire workspace").tag(false)
                if let selected { Text("Current file: " + selected.name).tag(true) }
            }.pickerStyle(.segmented)
            Text(session.currentFileOnly ? (selected?.relativePath ?? "") : "Indexed files and thoughts in " + session.scope)
                .font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
            HStack {
                Picker("Answer with", selection: Binding(get: { provider }, set: session.setProvider)) {
                    Text("Automatic").tag(AskProvider.auto)
                    Text("Local GGUF").tag(AskProvider.llama)
                    Text("Ollama").tag(AskProvider.ollama)
                    Text("Claude").tag(AskProvider.claude)
                }.pickerStyle(.menu)
                Button("Model folder…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        UserDefaults.standard.set(url.path, forKey: "FlamingoLlamaModelDir")
                        LlamaServer.shared.stop(); session.refreshReadiness()
                    }
                }
                if provider == .claude { Button("API key…") { session.enterKey() } }
                if session.waiting || session.current?.done == false { Button("Stop") { session.stop() } }
            }.font(Theme.Font.small)
            Text(session.readiness).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text(session.coverageHint).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            if session.current == nil && session.history.isEmpty && session.hasKey {
                Text("Ask about a file, decision, or connection. Answers cite retrieved evidence; inspect Sources to verify.")
                    .font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(.bottom, Theme.Space.l)
    }

    private var previousQuestions: some View {
        let shown = Array(session.history.suffix(visibleHistory))
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, exchange in
                PreviousQuestion(text: exchange.question,
                                 opacity: Theme.Opacity.dimmed + (Theme.Opacity.rest - Theme.Opacity.dimmed) * Double(i + 1) / Double(shown.count)) {
                    session.show(exchange)
                    focusRequest += 1
                }
            }
        }
        .padding(.bottom, shown.isEmpty ? 0 : Theme.Space.m)
    }

    private var questionField: some View {
        QuestionField(text: $session.draft, accessibility: "Question", focusRequest: focusRequest, host: host) {
            saveStatus = nil
            session.submit(file: session.currentFileOnly ? selected : nil, saveTarget: selected)
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Anthropic API key").font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
            QuestionField(text: $session.keyDraft, secure: true, font: Theme.NS.mono,
                          accessibility: "Anthropic API key", focusRequest: focusRequest, host: host) {
                session.saveKey()
            }
            Hairline()
            if let error = session.keyError { ErrorLine(text: error) }
        }
    }

    @ViewBuilder
    private func answer(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !exchange.text.isEmpty {
                AnswerText(markdown: exchange.text, streaming: !exchange.done, sources: exchange.sources) {
                    if let openCitation { openCitation($0) } else { onOpen($0.file, $0.anchor) }
                }
                .transition(.opacity)
            }
            if exchange.done, !exchange.sources.isEmpty {
                DisclosureGroup("Sources (\(exchange.sources.count))") {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(exchange.sources.keys.sorted(), id: \.self) { number in
                            if let citation = exchange.sources[number] {
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Button("[\(number)] " + citation.file.relativePath + (citation.anchor.map { " · " + $0.label } ?? "")) {
                                        if let openCitation { openCitation(citation) } else { onOpen(citation.file, citation.anchor) }
                                    }.buttonStyle(.plain).foregroundStyle(Theme.Color.accent)
                                    let key = exchange.id.uuidString + ":" + String(number)
                                    if let expanded = expandedSources[key] { Text(expanded).textSelection(.enabled) }
                                    else if let excerpt = citation.excerpt { Text(excerpt).textSelection(.enabled) }
                                    if expandedSources[key] == nil {
                                        Button("Read extracted section") {
                                            Task {
                                                do { expandedSources[key] = try await session.expand(citation) }
                                                catch { expandedSources[key] = error.localizedDescription }
                                            }
                                        }.buttonStyle(.plain).foregroundStyle(Theme.Color.accent)
                                    }
                                    if citation.provenance?.origin == .ai { Text("AI-generated source").foregroundStyle(Theme.Color.textSecondary) }
                                }.font(Theme.Font.small)
                            }
                        }
                    }.padding(.top, Theme.Space.s)
                }
            }
            if exchange.done, !exchange.text.isEmpty, exchange.error == nil, saveThought != nil || saveScopedThought != nil {
                Button("Save thought to " + (exchange.saveTarget?.name ?? "Inbox")) {
                    savingThought = true
                    let links = exchange.citations.map { "[[" + $0.file.relativePath + ($0.anchor.map { "#" + $0.label } ?? "") + "]]" }.joined(separator: " ")
                    let comment = Comment(text: exchange.question + "\n\n" + exchange.text + "\n\nSources: " + links,
                                          provenance: CommentProvenance(origin: .ai, model: exchange.model, reason: "Saved Ask answer"))
                    Task {
                        do {
                            if let saveScopedThought { try await saveScopedThought(comment, exchange.saveTarget) }
                            else if let saveThought { try await saveThought(comment) }
                            saveStatus = "Thought saved"
                        }
                        catch { saveStatus = "Not saved: " + error.localizedDescription }
                        savingThought = false
                    }
                }.disabled(savingThought)
            }
            if let saveStatus { ErrorLine(text: saveStatus) }
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
            guard session.hasKey, let window = host.window, event.window === window,
                  host.field?.isEditingNow == true else { return event }
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
    weak var field: NSTextField?
}

struct HostWindowReader: NSViewRepresentable {
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
            .fixedSize(horizontal: false, vertical: true)
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
