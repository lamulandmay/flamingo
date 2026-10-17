import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoAsk
import FlamingoExtract

/// The right sidebar's tabs: what's been thought about the open file, what it connects to,
/// its outline, and the chat.
enum InspectorTab: String, CaseIterable, Identifiable {
    case thoughts, connections, outline, chat
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .thoughts: "text.bubble"
        case .connections: "link"
        case .outline: "list.bullet.indent"
        case .chat: "sparkle"
        }
    }

    /// For tooltips, menus and VoiceOver. Never drawn.
    var title: String {
        switch self {
        case .thoughts: "Thoughts"
        case .connections: "Connections"
        case .outline: "Outline"
        case .chat: "Chat"
        }
    }
}

/// The right sidebar. Its tab icons share the title bar, like the left sidebar's; the
/// open file is the subject of every tab except Chat, which follows you everywhere.
struct Inspector: View {
    @EnvironmentObject var state: AppState
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader()
                .frame(height: topInset)
            Hairline()
            ZStack {
                // Chat stays mounted so a streaming answer and the field's text survive a
                // trip to another tab.
                ChatTab().opacity(state.inspectorTab == .chat ? 1 : 0)
                    .allowsHitTesting(state.inspectorTab == .chat)
                    .accessibilityHidden(state.inspectorTab != .chat)
                switch state.inspectorTab {
                case .thoughts: ThoughtsTab(file: state.selected)
                case .connections: ConnectionsTab(file: state.selected)
                case .outline: OutlineTab()
                case .chat: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Color.bg)
    }
}

private struct InspectorHeader: View {
    @EnvironmentObject var state: AppState
    @State private var connecting = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                IconButton(tab.symbol, help: tab.title, isOn: state.inspectorTab == tab) {
                    if tab == .chat { state.focusChat() } else { state.inspectorTab = tab }
                }
                .background(Squircle(radius: Theme.Radius.s)
                    .fill(Theme.Color.hover)
                    .opacity(state.inspectorTab == tab ? 1 : 0))
                .overlay(alignment: .topTrailing) { badge(for: tab) }
            }
            Spacer(minLength: Theme.Space.s)
            switch state.inspectorTab {
            case .thoughts:
                IconButton("square.and.pencil", help: "Leave a Thought…") { state.leaveThought() }
                    .disabled(state.selected == nil)
            case .connections:
                IconButton("dice", help: "Wander Suggestions") { state.startWander() }
                IconButton("plus", help: "Connect to…") { connecting = true }
                    .disabled(state.selected == nil)
                    .popover(isPresented: $connecting, arrowEdge: .bottom) {
                        if let file = state.selected {
                            ConnectPicker(source: file) { other in
                                connecting = false
                                state.connect(file, other)
                            }
                        }
                    }
            case .outline, .chat:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .animation(Theme.Motion.fast, value: state.inspectorTab)
    }

    /// A dot when a tab you aren't looking at has something: thoughts on this file.
    @ViewBuilder private func badge(for tab: InspectorTab) -> some View {
        if tab == .thoughts, state.inspectorTab != .thoughts, !state.comments.isEmpty {
            Circle().fill(Theme.Color.accent).frame(width: 5, height: 5).offset(x: -3, y: 3)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Thoughts

/// The open file's thoughts, oldest first, and a field at the foot for the next one,
/// left at the place you're looking at.
struct ThoughtsTab: View {
    @EnvironmentObject var state: AppState
    let file: FileRef?

    var body: some View {
        if let file {
            VStack(spacing: 0) {
                CommentsRail(
                    comments: state.comments,
                    onJump: { state.jumpToAnchor($0) },
                    onEdit: { c in state.updateComment(c, in: file) },
                    onDelete: { c in state.deleteComment(c, from: file) }
                )
                .usesSharedUndo()
                .onOpenLink { state.openLink($0) }
                .onRestore { c in state.restoreComment(c, to: file) }
                .onSaveEdit { c in try await state.saveEditedComment(c, in: file) }
                .onSaveDelete { c in try await state.saveDeletedComment(c, from: file) }
                .onSaveRestore { c in try await state.saveComment(c, to: file) }
                .focusComment(state.selectedCommentID)
                .recoveryContext(file: file, vault: state.vault)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ThoughtComposer(file: file)
            }
            .id(file)
        } else {
            Color.clear
        }
    }
}

/// Type, Return. The thought lands on the open file at the current slide, page or line.
private struct ThoughtComposer: View {
    @EnvironmentObject var state: AppState
    let file: FileRef
    @State private var draft = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var focused = false
    @State private var focusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let failure {
                Text(failure).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // Names where the thought lands, so the box reads as a place to write
                // (DESIGN.md principle 1's one exception). `[[` completes file names.
                ThoughtField(text: $draft, focused: $focused, placeholder: "Thought on " + file.name,
                             candidates: state.files, recent: recent, editable: !saving,
                             focusRequest: focusRequest, onSubmit: save,
                             onCancel: { NSApp.keyWindow?.makeFirstResponder(nil) })
                    .accessibilityLabel("New thought")
                if let anchor = state.anchor {
                    Text(anchor.displayLabel)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(Theme.Space.m)
            .background(Squircle(radius: Theme.Radius.l).fill(Theme.Color.fill))
            .focusRing(focused, radius: Theme.Radius.l)
            .contentShape(Rectangle())
            .onTapGesture { focusRequest += 1 }
        }
        .padding(Theme.Space.m)
    }

    /// Open tabs, then where you've been, newest first: what `[[` offers before you type.
    private var recent: [FileRef] {
        var seen = Set<FileRef>(), out: [FileRef] = []
        for f in state.openFiles.reversed() + state.history.entries.reversed().compactMap(\.file) where out.count < 30 {
            if f != file, seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saving else { return }
        saving = true
        failure = nil
        let comment = Comment(anchor: state.anchor, text: text)
        Task {
            do {
                try await state.saveComment(comment, to: file)
                state.celebrate(comment, on: file)
                draft = ""
            } catch {
                failure = "Not saved · " + error.localizedDescription
            }
            saving = false
            focusRequest += 1
        }
    }
}

// MARK: - Outline

/// The open file's slides, pages, sheets or headings. Click to go there; the current one
/// is lit.
struct OutlineTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.sections.isEmpty {
            Color.clear
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.sections.enumerated()), id: \.offset) { i, section in
                            OutlineRow(section: section, current: section.anchor == state.anchor) {
                                state.jumpToAnchor(section.anchor)
                            }
                            .id(i)
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: state.anchor) { scrollToCurrent(proxy) }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let i = state.sections.firstIndex(where: { $0.anchor == state.anchor }) else { return }
        withAnimation(Theme.Motion.fast) { proxy.scrollTo(i, anchor: .center) }
    }
}

private struct OutlineRow: View {
    let section: FlamingoExtract.Section
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(number)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(current ? Theme.Color.accent : Theme.Color.textTertiary)
                    .frame(minWidth: 22, alignment: .trailing)
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(current ? Theme.Color.text : Theme.Color.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .flamingoRow(selected: current)
        .help(section.anchor.displayLabel)
    }

    private var number: String {
        switch section.anchor.kind {
        case .slide, .page, .line: section.anchor.value
        case .time: section.anchor.value
        default: ""
        }
    }

    /// The section's own title, else the first words of its text, else its anchor.
    private var title: String {
        if let t = section.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let words = section.text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        if !words.isEmpty { return words }
        return section.anchor.displayLabel
    }
}

// MARK: - Chat

/// Drop a file on the chat to ask about it: it opens, and the question narrows to it.
private struct ChatTab: View {
    @EnvironmentObject var state: AppState
    @State private var scopeRequest = 0
    @State private var targeted = false

    var body: some View {
        if let engine = state.askEngine {
            ChatPanel(engine: engine) { state.jump(to: $0, anchor: $1) }
                .actionHistory(state.actionHistory)
                .selectedFile(state.selected)
                .context {
                    // The last week's opened files, newest first: "what was I working on?"
                    let since = Date().addingTimeInterval(-7 * 86_400)
                    let recent = ((try? state.trailStore?.events(since: since)) ?? [])
                        .reversed()
                        .filter { $0.kind == .opened }
                        .compactMap { e in e.file.map { AskContext.Visit(file: $0, anchor: e.anchor, at: e.at) } }
                    return AskContext(openFile: state.selected, anchor: state.anchor, folder: state.selectedFolder,
                                      recent: Array(recent.prefix(40)))
                }
                .focusRequest(state.chatFocusRequest)
                .scopeRequest(scopeRequest)
                .onOpenCitation { citation in
                    state.jump(to: citation.file, anchor: citation.anchor)
                    state.sourceHighlight = citation.excerpt ?? ""
                    state.selectedCommentID = citation.commentID
                }
                .onSaveScopedThought { comment, target in
                    let file = target ?? FileRef(relativePath: "_inbox/Chat")
                    try await state.saveComment(comment, to: file)
                }
                .overlay {
                    Squircle(radius: Theme.Radius.m)
                        .strokeBorder(Theme.Color.accent, lineWidth: 1)
                        .padding(Theme.Space.xs)
                        .opacity(targeted ? 1 : 0)
                        .animation(Theme.Motion.fast, value: targeted)
                        .allowsHitTesting(false)
                }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    Task { @MainActor in
                        guard let url = await DroppedURLs.load(providers).first,
                              let path = state.vault?.relativePath(of: url) else { return }
                        state.jump(to: FileRef(relativePath: path), anchor: nil)
                        scopeRequest += 1
                    }
                    return true
                }
        } else {
            Color.clear
        }
    }
}
