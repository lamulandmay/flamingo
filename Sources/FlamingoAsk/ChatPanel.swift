import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The chat, in the right sidebar beside whatever is open. Plan 09 owns.
///
/// A conversation reads top to bottom: each question in medium weight, its answer under it
/// with citations, the cited files as chips. The field sits at the foot with one chip that
/// narrows the question to the open file. Everything else (provider, model folder, key,
/// clearing) is in the field's menu. Nothing on screen explains itself.
public struct ChatPanel: View {
    public var engine: AskEngine
    public var onOpen: (FileRef, FileAnchor?) -> Void
    private var saveScopedThought: ((Comment, FileRef?) async throws -> Void)?
    private var openCitation: ((Citation) -> Void)?
    private var selected: FileRef?
    private var askContext: (() -> AskContext)?
    private var sharedHistory: ActionHistory?
    private var focusRequest = 0
    private var scopeRequest = 0

    public init(engine: AskEngine, onOpen: @escaping (FileRef, FileAnchor?) -> Void) {
        self.engine = engine; self.onOpen = onOpen
    }
    public func onSaveScopedThought(_ handler: @escaping (Comment, FileRef?) async throws -> Void) -> ChatPanel {
        var view = self; view.saveScopedThought = handler; return view
    }
    public func onOpenCitation(_ handler: @escaping (Citation) -> Void) -> ChatPanel {
        var view = self; view.openCitation = handler; return view
    }
    public func selectedFile(_ file: FileRef?) -> ChatPanel {
        var view = self; view.selected = file; return view
    }
    /// What the user has open, the folder and recent visits, read when a question is sent.
    /// Without it the chat still knows the selected file.
    public func context(_ provider: @escaping () -> AskContext) -> ChatPanel {
        var view = self; view.askContext = provider; return view
    }
    public func actionHistory(_ history: ActionHistory?) -> ChatPanel {
        var view = self; view.sharedHistory = history; return view
    }
    /// Bump to put the keys in the field.
    public func focusRequest(_ request: Int) -> ChatPanel {
        var view = self; view.focusRequest = request; return view
    }
    /// Bump to narrow the next question to the selected file (a file dropped on the chat).
    public func scopeRequest(_ request: Int) -> ChatPanel {
        var view = self; view.scopeRequest = request; return view
    }

    public var body: some View {
        ChatThread(session: AskSession.session(for: engine), onOpen: onOpen, saveScopedThought: saveScopedThought,
                   openCitation: openCitation, selected: selected, askContext: askContext, actionHistory: sharedHistory, externalFocus: focusRequest,
                   externalScope: scopeRequest)
            .id(ObjectIdentifier(engine))
    }
}

struct ChatThread: View {
    @ObservedObject var session: AskSession
    var onOpen: (FileRef, FileAnchor?) -> Void
    var saveScopedThought: ((Comment, FileRef?) async throws -> Void)?
    var openCitation: ((Citation) -> Void)?
    var selected: FileRef?
    var askContext: (() -> AskContext)?
    var actionHistory: ActionHistory?
    var externalFocus: Int
    var externalScope = 0

    @State private var provider = AskProvider.preferred
    @State private var focusRequest = 0
    @State private var host = HostWindow()
    @State private var keyMonitor: Any?
    @State private var saved: [UUID: String] = [:]

    private static let bottom = "chat.bottom"
    /// The field's radius, and how far its corner controls sit inside it.
    private static let radius = Theme.Radius.l
    private static let inset = Theme.Space.s
    private static let cornerShape = ConcentricSquircle(parentRadius: radius, padding: inset)
    /// The last outside focus request acted on, across this view coming and going.
    @MainActor private static var handledFocus = 0

    private var exchanges: [Exchange] { session.history + (session.current.map { [$0] } ?? []) }
    private var busy: Bool { session.waiting || session.current?.done == false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(exchanges) { exchange in
                            ExchangeView(exchange: exchange,
                                         isCurrent: exchange.id == session.current?.id,
                                         waiting: session.waiting && exchange.id == session.current?.id,
                                         status: exchange.id == session.current?.id ? session.status : nil,
                                         savedNote: saved[exchange.id],
                                         open: open, save: saveable(exchange) ? { save(exchange) } : nil,
                                         retry: { retry(exchange) })
                                .id(exchange.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.l)
                }
                .scrollIndicators(.automatic)
                .overlay {
                    if exchanges.isEmpty {
                        FlamingoMark()
                            .fill(Theme.Color.textTertiary)
                            .frame(width: 34, height: 52)
                            .opacity(0.35)
                            .accessibilityHidden(true)
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: session.current?.text) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: session.current?.id) { withAnimation(Theme.Motion.normal) { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            }
            composer
        }
        .background(HostWindowReader(host: host))
        .onAppear {
            session.actionHistory = actionHistory
            if selected == nil { session.currentFileOnly = false }
            installKeyMonitor()
            // ⌘4 with the sidebar closed mounts this view and asks for focus in one go; a
            // request made before we existed still counts, once.
            if externalFocus != 0, externalFocus != Self.handledFocus {
                Self.handledFocus = externalFocus
                DispatchQueue.main.async { focusRequest += 1 }
            }
        }
        .onDisappear { removeKeyMonitor(); session.persist() }
        .onChange(of: externalFocus) { Self.handledFocus = externalFocus; focusRequest += 1 }
        .onChange(of: externalScope) { session.setCurrentFileOnly(true); focusRequest += 1 }
        .onChange(of: session.hasKey) { focusRequest += 1 }
        .onChange(of: session.draft) { session.persist(debounce: true) }
        .onChange(of: selected) { if selected == nil { session.currentFileOnly = false } }
        .onReceive(NotificationCenter.default.publisher(for: AskProvider.didChange)) { _ in provider = AskProvider.preferred }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let problem = providerProblem {
                Text(problem)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = session.persistenceError ?? session.keyError {
                Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Group {
                if session.hasKey {
                    QuestionField(text: $session.draft, font: Theme.NS.body, accessibility: "Message",
                                  focusRequest: focusRequest, host: host, claimsFocus: false, maxLines: 10) { submit() }
                } else {
                    QuestionField(text: $session.keyDraft, secure: true, font: Theme.NS.mono,
                                  accessibility: "Anthropic API key", focusRequest: focusRequest, host: host,
                                  claimsFocus: false) { session.saveKey() }
                }
                }
                .padding(.horizontal, Theme.Space.m - Self.inset)
                .padding(.top, Theme.Space.m - Self.inset)
                // The chip and the send key sit in the field's bottom corners at a uniform
                // `inset`, so their corners are the field's corners offset by it.
                HStack(spacing: Theme.Space.xs) {
                    if let selected, session.hasKey { scopeChip(selected) }
                    Spacer(minLength: 0)
                    menu
                    sendButton
                }
            }
            .padding(Self.inset)
            .background(Squircle(radius: Self.radius).fill(Theme.Color.fill))
            .contentShape(Rectangle())
            .onTapGesture { focusRequest += 1 }
        }
        .padding(Theme.Space.m)
    }

    /// The open file. Lit: the question is about this file only. Dim: the whole vault.
    private func scopeChip(_ file: FileRef) -> some View {
        let on = session.currentFileOnly
        return Button { session.setCurrentFileOnly(!on) } label: {
            HStack(spacing: Theme.Space.xs) {
                FileGlyph(ext: file.ext, size: 11, selected: on)
                Text(file.name)
                    .font(Theme.Font.small)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(on ? Theme.Color.text : Theme.Color.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 22)
            .background(Self.cornerShape
                .strokeBorder(on ? Theme.Color.accent : Theme.Color.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .help(on ? "Asking about \(file.name) only" : "Ask about \(file.name) only")
        .animation(Theme.Motion.fast, value: on)
    }

    private var menu: some View {
        Menu {
            Picker("Answer With", selection: Binding(get: { provider }, set: session.setProvider)) {
                Text("Automatic").tag(AskProvider.auto)
                Text("Local Model").tag(AskProvider.llama)
                Text("Ollama").tag(AskProvider.ollama)
                Text("Claude").tag(AskProvider.claude)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Choose Model Folder…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    UserDefaults.standard.set(url.path, forKey: "FlamingoLlamaModelDir")
                    LlamaServer.shared.stop(); session.refreshReadiness()
                }
            }
            if provider == .claude || provider == .auto { Button("Anthropic API Key…") { session.enterKey() } }
            Divider()
            Button("Clear Conversation") { session.clear() }.disabled(exchanges.isEmpty && session.draft.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.Color.textSecondary)
        .fixedSize()
        .frame(width: 24, height: 20)
        .help(session.readiness)
    }

    private var sendButton: some View {
        let empty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            if busy { session.stop() } else { submit() }
        } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(busy || !empty ? Theme.Color.onAccent : Theme.Color.textTertiary)
                .frame(width: 22, height: 22)
                .background(Self.cornerShape.fill(busy || !empty ? Theme.Color.accent : Theme.Color.hover))
        }
        .buttonStyle(.press(shade: nil))
        .disabled(!busy && (empty || !session.hasKey))
        .help(busy ? "Stop" : "Send")
        .animation(Theme.Motion.fast, value: empty)
    }

    /// A short line only when nothing can answer.
    private var providerProblem: String? {
        let r = session.readiness
        if r.hasPrefix("Local model unavailable") { return "No local model · choose a model folder or Claude in the menu" }
        if r.hasSuffix("API key required") { return "Claude needs an API key" }
        return nil
    }

    // MARK: Actions

    /// Sends and clears the field; ↑ brings the question back.
    private func submit() {
        guard session.hasKey, !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submit(file: session.currentFileOnly ? selected : nil, saveTarget: selected,
                       context: askContext?() ?? AskContext(openFile: selected))
        session.draft = ""
    }

    private func open(_ citation: Citation) {
        if let openCitation { openCitation(citation) } else { onOpen(citation.file, citation.anchor) }
    }

    private func retry(_ exchange: Exchange) {
        let draft = session.draft
        session.draft = exchange.question
        session.submit(file: exchange.fileScope, saveTarget: exchange.saveTarget ?? selected)
        session.draft = draft
    }

    private func saveable(_ exchange: Exchange) -> Bool {
        saveScopedThought != nil && exchange.done && !exchange.text.isEmpty && exchange.error == nil
    }

    private func save(_ exchange: Exchange) {
        guard let saveScopedThought else { return }
        let links = exchange.citations.map { "[[" + $0.file.relativePath + ($0.anchor.map { "#" + $0.label } ?? "") + "]]" }
        let text = exchange.question + "\n\n" + exchange.text + (links.isEmpty ? "" : "\n\n" + links.joined(separator: " "))
        let comment = Comment(text: text, provenance: CommentProvenance(origin: .ai, model: exchange.model, reason: "Saved Ask answer"))
        let target = exchange.saveTarget
        saved[exchange.id] = "…"
        Task {
            do {
                try await saveScopedThought(comment, target)
                saved[exchange.id] = target?.name ?? "Inbox"
            } catch {
                saved[exchange.id] = "Not saved · " + error.localizedDescription
            }
        }
    }

    // MARK: Keys

    /// ↑ in an empty field brings back the last question, as in a shell.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [session, host] event in
            guard session.hasKey, let window = host.window, event.window === window,
                  host.field?.isEditingNow == true else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            let free = session.draft.isEmpty || session.isRecalling
            switch event.keyCode {
            case 126 where mods.isEmpty && free: return session.recall(-1) ? nil : event
            case 125 where mods.isEmpty && session.isRecalling: return session.recall(1) ? nil : event
            case 53 where mods.isEmpty && (session.waiting || session.current?.done == false): session.stop(); return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// One question and its answer.
private struct ExchangeView: View {
    let exchange: Exchange
    let isCurrent: Bool
    let waiting: Bool
    let status: String?
    let savedNote: String?
    let open: (Citation) -> Void
    let save: (() -> Void)?
    let retry: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(exchange.question)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let scope = exchange.fileScope {
                    FileGlyph(ext: scope.ext, size: 11).help("About " + scope.name)
                }
            }
            if waiting {
                ProgressHairline(value: nil).frame(maxWidth: 64)
                    .padding(.vertical, Theme.Space.xs)
            }
            if let status, exchange.text.isEmpty {
                Text(status).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
            }
            if !exchange.text.isEmpty {
                AnswerText(markdown: exchange.text, streaming: !exchange.done, sources: exchange.sources, onOpen: open)
                    .foregroundStyle(Theme.Color.text)
            }
            if exchange.done, !exchange.citations.isEmpty {
                FlowLayout(spacing: Theme.Space.xs) {
                    ForEach(AskSurface.files(exchange.citations), id: \.id) { citation in
                        CitedFile(citation: citation) { open(citation) }
                    }
                }
            }
            if let error = exchange.error {
                Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 2) {
                if let savedNote {
                    Label(savedNote, systemImage: "checkmark")
                        .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                } else if let save {
                    IconButton("text.bubble", help: "Save as Thought", action: save)
                }
                if exchange.done {
                    IconButton("doc.on.doc", help: "Copy Answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exchange.text, forType: .string)
                    }
                    IconButton("arrow.clockwise", help: "Ask Again", action: retry)
                }
                Spacer(minLength: 0)
            }
            .opacity(hovering || savedNote != nil ? 1 : 0)
            .animation(Theme.Motion.fast, value: hovering)
            .frame(height: exchange.done ? 24 : 0)
            .clipped()
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A file the answer cites: glyph and name, opening at the first place it was cited.
private struct CitedFile: View {
    let citation: Citation
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                FileGlyph(ext: citation.file.ext, size: 11)
                Text(citation.file.name).lineLimit(1).truncationMode(.middle)
            }
            .font(Theme.Font.small)
            .foregroundStyle(hovering ? Theme.Color.text : Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 20)
            .background(Squircle(radius: Theme.Radius.s).fill(Theme.Color.fill))
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .help(citation.file.relativePath + (citation.anchor.map { " · " + $0.label } ?? ""))
    }
}
