import AppKit
import FlamingoCore

extension AppState {
    /// Points the recents model at a freshly opened session. Open tabs and then history stand
    /// in while the trail has too little to fill the ring.
    func attachRecents(to session: VaultSession) {
        recents.fallback = { [weak self] in
            guard let self else { return [] }
            var out: [FileRef] = []
            var seen = Set<FileRef>()
            func add(_ file: FileRef?) { if let file, seen.insert(file).inserted { out.append(file) } }
            self.openFiles.reversed().forEach(add)
            // History times can't be trusted (restored entries are all stamped now), so it only
            // supplies an order.
            self.history.entries.reversed().filter { !$0.transient }.forEach { add($0.file) }
            return out
        }
        recents.attach(trail: session.trail, vault: session.vault)
    }

    /// Shows `file` the way the ring and the Recent Files menu do: if another visible pane
    /// already shows it, that pane takes focus; otherwise it opens in the active pane at the
    /// place that pane or the workspace remembers. `anchor` (the trail's last place in the
    /// file) is only a fallback for when neither remembers one.
    func reveal(_ file: FileRef, anchor: FileAnchor? = nil) {
        guard let vault, vault.exists(file) else {
            recents.refreshSoon(after: 0)
            return
        }
        let visible = splitVisible ? [primaryPane, secondaryPane] : [primaryPane]
        if let other = visible.first(where: { $0.id != activePaneID && $0.file == file }) {
            mode = .files
            activatePane(other.id)
            hostWindow?.makeFirstResponder(nil)
            other.focusWhenReady()
            return
        }
        let remembered = activePane.anchors[file.relativePath] ?? savedAnchors[file.relativePath]
        jump(to: file, anchor: remembered == nil ? anchor : nil)
    }
}
