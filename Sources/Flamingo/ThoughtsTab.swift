import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoCapture

// MARK: - Thoughts

/// What the Thoughts tab writes to: an open file, or (with a folder selected and no file) the
/// folder's note.
struct ThoughtTarget: Equatable {
    var file: FileRef
    var note: ThoughtNote?

    var placeholder: String { "Thought on " + (note?.name ?? file.name) }
}

/// A thought the composer is answering.
struct ReplyTarget: Equatable {
    var file: FileRef
    var uid: String
    var firstLine: String
}

/// The open file's thoughts, oldest first (replies under their thought), and a field at the foot
/// for the next one, left at the place you're looking at. With a folder selected and no file it
/// is that folder's note.
struct ThoughtsTab: View {
    @Environment(AppState.self) var state
    let file: FileRef?

    var body: some View {
        if let file {
            ThoughtsPane(target: ThoughtTarget(file: file, note: nil), comments: state.comments, jobs: state.thoughts.jobs)
                .id(file)
        } else if let folder = state.selectedFolder, let note = ThoughtNote.folder(FileRef(relativePath: folder)) {
            FolderThoughts(note: note, jobs: state.thoughts.jobs).id(note.file)
        } else {
            Color.clear
        }
    }
}

/// A folder's note is not the open file, so its thoughts are read here and again whenever
/// the shell changes it.
private struct FolderThoughts: View {
    @Environment(AppState.self) var state
    let note: ThoughtNote
    @ObservedObject var jobs: ThoughtJobsModel
    @State private var comments: [Comment] = []

    var body: some View {
        ThoughtsPane(target: ThoughtTarget(file: note.file, note: note), comments: comments, jobs: jobs)
            .task(id: jobs.noteRevision) { comments = await state.noteComments(note.file) }
    }
}

private struct ThoughtsPane: View {
    @Environment(AppState.self) var state
    let target: ThoughtTarget
    let comments: [Comment]
    @ObservedObject var jobs: ThoughtJobsModel
    @State private var reply: ReplyTarget?
    @State private var replyFocus = 0

    private var file: FileRef { target.file }

    var body: some View {
        VStack(spacing: 0) {
            CommentsRail(
                comments: comments,
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
            .onReply { c in beginReply(c) }
            .onSetState { c, st, until in state.setThoughtState(c, to: st, until: until, in: file) }
            .onSetKind { c, kind in state.setThoughtKind(c, to: kind, in: file) }
            .onAskAI { c in state.askAssistant(about: c, in: file) }
            .onWork { c, recipe in state.workOnThought(c, recipe: recipe, in: file) }
            .onCopyLink { c in state.copyThoughtLink(c, in: file) }
            .onSendToCapybara { c in state.sendToCapybara(c, in: file) }
            .pendingReplies(jobs.pending)
            .onCancelPending { jobs.cancel($0) }
            .linkCandidates(state.files, recent: state.recentLinkTargets(excluding: file))
            .focusComment(state.selectedCommentID)
            .recoveryContext(file: file, vault: state.vault)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ThoughtComposer(target: target, reply: $reply, replyFocus: replyFocus)
        }
    }

    /// `r`, or Reply in the menu: the composer now answers this thought.
    private func beginReply(_ comment: Comment) {
        Task {
            guard let uid = try? await state.thoughtUID(for: comment, in: file) else { return }
            reply = ReplyTarget(file: file, uid: uid, firstLine: ThoughtLines.first(of: comment.text))
            replyFocus += 1
        }
    }
}

/// Type, Return. The thought lands on the open file at the current slide, page or line, or
/// answers the thought named above the field.
private struct ThoughtComposer: View {
    @Environment(AppState.self) var state
    let target: ThoughtTarget
    @Binding var reply: ReplyTarget?
    let replyFocus: Int
    @State private var draft = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var focused = false
    @State private var focusRequest = 0
    @StateObject private var echo = ThoughtEchoModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let failure {
                Text(failure).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ThoughtEcho(model: echo, onJump: { state.jumpToThought($0) }, onReplyTo: { hit in
                guard let uid = hit.uid else { return }
                reply = ReplyTarget(file: hit.file, uid: uid, firstLine: hit.firstLine)
                focusRequest += 1
            })
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let reply {
                    // The thought being answered, in its own words; clicking it lets go.
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: Theme.Size.iconSmall))
                        Text(reply.firstLine).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .contentShape(Rectangle())
                    .onTapGesture { self.reply = nil; focusRequest += 1 }
                    .transition(.opacity)
                }
                // Names where the thought lands, so the box reads as a place to write
                // (DESIGN.md principle 1's one exception). `[[` completes file names.
                ThoughtField(text: $draft, focused: $focused, placeholder: reply == nil ? target.placeholder : "",
                             candidates: state.files, recent: state.recentLinkTargets(excluding: target.file), editable: !saving,
                             focusRequest: focusRequest, onSubmit: save,
                             onCancel: {
                                 if reply != nil { reply = nil } else { NSApp.keyWindow?.makeFirstResponder(nil) }
                             })
                    .accessibilityLabel("New thought")
                if target.note == nil, reply == nil, let anchor = state.anchor {
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
            .animation(Theme.Motion.fast, value: reply)
        }
        .padding(Theme.Space.m)
        .onAppear { echo.similar = { [state] draft in await state.similarThoughtHits(draft) } }
        .onChange(of: draft) { _, new in echo.update(draft: new) }
        .onChange(of: replyFocus) { focusRequest += 1 }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saving else { return }
        saving = true
        failure = nil
        let answering = reply
        Task {
            do {
                if let answering {
                    try await state.saveThoughtReply(text: text, toUID: answering.uid, in: answering.file)
                    reply = nil
                } else if let note = target.note {
                    try await state.saveNoteComment(Comment(text: text), to: note.file, frontmatter: note.frontmatter)
                } else {
                    let comment = Comment(anchor: state.anchor, text: text)
                    try await state.saveComment(comment, to: target.file)
                    state.celebrate(comment, on: target.file)
                }
                draft = ""
                echo.reset()
            } catch {
                failure = "Not saved · " + error.localizedDescription
            }
            saving = false
            focusRequest += 1
        }
    }
}

extension AppState {
    /// Open tabs, then where you've been, newest first: what `[[` offers before you type.
    func recentLinkTargets(excluding file: FileRef) -> [FileRef] {
        var seen = Set<FileRef>(), out: [FileRef] = []
        for f in openFiles.reversed() + history.entries.reversed().compactMap(\.file) where out.count < 30 {
            if f != file, seen.insert(f).inserted { out.append(f) }
        }
        return out
    }
}
