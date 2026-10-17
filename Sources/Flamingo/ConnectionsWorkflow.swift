import Foundation
import FlamingoCore
import FlamingoIndex

/// Making, accepting, dismissing and removing connections from anywhere in the shell.
/// Every change is one undoable action and refreshes the graph and the inspector.
extension AppState {
    /// Connect two files by hand. Accepting a suggestion is the same thing.
    func connect(_ a: FileRef, _ b: FileRef, note: String? = nil) {
        guard let s = session, a != b else { return }
        changeConnections(in: s, name: "Connect Files", connected: true, files: [a, b], note: note)
    }

    /// Connect every pair among `files`, as connect mode does for its group. Returns the
    /// pairs that are new, so taking a file back out removes only what this made.
    @discardableResult
    func connect(_ files: [FileRef]) -> [ManualConnection] {
        guard let s = session, Set(files).count > 1 else { return [] }
        let before = Set(((try? s.connections.all()) ?? []).map(\.id))
        changeConnections(in: s, name: "Connect Files", connected: true, files: files, note: nil)
        return ((try? s.connections.all()) ?? []).filter { !before.contains($0.id) }
    }

    /// Remove a hand-made connection. Links written in a thought or note stay: they belong
    /// to the text, and removing them means editing it.
    func disconnect(_ a: FileRef, _ b: FileRef) {
        guard let s = session else { return }
        changeConnections(in: s, name: "Remove Connection", connected: false, files: [a, b], note: nil)
    }

    /// Hide a suggestion between two files everywhere: the inspector, Wander and the graph.
    func dismissSuggestion(_ a: FileRef, _ b: FileRef) {
        guard let s = session else { return }
        let store = s.dismissed, generation = s
        let (x, y) = (a.relativePath, b.relativePath)
        do { try store.dismiss(x, y) } catch { showToast(ToastMessage(text: error.localizedDescription)); return }
        connectionsTouched()
        actionHistory.register(name: "Dismiss Suggestion", undo: { [weak self] in
            guard self?.session === generation else { return }
            try store.restore(x, y); self?.connectionsTouched()
        }, redo: { [weak self] in
            guard self?.session === generation else { return }
            try store.dismiss(x, y); self?.connectionsTouched()
        })
    }

    private func changeConnections(in s: VaultSession, name: String, connected: Bool, files: [FileRef], note: String?) {
        let store = s.connections
        do {
            let (before, after) = try store.setConnectionsUndoably(between: files, connected: connected, label: note)
            guard before != after else { return }
            connectionsTouched(identities: connected)
            actionHistory.register(name: name, undo: { [weak self] in
                guard self?.session === s else { return }
                try store.replaceConnections(before, expecting: after); self?.connectionsTouched()
            }, redo: { [weak self] in
                guard self?.session === s else { return }
                try store.replaceConnections(after, expecting: before); self?.connectionsTouched()
            })
        } catch {
            showToast(ToastMessage(text: error.localizedDescription))
        }
    }

    /// Something about connections changed on disk: the inspector reloads now, the graph
    /// soon. New hand-made connections also give their files a durable identity.
    func connectionsTouched(identities: Bool = false) {
        connectionsRevision &+= 1
        if identities { Task { await connectionsChanged() } }
        else { Task { await refreshGraph() } }
    }
}
