import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Panes and layouts. `AppState` owns four panes; `tiling.arrangement` says how many show and
/// where. Selection still mirrors the active pane exactly as it did with two.
extension AppState {
    /// One line per layout or focus change, for the QA scripts.
    func logTiles(_ why: String) {
        let a = tiling.arrangement
        Log.debug("tiles: \(why) layout=\(a.kind.rawValue) order=\(a.visible.map(\.rawValue).joined(separator: ",")) active=\(a.slot(of: activePaneID).map { $0 + 1 } ?? 0) files=\(visiblePanes.map { $0.file?.relativePath ?? "-" }.joined(separator: ","))")
    }

    // MARK: Layout

    /// Switches layout. Panes a larger layout reveals start empty (they open as launchers) and
    /// the first takes focus; panes a smaller layout hides keep their documents. `anchor` is the
    /// pane that must stay (the one whose ••• was clicked); the active pane by default.
    func setLayout(_ layout: TileLayout, from anchor: DocumentPaneID? = nil) {
        guard vault != nil, layout != tiling.arrangement.kind else { return }
        let before = undoWorkspaceSnapshot(), panelsBefore = panelState(), wasSuppressed = suppressActionHistory
        suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed }
        mode = .files
        let (arrangement, revealed) = tiling.arrangement.resized(to: layout, keeping: anchor ?? activePaneID)
        revealed.forEach { pane($0).reset() }
        apply(arrangement, preferring: revealed.first ?? anchor)
        if let first = revealed.first {
            hostWindow?.makeFirstResponder(nil)
            pane(first).focusWhenReady()
        }
        fitPanels(for: layout)
        persistWorkspace()
        logTiles("layout")
        // Undo brings back the layout, the panes and the panels that were folded for it.
        let after = undoWorkspaceSnapshot(), panelsAfter = panelState()
        guard !openingVault, !wasSuppressed, !actionHistory.isApplying else { return }
        actionHistory.register(name: "Change Layout",
                               undo: { [weak self] in self?.restoreUndoWorkspace(before); self?.applyPanels(panelsBefore) },
                               redo: { [weak self] in self?.restoreUndoWorkspace(after); self?.applyPanels(panelsAfter) })
    }

    // MARK: Making room

    struct PanelState: Equatable {
        var inspector: Bool, pinned: Bool, sidebarCollapsed: Bool
        var autoHidden: [TilePanel: CGFloat]
    }

    func panelState() -> PanelState {
        PanelState(inspector: railVisible, pinned: railPinned, sidebarCollapsed: sidebarCollapsed, autoHidden: tiling.autoHidden)
    }

    func applyPanels(_ state: PanelState) {
        tiling.applyingPanels = true
        withAnimation(Theme.Motion.normal) {
            railVisible = state.inspector; railPinned = state.pinned; sidebarCollapsed = state.sidebarCollapsed
        }
        tiling.autoHidden = state.autoHidden
        tiling.applyingPanels = false
    }

    /// What the window shows now, for deciding whether the tiles have room.
    var tilePanelSpace: TilePanels.Space {
        TilePanels.Space(window: windowWidth, ribbon: Ribbon.width + Theme.Size.hairline,
                         sidebar: sidebarCollapsed ? 0 : Theme.Size.hairline + sidebarWidth,
                         inspector: railShown ? Theme.Size.hairline + layout.rightWidth : 0)
    }

    /// Folds the inspector, then the sidebar, when `layout` can't give each column its width; brings
    /// back exactly what was folded here once a layout (or window) has room again. A panel the user
    /// reopened is theirs: it's dropped from the list and never touched.
    func fitPanels(for layout: TileLayout, allowHide: Bool = true) {
        let space = tilePanelSpace
        let hide = allowHide ? TilePanels.hide(for: layout, space) : []
        let restore = hide.isEmpty ? TilePanels.restore(tiling.autoHidden, for: layout, space) : []
        guard !hide.isEmpty || !restore.isEmpty else { return }
        tiling.applyingPanels = true
        withAnimation(Theme.Motion.normal) {
            if hide.contains(.inspector) { railVisible = false; railPinned = false; tiling.autoHidden[.inspector] = space.inspector }
            if hide.contains(.sidebar) { sidebarCollapsed = true; tiling.autoHidden[.sidebar] = space.sidebar }
            if restore.contains(.sidebar) { sidebarCollapsed = false }
            if restore.contains(.inspector) { railVisible = true; railPinned = windowWidth < AppState.narrowWindow }
            for panel in restore { tiling.autoHidden[panel] = nil }
        }
        tiling.applyingPanels = false
        Log.debug("tiles: panels hide=\(hide.map(\.rawValue).sorted()) restore=\(restore.map(\.rawValue).sorted())")
    }

    /// A tiled window that gets narrower folds panels; one that gets wider gives them back.
    func windowResizedForTiles() {
        let width = windowWidth, narrower = width < tiling.lastFitWidth
        defer { tiling.lastFitWidth = width }
        guard splitVisible || !tiling.autoHidden.isEmpty else { return }
        fitPanels(for: tiling.arrangement.kind, allowHide: narrower)
    }

    /// Installs an arrangement and keeps the active pane on screen: `preferred` takes focus if given.
    private func apply(_ arrangement: TileArrangement, preferring preferred: DocumentPaneID?) {
        tiling.set(arrangement)
        let visible = arrangement.visible
        if let preferred, visible.contains(preferred) {
            activatePane(preferred)
        } else if !visible.contains(activePaneID) {
            activePane.cancelFocusRequest()
            activePaneID = visible[0]
            synchronizeActivePane(record: true)
        }
    }

    /// ⌘\: the same file again beside the current one, or back to one pane.
    func toggleSplit() {
        let before = undoWorkspaceSnapshot(), wasSuppressed = suppressActionHistory
        suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed; recordWorkspaceChange("Toggle Split View", before: before) }
        guard vault != nil else { return }
        if splitVisible { closeSplit(); return }
        let (arrangement, revealed) = tiling.arrangement.resized(to: .halves, keeping: activePaneID)
        tiling.set(arrangement)
        mode = .files
        if let second = revealed.first.map(pane), second.file == nil, let selected {
            second.show(selected)
            second.anchor = anchor
            second.jumpRequest = anchor.map { JumpRequest(file: selected, anchor: $0) }
            second.sourceHighlight = sourceHighlight
            second.readSource = activePane.readSource
        }
        fitPanels(for: .halves)
        persistWorkspace()
    }

    /// Back to one pane, the one in the first slot.
    func closeSplit() {
        let before = undoWorkspaceSnapshot(), wasSuppressed = suppressActionHistory
        suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed; recordWorkspaceChange("Close Split View", before: before) }
        guard splitVisible else { return }
        let first = tiling.arrangement.order[0]
        activatePane(first)
        tiling.set(tiling.arrangement.resized(to: .single, keeping: first).0)
        hostWindow?.makeFirstResponder(nil)
        pane(first).focusWhenReady()
        fitPanels(for: .single)
        persistWorkspace()
    }

    func openBeside(_ file: FileRef, anchor: FileAnchor? = nil) {
        let before = undoWorkspaceSnapshot(), wasSuppressed = suppressActionHistory
        suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed; recordWorkspaceChange("Open Beside", before: before) }
        guard vault?.exists(file) == true else { return }
        let destination: DocumentPaneID
        if splitVisible {
            let visible = tiling.arrangement.visible
            destination = visible.first { $0 != activePaneID && pane($0).file == nil }
                ?? tiling.arrangement.neighbor(of: activePaneID, step: 1)
        } else {
            let (arrangement, revealed) = tiling.arrangement.resized(to: .halves, keeping: activePaneID)
            tiling.set(arrangement)
            destination = revealed[0]
        }
        mode = .files
        activatePane(destination)
        select(file, anchor: anchor, source: .other)
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
        fitPanels(for: tiling.arrangement.kind)
        persistWorkspace()
    }

    /// Opens `file` in a given pane (a launcher's pick). The other panes stay as they are.
    func open(_ file: FileRef, inPane id: DocumentPaneID, anchor: FileAnchor? = nil) {
        guard vault?.exists(file) == true, tiling.arrangement.visible.contains(id) else { return }
        mode = .files
        activatePane(id)
        select(file, anchor: anchor, source: .other)
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
        logTiles("open")
    }

    // MARK: Closing and focus

    /// Closes a pane in a tiled layout. Its tab closes with it unless another pane shows the
    /// same file; the layout collapses a step and focus moves to the previous slot.
    func closePane(_ id: DocumentPaneID) {
        let before = undoWorkspaceSnapshot(), wasSuppressed = suppressActionHistory
        suppressActionHistory = true
        defer { suppressActionHistory = wasSuppressed; recordWorkspaceChange("Close Pane", before: before) }
        guard vault != nil, let (arrangement, successor) = tiling.arrangement.closing(id) else { return }
        let closing = pane(id)
        if let file = closing.file, !tiling.arrangement.visible.contains(where: { $0 != id && pane($0).file == file }) {
            guard releaseTab(file) else { return }
        }
        closing.cancelFocusRequest()
        closing.show(nil); closing.pendingFile = nil
        if id == activePaneID {
            tiling.set(arrangement)
            activePaneID = successor
            synchronizeActivePane(record: true)
        } else {
            tiling.set(arrangement)
        }
        activatePane(successor)
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
        fitPanels(for: tiling.arrangement.kind)
        persistWorkspace()
        logTiles("close")
    }

    /// ⌥⌘→ and ⌥⌘←: the next or previous pane, wrapping.
    func focusPane(step: Int) {
        guard splitVisible else { return }
        activatePane(tiling.arrangement.neighbor(of: activePaneID, step: step))
        // The containing pane remains mounted. Its native responder is focused by the
        // pane host; no anchor request is regenerated just because focus moved.
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
        logTiles("focus")
    }

    func focusOtherPane() { focusPane(step: 1) }

    /// Slot `n` (0-based) takes focus, if it is showing.
    func focusPane(slot: Int) {
        let visible = tiling.arrangement.visible
        guard visible.indices.contains(slot) else { return }
        activatePane(visible[slot])
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
    }

    /// A launcher gives up focus (Esc on an empty field): back to the previous pane.
    func leaveLauncher(_ id: DocumentPaneID) {
        guard splitVisible else { return }
        let target = tiling.arrangement.neighbor(of: id, step: -1)
        guard target != id else { return }
        activatePane(target)
        hostWindow?.makeFirstResponder(nil)
        activePane.focusWhenReady()
    }

    /// The panes on screen, in slot order.
    var visiblePanes: [DocumentPane] { tiling.arrangement.visible.map(pane) }

    // MARK: Snapshots

    /// The workspace's panes as saved. Slots 0 and 1 also fill the legacy fields, so a build
    /// that knows two panes reads a sensible two-pane workspace.
    func savedSplit() -> SavedSplitWorkspace {
        let arrangement = tiling.arrangement
        let slot = arrangement.slot(of: activePaneID) ?? 0
        return SavedSplitWorkspace(
            visible: arrangement.kind != .single,
            activePane: slot == 1 ? .secondary : .primary,
            primary: pane(arrangement.order[0]).snapshot,
            secondary: pane(arrangement.order[1]).snapshot,
            tiles: SavedTiles(layout: arrangement.kind, order: arrangement.order, active: activePaneID,
                              panes: allPanes.map { SavedTilePane(id: $0.id, pane: $0.snapshot) }))
    }

    /// Puts panes, layout and focus back. The caller wraps this in `synchronizingPane`.
    func restoreSplit(_ split: SavedSplitWorkspace, in vault: Vault) {
        if let tiles = split.tiles {
            for id in DocumentPaneID.allCases {
                if let saved = tiles.panes.first(where: { $0.id == id }) { pane(id).restore(saved.pane, in: vault) }
                else { pane(id).reset() }
            }
            let arrangement = TileArrangement(kind: tiles.layout, order: tiles.order).repaired()
            tiling.set(arrangement)
            activePaneID = arrangement.visible.contains(tiles.active) ? tiles.active : arrangement.order[0]
            logTiles("restored")
        } else {
            for id in DocumentPaneID.allCases { pane(id).reset() }
            pane(.primary).restore(split.primary, in: vault)
            pane(.secondary).restore(split.secondary, in: vault)
            tiling.set(TileArrangement(kind: split.visible ? .halves : .single))
            activePaneID = split.visible ? split.activePane : .primary
            logTiles("restored legacy")
        }
    }

    // MARK: Commands

    var paneCommands: [PaletteCommand] {
        let hasVault = vault != nil
        var list = TileLayout.allCases.map { layout in
            PaletteCommand(id: "layout-" + layout.rawValue, title: "Layout: " + layout.title, keys: "⌃⌥⌘" + layout.key,
                           symbol: layout.symbol, enabled: hasVault) { [weak self] in self?.setLayout(layout) }
        }
        list += [
            PaletteCommand(id: "focus-other-pane", title: "Focus Next Pane", keys: "⌘⌥→", symbol: "arrow.left.arrow.right", enabled: splitVisible) { [weak self] in self?.focusPane(step: 1) },
            PaletteCommand(id: "focus-previous-pane", title: "Focus Previous Pane", keys: "⌘⌥←", symbol: "arrow.left.arrow.right", enabled: splitVisible) { [weak self] in self?.focusPane(step: -1) },
        ]
        return list
    }
}
