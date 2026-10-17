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

    public func onSaveEdit(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveEdit = handler; return rail
    }
    public func onSaveDelete(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveDelete = handler; return rail
    }
    public func onSaveRestore(_ handler: @escaping (Comment) async throws -> Void) -> CommentsRail {
        var rail = self; rail.saveRestore = handler; return rail
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
    @FocusState private var editorFocused: Bool
    @Environment(\.undoManager) private var undoManager

    /// Scroll target below the last row, so the bottom padding shows too.
    private static let end = "rail.end"

    private var rows: [Comment] {
        comments.enumerated()
            .filter { !hidden.contains($0.element.id) }
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map { pair in
                var c = pair.element
                if let t = pendingText[c.id] { c.text = t }
                return c
            }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { c in row(c).id(c.id) }
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

    private func row(_ c: Comment) -> some View {
        let isEditing = editing == c.id
        return RailRow(comment: c, selected: selection == c.id, active: railFocused || editorFocused,
                       editing: isEditing, draft: Binding(get: { draft }, set: {
                           draft = $0; backupEditingDraft($0)
                       }), editorFocus: $editorFocused,
                       onJump: { a in select(c); onJump(a) }, onSubmit: commitEdit, onCancel: cancelEdit,
                       onSelect: { select(c) }, onEdit: { beginEdit(c) }, onLink: { openLink?($0) })
            .contextMenu {
                Button("Edit") { beginEdit(c) }
                Button("Delete") { delete(c) }
            }
            .disabled(savingIDs.contains(c.id))
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
        } else if let last = rows.last?.id, added.contains(last) {
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
        guard selection != nil else { return .ignored }
        selection = nil
        return .handled
    }

    // MARK: Edit

    private func beginEdit(_ c: Comment) {
        selection = c.id
        draft = c.text
        editing = c.id
        DispatchQueue.main.async {
            editorFocused = true
            // The field editor selects everything on focus; a thought is appended to, not replaced.
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

/// One thought: timestamp and anchor chip on top, text below.
private struct RailRow: View {
    let comment: Comment
    let selected: Bool
    /// The rail has keyboard focus; selection draws in accent instead of grey.
    let active: Bool
    let editing: Bool
    @Binding var draft: String
    var editorFocus: FocusState<Bool>.Binding
    let onJump: (FileAnchor) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onLink: (String) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(RailText.timestamp(comment.timestamp))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .onTapGesture(count: 2, perform: onEdit)
                    .simultaneousGesture(TapGesture().onEnded { onSelect() })
                if let a = comment.anchor { Chip(RailText.anchorLabel(a)) { onJump(a) } }
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
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text)
                    .focused(editorFocus)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
                    .padding(Theme.Space.xs)
                    // The editor sits `s − xs` inside the row: its corners are the row's, offset.
                    .background(Theme.Color.bgRaised, in: Self.editorShape)
                    .overlay(Self.editorShape.strokeBorder(Theme.Color.accent, lineWidth: Theme.Size.hairline))
                    .padding(-Theme.Space.xs)
            } else {
                RailRichText(text: comment.text, onLink: onLink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: Squircle(radius: Self.radius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
    }

    private static let radius = Theme.Radius.m
    private static let editorShape = ConcentricSquircle(parentRadius: radius, padding: Theme.Space.s - Theme.Space.xs)

    private var background: Color {
        if selected { return active ? Theme.Color.selection : Theme.Color.fill }
        return hovering ? Theme.Color.hover : .clear
    }
}
