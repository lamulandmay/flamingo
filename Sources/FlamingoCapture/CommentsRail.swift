import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign

/// Existing thoughts on the selected file, newest last. Clicking an anchored
/// comment asks the shell to jump there. Plan 03 owns.
///
/// Click selects, ↑↓ move, Return or double-click edits in place, ⌫ deletes.
/// A standalone rail shows a five-second undo line after deleting when `onRestore` is set.
/// The app can use its shared undo history instead with `usesSharedUndo()`.
public struct CommentsRail: View {
    public var comments: [Comment]
    public var onJump: (FileAnchor) -> Void
    public var onEdit: (Comment) -> Void
    public var onDelete: (Comment) -> Void
    var openLink: ((String) -> Void)?
    var restore: ((Comment) -> Void)?
    var saveEdit: ((Comment) async throws -> Void)?
    var saveDelete: ((Comment) async throws -> Void)?
    var saveRestore: ((Comment) async throws -> Void)?
    var focusedComment: UUID?
    var recoveryFile: FileRef?
    var recoveryVault: Vault?
    var sharedUndo = false
    var reply: ((Comment) -> Void)?
    var setState: ((Comment, ThoughtState, Date?) -> Void)?
    var setKind: ((Comment, ThoughtKind) -> Void)?
    var askAI: ((Comment) -> Void)?
    var work: ((Comment, RailRecipe) -> Void)?
    var copyLink: ((Comment) -> Void)?
    var pending: [String: String] = [:]
    var cancelPending: ((String) -> Void)?
    var linkFiles: [FileRef] = []
    var linkRecent: [FileRef] = []

    public func onSaveEdit(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveEdit = handler; return rail
    }
    public func onSaveDelete(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveDelete = handler; return rail
    }
    public func onSaveRestore(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveRestore = handler; return rail
    }
    /// `r`, or Reply in the menu: the shell turns its composer into a reply to this thought
    /// (`comment.replying(toUID:)` on what it saves).
    public func onReply(_ handler: @escaping (Comment) -> Void) -> CommentsRail {
        var rail = self; rail.reply = handler; return rail
    }
    /// `e` (done, or open again) and `s` (snooze until tomorrow 09:00), and their menu items.
    /// The date is when a snoozed thought returns. Save with `Comment.settingState(_:snoozeUntil:)`.
    public func onSetState(_ handler: @escaping (Comment, ThoughtState, Date?) -> Void) -> CommentsRail {
        var rail = self; rail.setState = handler; return rail
    }
    /// Kind ▸ in the menu. Save with `Comment.settingKind(_:)`, which sets `kindBy: user`.
    public func onSetKind(_ handler: @escaping (Comment, ThoughtKind) -> Void) -> CommentsRail {
        var rail = self; rail.setKind = handler; return rail
    }
    /// Ask AI in the menu: answer this thought the way `@ai` would.
    public func onAskAI(_ handler: @escaping (Comment) -> Void) -> CommentsRail {
        var rail = self; rail.askAI = handler; return rail
    }
    /// Work on This Now ▸ in the menu.
    public func onWork(_ handler: @escaping (Comment, RailRecipe) -> Void) -> CommentsRail {
        var rail = self; rail.work = handler; return rail
    }
    /// Copy Link to Thought in the menu. Without it the rail copies `[[<file>#^<uid>]]`
    /// when it knows the file (`recoveryContext`).
    public func onCopyLink(_ handler: @escaping (Comment) -> Void) -> CommentsRail {
        var rail = self; rail.copyLink = handler; return rail
    }
    /// AI answers still streaming, by the uid of the thought they answer. Each shows under its
    /// thread as grey text over a pulsing hairline. Empty text shows the hairline alone.
    public func pendingReplies(_ replies: [String: String]) -> CommentsRail {
        var rail = self; rail.pending = replies; return rail
    }
    /// Esc while an answer streams: the uid it answers.
    public func onCancelPending(_ handler: @escaping (String) -> Void) -> CommentsRail {
        var rail = self; rail.cancelPending = handler; return rail
    }
    /// Files `[[` offers while a thought is edited in place.
    public func linkCandidates(_ files: [FileRef], recent: [FileRef] = []) -> CommentsRail {
        var rail = self; rail.linkFiles = files; rail.linkRecent = recent; return rail
    }
    public func focusComment(_ id: UUID?) -> CommentsRail {
        var rail = self; rail.focusedComment = id; return rail
    }
    public func recoveryContext(file: FileRef?, vault: Vault?) -> CommentsRail {
        var rail = self; rail.recoveryFile = file; rail.recoveryVault = vault; return rail
    }

    /// The shell registers successful comment mutations in its shared undo history.
    /// This disables the rail's separate delete entry, timer and toast, while keeping
    /// native text editing undo and the existing persistence callbacks intact.
    public func usesSharedUndo(_ enabled: Bool = true) -> CommentsRail {
        var rail = self; rail.sharedUndo = enabled; return rail
    }

    public init(comments: [Comment], onJump: @escaping (FileAnchor) -> Void,
                onEdit: @escaping (Comment) -> Void = { _ in }, onDelete: @escaping (Comment) -> Void = { _ in }) {
        self.comments = comments; self.onJump = onJump; self.onEdit = onEdit; self.onDelete = onDelete
    }

    /// Called with a clicked wikilink's target: alias dropped, `#anchor` kept, e.g. `q3.pptx#slide 2`.
    public func onOpenLink(_ handler: @escaping (String) -> Void) -> CommentsRail {
        var rail = self; rail.openLink = handler; return rail
    }

    /// Re-adds a deleted comment with its original id, timestamp, anchor and text.
    /// Setting this turns on the undo line and ⌘Z after a delete.
    public func onRestore(_ handler: @escaping (Comment) -> Void) -> CommentsRail {
        var rail = self; rail.restore = handler; return rail
    }

    @State private var selection: UUID?
    @State private var editing: UUID?
    @State private var draft = ""
    /// Deleted here but possibly not yet gone from `comments`.
    @State private var hidden: Set<UUID> = []
    /// Edited here but possibly not yet updated in `comments`.
    @State private var pendingText: [UUID: String] = [:]
    @State private var deletion: RailDeletion?
    @State private var mutationError: String?
    @State private var failedEdit: Comment?
    @State private var savingIDs: Set<UUID> = []
    @FocusState private var railFocused: Bool
    @State private var editorFocused = false
    @State private var editorFocusRequest = 0
    @Environment(\.undoManager) private var undoManager

    /// Scroll target below the last row, so the bottom padding shows too.
    private static let end = "rail.end"

    private var visible: [Comment] {
        comments
            .filter { !hidden.contains($0.id) }
            .map { c in
                var c = c
                if let t = pendingText[c.id] { c.text = t }
                return c
            }
    }

    private var threads: [RailThread] { RailThreads.build(visible, pending: pending) }

    /// The rows top to bottom: each thought, then its replies.
    private var rows: [Comment] { threads.flatMap(\.comments) }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(threads) { thread in threadView(thread) }
                }
                .padding(Theme.Space.s)
                Color.clear.frame(height: 0).id(Self.end)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let mutationError {
                        Text(mutationError).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
                        if let failedEdit {
                            HStack {
                                Button("Retry") { persistEdit(failedEdit) }
                                Button("Copy unsaved edit") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(failedEdit.text, forType: .string)
                                }
                                Button("Discard edit") { discardRecovery() }
                            }
                        }
                    }
                    undoLine
                }.padding(mutationError == nil ? 0 : Theme.Space.s)
            }
            .onAppear { DispatchQueue.main.async {
                if let focusedComment { selection = focusedComment; proxy.scrollTo(focusedComment, anchor: .center) }
                else { proxy.scrollTo(Self.end, anchor: .bottom) }
            } }
            .onChange(of: focusedComment) { _, id in
                if let id { selection = id; proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: comments.map(\.id)) { old, new in commentsChanged(old: old, new: new, proxy: proxy) }
            .onChange(of: selection) { _, s in
                if let s { withAnimation(Theme.Motion.fast) { proxy.scrollTo(s) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($railFocused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(keys: RailKeys.delete) { _ in deleteSelected() }
        .onKeyPress(.return) { editSelected() }
        .onKeyPress(.escape) { escape() }
        .onKeyPress(keys: ["r"]) { press in
            guard press.modifiers.isEmpty, editing == nil, reply != nil, let c = selectedComment else { return .ignored }
            reply?(c); return .handled
        }
        .onKeyPress(keys: ["e"]) { press in
            guard press.modifiers.isEmpty, editing == nil, setState != nil, let c = selectedComment else { return .ignored }
            toggleDone(c); return .handled
        }
        .onKeyPress(keys: ["s"]) { press in
            guard press.modifiers.isEmpty, editing == nil, setState != nil, selectedComment != nil else { return .ignored }
            snoozeSelected(); return .handled
        }
        .onChange(of: comments) { pendingText = [:] }
        .onChange(of: sharedUndo) { _, enabled in if enabled { endDeletion() } }
        .onChange(of: editorFocused) { _, focused in if !focused, editing != nil { commitEdit() } }
        // Switching files replaces the rail; an edit in progress is saved, not dropped.
        .onDisappear { if editing != nil { commitEdit() } }
        .task(id: deletion?.id) { await expireDeletion() }
        .task(id: recoveryFile) { await recoverEdit() }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = RailText.linkTarget(from: url) else { return .systemAction }
            openLink?(target)
            return .handled
        })
    }

    // MARK: Rows

    private func threadView(_ t: RailThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(t.root, reply: false).id(t.root.id)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(t.replies) { c in row(c, reply: true).id(c.id) }
                ForEach(t.pending) { p in
                    PendingReplyRow(text: p.text).padding(.leading, Theme.Space.l)
                }
            }
            .overlay(alignment: .topLeading) {
                // The thread rule hangs from the root's text down past the last reply.
                if !t.replies.isEmpty || !t.pending.isEmpty {
                    VHairline().padding(.leading, Theme.Space.s).padding(.bottom, Theme.Space.xs)
                }
            }
        }
    }

    private func row(_ c: Comment, reply: Bool) -> some View {
        let isEditing = editing == c.id
        let reading = RailReading.of(c)
        return RailRow(comment: c, kind: reading.kind, due: reading.due, selected: selection == c.id,
                       active: railFocused || editorFocused,
                       editing: isEditing, draft: Binding(get: { draft }, set: {
                           draft = $0; backupEditingDraft($0)
                       }), editorFocused: $editorFocused, focusRequest: editorFocusRequest,
                       candidates: linkFiles, recent: linkRecent,
                       onJump: { a in select(c); onJump(a) }, onSubmit: commitEdit, onCancel: cancelEdit,
                       onSelect: { select(c) }, onEdit: { beginEdit(c) }, onLink: { openLink?($0) })
            .padding(.leading, reply ? Theme.Space.l : 0)
            .contextMenu {
                if self.reply != nil { Button("Reply") { self.reply?(c) } }
                if setState != nil {
                    Button(c.state == .done ? "Not Done" : "Done") { toggleDone(c) }
                    Menu("Snooze") {
                        ForEach(RailSnooze.allCases) { option in
                            Button(option.title) { setState?(c, .snoozed, option.date()) }
                        }
                    }
                }
                if setKind != nil {
                    Menu("Kind") {
                        ForEach(ThoughtKind.allCases, id: \.self) { kind in
                            Button(kind.menuTitle) { setKind?(c, kind) }
                        }
                    }
                }
                if askAI != nil { Button("Ask AI") { askAI?(c) } }
                if work != nil {
                    Menu("Work on This Now") {
                        ForEach(RailRecipe.allCases) { recipe in
                            Button(recipe.title) { work?(c, recipe) }
                        }
                    }
                }
                Button("Copy Link to Thought") { copyLinkToThought(c) }
                Divider()
                Button("Edit") { beginEdit(c) }
                Button("Delete") { delete(c) }
            }
            .disabled(savingIDs.contains(c.id))
    }

    private func toggleDone(_ c: Comment) {
        if c.state == .done { setState?(c, .open, nil) } else {
            setState?(c, .done, nil)
            Chime.tick(level: 1)
        }
    }

    private func snoozeSelected() {
        guard let c = selectedComment else { return }
        setState?(c, .snoozed, RailSnooze.tomorrow.date())
    }

    private var selectedComment: Comment? {
        guard let s = selection else { return nil }
        return rows.first { $0.id == s }
    }

    private func copyLinkToThought(_ c: Comment) {
        if let copyLink { return copyLink(c) }
        var link = "[[" + (recoveryFile?.relativePath ?? "")
        if let uid = c.uid { link += "#^" + uid }
        link += "]]"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func select(_ c: Comment) {
        selection = c.id
        if editing != c.id { railFocused = true }
    }

    private func commentsChanged(old: [UUID], new: [UUID], proxy: ScrollViewProxy) {
        let oldSet = Set(old), newSet = Set(new)
        hidden.formIntersection(newSet)
        if let s = selection, !newSet.contains(s) { selection = nil }
        if let e = editing, !newSet.contains(e) { editing = nil }
        // Anything but the delete itself landing means the undo may target the wrong file.
        if let d = deletion, newSet.subtracting(hidden) != d.expected { endDeletion() }
        if let focusedComment, newSet.contains(focusedComment), !oldSet.contains(focusedComment) {
            selection = focusedComment
            DispatchQueue.main.async { proxy.scrollTo(focusedComment, anchor: .center) }
            return
        }
        let added = newSet.subtracting(oldSet)
        if oldSet.isDisjoint(with: newSet) {
            proxy.scrollTo(Self.end, anchor: .bottom)
        } else if let last = rows.last?.id, added.contains(last)
                    || comments.max(by: { $0.timestamp < $1.timestamp }).map({ added.contains($0.id) }) == true {
            // A new thought landed. A restored older one scrolls itself into view via selection.
            withAnimation(Theme.Motion.normal) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    // MARK: Keys

    private func move(_ delta: Int) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let rows = rows
        guard !rows.isEmpty else { return .ignored }
        if let s = selection, let i = rows.firstIndex(where: { $0.id == s }) {
            selection = rows[max(0, min(rows.count - 1, i + delta))].id
        } else {
            selection = (delta > 0 ? rows.first : rows.last)?.id
        }
        return .handled
    }

    private func deleteSelected() -> KeyPress.Result {
        guard editing == nil, let s = selection, let c = rows.first(where: { $0.id == s }) else { return .ignored }
        delete(c)
        return .handled
    }

    private func editSelected() -> KeyPress.Result {
        guard editing == nil, let s = selection, let c = rows.first(where: { $0.id == s }) else { return .ignored }
        beginEdit(c)
        return .handled
    }

    private func escape() -> KeyPress.Result {
        if editing != nil { cancelEdit(); return .handled }
        // An answer streaming under the selected thought stops first; with nothing selected, any answer does.
        if let uid = selectedComment?.uid, pending[uid] != nil { cancelPending?(uid); return .handled }
        if selection != nil { selection = nil; return .handled }
        guard !pending.isEmpty, let cancelPending else { return .ignored }
        for uid in pending.keys.sorted() { cancelPending(uid) }
        return .handled
    }

    // MARK: Edit

    private func beginEdit(_ c: Comment) {
        selection = c.id
        draft = c.text
        editing = c.id
        DispatchQueue.main.async {
            editorFocusRequest += 1
            // A thought is appended to, not replaced: the cursor goes to the end.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == draft else { return }
                editor.moveToEndOfDocument(nil)
            }
        }
    }

    private func commitEdit() {
        guard let id = editing else { return }
        editing = nil
        railFocused = true
        guard let original = comments.first(where: { $0.id == id }) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { delete(original); return }
        let current = pendingText[id] ?? original.text
        guard text != current.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        var updated = original
        updated.text = text
        persistEdit(updated)
    }

    private func backupEditingDraft(_ text: String) {
        guard let id = editing, let file = recoveryFile, let vault = recoveryVault,
              var updated = comments.first(where: { $0.id == id }) else { return }
        let key = CommentEditDraftStore.recoveryKey(for: updated, file: file, in: vault)
        if text == updated.text {
            ThoughtDraftCheckpoint.enqueue(key: key, operation: {
                try CommentEditDraftStore.remove(commentID: id, for: file, in: vault)
            })
        } else {
            updated.text = text
            CommentEditDraftStore.checkpoint(updated, for: file, in: vault) { failure in
                guard let failure else { return }
                Task { @MainActor in mutationError = "Draft recovery unavailable: " + failure }
            }
        }
    }

    private func persistEdit(_ updated: Comment) {
        let id = updated.id, text = updated.text
        guard !savingIDs.contains(id) else { return }
        pendingText[id] = text
        mutationError = nil
        if let saveEdit {
            savingIDs.insert(id)
            Task { @MainActor in
                var recoveryError: String?
                var recoveryRevision: UInt64?
                if let file = recoveryFile, let vault = recoveryVault {
                    recoveryRevision = CommentEditDraftStore.checkpoint(updated, for: file, in: vault)
                    recoveryError = await ThoughtDraftCheckpoint.flushAsync(key: CommentEditDraftStore.recoveryKey(for: updated, file: file, in: vault))
                }
                do {
                    try await saveEdit(updated)
                    failedEdit = nil
                    if let file = recoveryFile, let vault = recoveryVault {
                        ThoughtDraftCheckpoint.enqueue(key: CommentEditDraftStore.recoveryKey(for: updated, file: file, in: vault),
                                                       required: false, ifCurrent: recoveryRevision, operation: {
                            try CommentEditDraftStore.removeIfMatching(updated, for: file, in: vault)
                        })
                    }
                } catch {
                    pendingText[id] = nil
                    failedEdit = updated
                    mutationError = "Edit not saved: " + error.localizedDescription + (recoveryError.map { " · Draft recovery unavailable: " + $0 } ?? "")
                    draft = text
                }
                savingIDs.remove(id)
            }
        } else {
            onEdit(updated)
            // Compatibility for callbacks that cannot acknowledge persistence.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if pendingText[id] == text { pendingText[id] = nil } }
        }
    }

    private func cancelEdit() {
        if let id = editing, let file = recoveryFile, let vault = recoveryVault,
           let comment = comments.first(where: { $0.id == id }) {
            let key = CommentEditDraftStore.recoveryKey(for: comment, file: file, in: vault)
            ThoughtDraftCheckpoint.enqueue(key: key, operation: { try CommentEditDraftStore.remove(commentID: id, for: file, in: vault) })
            if let failure = ThoughtDraftCheckpoint.flush(key: key) {
                mutationError = "Edit was not discarded: " + failure
                return
            }
        }
        editing = nil
        railFocused = true
    }

    private func recoverEdit() async {
        guard let file = recoveryFile, let vault = recoveryVault else { return }
        do {
            guard let saved = try await Task.detached(operation: { try CommentEditDraftStore.draft(for: file, in: vault) }).value else { return }
            guard !Task.isCancelled else { return }
            if comments.contains(where: { $0.text == saved.text && $0.timestamp == saved.timestamp && $0.anchor == saved.anchor }) {
                try? await Task.detached { try CommentEditDraftStore.removeIfMatching(saved, for: file, in: vault) }.value
            } else {
                failedEdit = saved
                mutationError = "Recovered an unsaved edit. Retry saving or copy it before discarding."
            }
        } catch { mutationError = "Edit recovery unavailable: " + error.localizedDescription }
    }

    private func discardRecovery() {
        guard let file = recoveryFile, let vault = recoveryVault, let failedEdit else { failedEdit = nil; mutationError = nil; return }
        let key = CommentEditDraftStore.recoveryKey(for: failedEdit, file: file, in: vault)
        ThoughtDraftCheckpoint.enqueue(key: key, operation: {
            try CommentEditDraftStore.removeIfMatching(failedEdit, for: file, in: vault)
        })
        Task {
            if let failure = await ThoughtDraftCheckpoint.flushAsync(key: key) {
                mutationError = "Could not discard recovered edit: " + failure
            } else { self.failedEdit = nil; mutationError = nil }
        }
    }

    // MARK: Delete and undo

    private func delete(_ c: Comment) {
        guard !savingIDs.contains(c.id) else { return }
        if let saveDelete {
            savingIDs.insert(c.id)
            mutationError = nil
            Task { @MainActor in
                do {
                    try await saveDelete(c)
                    completeDelete(c)
                } catch { mutationError = "Comment not deleted: " + error.localizedDescription }
                savingIDs.remove(c.id)
            }
        } else {
            onDelete(c)
            completeDelete(c)
        }
    }

    private func completeDelete(_ c: Comment) {
        // Nothing stays selected, so a second ⌫ can't take a neighbor past the one-level undo.
        if selection == c.id { selection = nil }
        if editing == c.id { editing = nil }
        hidden.insert(c.id)
        endDeletion()
        guard !sharedUndo else { return }
        guard restore != nil || saveRestore != nil else { return }
        let d = RailDeletion(comment: c, expected: Set(comments.map(\.id)).subtracting(hidden))
        if let undoManager {
            undoManager.registerUndo(withTarget: d.token) { _ in
                MainActor.assumeIsolated { undoDeletion(fromUndoManager: true) }
            }
            undoManager.setActionName("Delete")
        }
        withAnimation(Theme.Motion.fast) { deletion = d }
    }

    private func undoDeletion(fromUndoManager: Bool = false) {
        guard let d = deletion else { return }
        if let saveRestore {
            guard !savingIDs.contains(d.comment.id) else { return }
            savingIDs.insert(d.comment.id)
            Task { @MainActor in
                do {
                    try await saveRestore(d.comment)
                    completeUndo(d, fromUndoManager: fromUndoManager)
                } catch { mutationError = "Restore failed: " + error.localizedDescription }
                savingIDs.remove(d.comment.id)
            }
            return
        }
        restore?(d.comment)
        completeUndo(d, fromUndoManager: fromUndoManager)
    }

    private func completeUndo(_ d: RailDeletion, fromUndoManager: Bool) {
        if !fromUndoManager { undoManager?.removeAllActions(withTarget: d.token) }
        hidden.remove(d.comment.id)
        selection = d.comment.id
        railFocused = true
        withAnimation(Theme.Motion.fast) { deletion = nil }
    }

    private func endDeletion() {
        guard let d = deletion else { return }
        undoManager?.removeAllActions(withTarget: d.token)
        withAnimation(Theme.Motion.fast) { deletion = nil }
    }

    private func expireDeletion() async {
        guard let id = deletion?.id else { return }
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled, deletion?.id == id, let d = deletion, !savingIDs.contains(d.comment.id) { endDeletion() }
    }

    @ViewBuilder private var undoLine: some View {
        if deletion != nil {
            Toast("Deleted", action: "Undo") { undoDeletion() }
                .padding(Theme.Space.s)
                .transition(.opacity)
        }
    }
}

private enum RailKeys {
    /// ⌫ arrives as U+007F, which `KeyEquivalent.delete` (U+0008) doesn't match; ⌦ as U+F728.
    static let delete: Set<KeyEquivalent> = [.delete, .deleteForward, KeyEquivalent("\u{7F}")]
}

/// A delete that can still be undone.
private struct RailDeletion: Equatable {
    let id = UUID()
    let comment: Comment
    /// The visible ids once the delete lands. Any other change ends the undo.
    let expected: Set<UUID>
    /// Undo-manager target, so only this delete's action is removed when it expires.
    let token = RailUndoToken()
    static func == (a: RailDeletion, b: RailDeletion) -> Bool { a.id == b.id }
}

private final class RailUndoToken {}

/// An AI answer still being written: its words so far in `textSecondary`, a pulsing hairline under them.
private struct PendingReplyRow: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            ProgressHairline(value: nil)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ThoughtKind {
    /// The Kind submenu item.
    var menuTitle: String {
        switch self {
        case .idea: "Idea"
        case .question: "Question"
        case .todo: "To Do"
        case .intent: "Intent"
        }
    }
}

/// One thought: kind glyph, timestamp, anchor and due chips on top, text below.
private struct RailRow: View {
    let comment: Comment
    let kind: ThoughtKind
    let due: Date?
    let selected: Bool
    /// The rail has keyboard focus; selection draws in accent instead of grey.
    let active: Bool
    let editing: Bool
    @Binding var draft: String
    @Binding var editorFocused: Bool
    let focusRequest: Int
    let candidates: [FileRef]
    let recent: [FileRef]
    let onJump: (FileAnchor) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onLink: (String) -> Void
    @State private var hovering = false

    private var done: Bool { comment.state == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                KindGlyph(kind: kind, state: comment.state)
                Text(RailText.timestamp(comment.timestamp))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .onTapGesture(count: 2, perform: onEdit)
                    .simultaneousGesture(TapGesture().onEnded { onSelect() })
                if let a = comment.anchor { Chip(RailText.anchorLabel(a)) { onJump(a) } }
                if let due, !done { Chip(RailReading.dueLabel(due)) }
                Spacer(minLength: 0)
                // Where it came from, only when it wasn't typed here: an AI sparkle, or the app.
                if let provenance = comment.provenance, provenance.origin == .ai {
                    Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(Theme.Color.textTertiary)
                        .help("AI · " + (provenance.model ?? "generated"))
                        .accessibilityLabel("AI generated")
                } else if let app = comment.provenance?.appName {
                    Text(app).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                }
                if let raw = comment.provenance?.sourceURL, let url = URL(string: raw) {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square").font(.system(size: 10)) }
                        .foregroundStyle(Theme.Color.textTertiary)
                        .help(comment.provenance?.windowTitle ?? url.host ?? raw)
                }
                IconButton("pencil", help: "Edit Thought", action: onEdit)
                    .opacity(hovering || selected ? 1 : 0)
                    .frame(height: 16)
            }
            if editing {
                ThoughtField(text: $draft, focused: $editorFocused, placeholder: "", candidates: candidates, recent: recent,
                             focusRequest: focusRequest, onSubmit: onSubmit, onCancel: onCancel)
                    .padding(Theme.Space.xs)
                    // The editor sits `s − xs` inside the row: its corners are the row's, offset.
                    .background(Theme.Color.bgRaised, in: Self.editorShape)
                    .overlay(Self.editorShape.strokeBorder(Theme.Color.accent, lineWidth: Theme.Size.hairline))
                    .padding(-Theme.Space.xs)
            } else {
                RailRichText(text: comment.text, onLink: onLink, dimmed: done)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: Squircle(radius: Self.radius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: done)
    }

    private static let radius = Theme.Radius.m
    private static let editorShape = ConcentricSquircle(parentRadius: radius, padding: Theme.Space.s - Theme.Space.xs)

    private var background: Color {
        if selected { return active ? Theme.Color.selection : Theme.Color.fill }
        return hovering ? Theme.Color.hover : .clear
    }
}
