import AppKit
import SwiftUI
import FlamingoCore
import FlamingoCapture
import FlamingoIndex

/// What the morning inbox does to the vault. The view and the model are in `BriefingWorkflow`.
/// Merging with the thoughts work, two lines hook it up in `AppDelegate`:
///
///     state.briefing.catchUp = { [weak state] onEvent in await state?.nightShiftCatchUp(onEvent: onEvent) }
///     state.briefing.now = { [weak state] in state?.qaNow ?? Date() }
private enum BriefingUndoError: LocalizedError {
    case changed
    var errorDescription: String? { "Undo stopped because this item changed outside Flamingo. Your current files are untouched." }
}

extension AppState {
    /// The ribbon's tray, the palette's "Inbox" and ⌘0: opens the briefing, or closes it.
    func showBriefing() { briefing.toggle() }

    /// Palette entries: the inbox, and the toggle for opening it each morning.
    var briefingCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "inbox", title: "Inbox", keys: "⌘0", symbol: "tray", enabled: vault != nil) { [weak self] in self?.showBriefing() },
            PaletteCommand(id: "morning-inbox", title: Defaults.briefingAutoOpen ? "Turn Off Morning Inbox" : "Turn On Morning Inbox",
                           keys: nil, symbol: "sunrise") { Defaults.briefingAutoOpen.toggle() },
        ]
    }

    /// Changes one thought (done, snoozed, dismissed) through its uid, and registers the undo.
    /// `onUndo` / `onRedo` let the page put its row back or take it away again.
    func briefingChange(_ record: ThoughtRecord, name: String, _ edit: @escaping (inout Comment) -> Void,
                        onUndo: @escaping @MainActor () -> Void, onRedo: @escaping @MainActor () -> Void) async throws {
        guard let s = session else { throw CocoaError(.fileNoSuchFile) }
        let file = record.file
        let uid = try record.uid ?? s.sidecar.ensureUID(forCommentID: record.comment.id, in: file)
        let before = try s.sidecar.document(for: file)
        try s.sidecar.update(uid: uid, in: file) { edit(&$0) }
        let after = try s.sidecar.document(for: file)
        actionHistory.register(name: name, undo: { [weak self] in
            try self?.briefingRestore(before, expecting: after, file: file, in: s); onUndo()
        }, redo: { [weak self] in
            try self?.briefingRestore(after, expecting: before, file: file, in: s); onRedo()
        })
        await commentsDidChange(for: file, in: s)
    }

    /// Adds a reply under a thought, as the rail does, and registers the undo.
    func briefingReply(to record: ThoughtRecord, text: String,
                       onUndo: @escaping @MainActor () -> Void, onRedo: @escaping @MainActor () -> Void) async throws {
        guard let s = session else { throw CocoaError(.fileNoSuchFile) }
        let file = record.file
        let uid = try record.uid ?? s.sidecar.ensureUID(forCommentID: record.comment.id, in: file)
        let before = try s.sidecar.document(for: file)
        let reply = Comment(anchor: record.comment.anchor, text: text).stamped()
        let stored = try s.sidecar.appendReply(reply, toUID: uid, in: file)
        let after = try s.sidecar.document(for: file)
        s.trail.recordComment(stored, on: file)
        actionHistory.register(name: "Reply to Thought", undo: { [weak self] in
            try self?.briefingRestore(before, expecting: after, file: file, in: s); onUndo()
        }, redo: { [weak self] in
            try self?.briefingRestore(after, expecting: before, file: file, in: s); onRedo()
        })
        await commentsDidChange(for: file, in: s)
    }

    private func briefingRestore(_ snapshot: SidecarDocument?, expecting: SidecarDocument?, file: FileRef, in s: VaultSession) throws {
        guard session === s, try s.sidecar.document(for: file) == expecting else { throw BriefingUndoError.changed }
        try s.sidecar.replaceDocument(snapshot, for: file, expecting: expecting)
        Task { await commentsDidChange(for: file, in: s) }
    }

    /// Selects a thought's row in the rail once the open file's comments have loaded. By uid, since
    /// a row's derived id moves when its text is edited.
    func selectThought(uid: String?, fallback: UUID) {
        Task { [weak self] in
            for _ in 0..<14 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self else { return }
                let hit = self.comments.first { uid != nil && $0.uid == uid } ?? self.comments.first { $0.id == fallback }
                if let hit { self.selectedCommentID = hit.id; return }
            }
            self?.selectedCommentID = fallback
        }
    }
}
