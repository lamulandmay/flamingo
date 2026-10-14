import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Existing thoughts on the selected file, newest last. Clicking an anchored
/// comment asks the shell to jump there. Plan 03 owns.
///
/// Click selects, ↑↓ move, Return or double-click edits in place, ⌫ deletes.
/// A delete shows a five-second undo line at the bottom when `onRestore` is set.
public struct CommentsRail: View {
    public var comments: [Comment]
    public var onJump: (FileAnchor) -> Void
    public var onEdit: (Comment) -> Void
    public var onDelete: (Comment) -> Void
    var openLink: ((String) -> Void)?
    var restore: ((Comment) -> Void)?

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
    @FocusState private var railFocused: Bool
    @FocusState private var editorFocused: Bool
    @Environment(\.undoManager) private var undoManager

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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { c in row(c).id(c.id) }
                }
                .padding(Theme.Space.s)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { undoLine }
            .onAppear {
                if let last = rows.last?.id { DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) } }
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
        .onChange(of: editorFocused) { _, focused in if !focused, editing != nil { commitEdit() } }
        .task(id: deletion?.id) { await expireDeletion() }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = RailText.linkTarget(from: url) else { return .systemAction }
            openLink?(target)
            return .handled
        })
    }

    // MARK: Rows

    private func row(_ c: Comment) -> some View {
        let isEditing = editing == c.id
        let mask: GestureMask = isEditing ? .subviews : .all
        return RailRow(comment: c, selected: selection == c.id, active: railFocused || editorFocused,
                       editing: isEditing, draft: $draft, editorFocus: $editorFocused,
                       onJump: { a in select(c); onJump(a) }, onSubmit: commitEdit, onCancel: cancelEdit)
            .gesture(TapGesture(count: 2).onEnded { beginEdit(c) }, including: mask)
            .simultaneousGesture(TapGesture().onEnded { select(c) }, including: mask)
            .contextMenu {
                Button("Edit") { beginEdit(c) }
                Button("Delete") { delete(c) }
            }
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
        if let d = deletion, newSet != d.expected { endDeletion() }
        guard !newSet.subtracting(oldSet).isEmpty, let last = rows.last?.id else { return }
        if oldSet.isDisjoint(with: newSet) {
            proxy.scrollTo(last, anchor: .bottom)
        } else {
            withAnimation(Theme.Motion.normal) { proxy.scrollTo(last, anchor: .bottom) }
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
        DispatchQueue.main.async { editorFocused = true }
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
        pendingText[id] = text
        onEdit(updated)
    }

    private func cancelEdit() {
        editing = nil
        railFocused = true
    }

    // MARK: Delete and undo

    private func delete(_ c: Comment) {
        let before = rows
        if selection == c.id, let i = before.firstIndex(where: { $0.id == c.id }) {
            let next = i + 1 < before.count ? before[i + 1] : (i > 0 ? before[i - 1] : nil)
            selection = next?.id
        }
        if editing == c.id { editing = nil }
        hidden.insert(c.id)
        endDeletion()
        onDelete(c)
        guard restore != nil else { return }
        let d = RailDeletion(comment: c, expected: Set(comments.map(\.id)).subtracting([c.id]))
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
        if !fromUndoManager { undoManager?.removeAllActions(withTarget: d.token) }
        hidden.remove(d.comment.id)
        restore?(d.comment)
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
        if !Task.isCancelled, deletion?.id == id { endDeletion() }
    }

    @ViewBuilder private var undoLine: some View {
        if deletion != nil {
            VStack(spacing: 0) {
                Hairline()
                HStack(spacing: Theme.Space.s) {
                    Text("Deleted")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer(minLength: 0)
                    Button("Undo") { undoDeletion() }
                        .buttonStyle(.plain)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.accent)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Size.row)
            }
            .background(Theme.Color.bgRaised)
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
    /// The ids the shell should report once the delete lands.
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
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(RailText.timestamp(comment.timestamp))
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                if let a = comment.anchor { RailChip(anchor: a) { onJump(a) } }
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
                    .background(Theme.Color.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .strokeBorder(Theme.Color.accent, lineWidth: Theme.Size.hairline))
                    .padding(-Theme.Space.xs)
            } else {
                Text(RailText.attributed(comment.text))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text)
                    .tint(Theme.Color.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
    }

    private var background: Color {
        if selected { return active ? Theme.Color.selection : Theme.Color.fill }
        return hovering ? Theme.Color.hover : .clear
    }
}

/// `slide 7`. Clicking jumps the preview there.
private struct RailChip: View {
    let anchor: FileAnchor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(RailText.anchorLabel(anchor))
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, Theme.Space.xs / 4)
                .background(Theme.Color.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : Theme.Opacity.rest)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
    }
}
