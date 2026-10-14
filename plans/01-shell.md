# Plan 01 — App shell

**You own:** `Sources/Flamingo/` only.
**Read first:** `CONTRACT.md`, `DESIGN.md`. Then skim every other module's public API in
`Sources/*/` so you know what you'll be wiring. Those APIs are frozen; code against them now
even though their bodies are stubs. Other sessions are filling them in as you work.

## Mission

The window people live in. Finder-grade file browsing, instant preview of anything, and
the wiring that makes every other module show up in the right place. You are the
integrator: when another module's view exists, it appears in your layout.

## Milestones, in order

### M1 — A real app window (do this first, it unblocks QA)
- `main.swift` boots `NSApplication` as a regular app. Already there. Make it solid: Dock
  icon, app menu with About/Quit, File menu with Open Vault… (⌘O) and Open Recent.
- Three-column layout from DESIGN.md: sidebar, content, comments rail. Rail toggles with
  ⌘⌥I and remembers its state. Use `NSVisualEffectView` sidebar material behind the sidebar.
- Sidebar: a collapsible folder tree of the vault (not a flat list). Folders collapse by
  default below depth 1. Rows show `FileGlyph` + name. Keyboard navigation works. Type-to-select works.
- Preview: `QLPreviewView` for everything, except `.pdf` → `PDFView` (so you know the current
  page) and audio/video → `AVPlayerView` (so you know the current time). Publish the current
  `FileAnchor` into `AppState.anchor` whenever it changes. ⌘↑/⌘↓ moves page.
- Restore last vault and last selection on launch.
- Run `scripts/run.sh`. Open your own `~/Documents`. It should feel like Finder's preview
  pane in a window of its own.

### M2 — Modes and palette
- Mode switcher (⌘1 Files, ⌘2 Graph, ⌘3 Trail, ⌘4 Ask) as a segmented control in the
  toolbar area. Graph/Trail/Ask replace the content column with `GraphView`, `TrailView`,
  `AskView`. Selecting a node or chip in those views jumps back to Files with that file and
  anchor selected.
- Command palette (⌘K): one floating panel, one text field, fuzzy-matches file names and
  commands. Arrow keys, Enter, Esc. No header, no footer.
- Search (⌘F): same panel style, calls `IndexStore.search`, shows `SearchHit`s with snippet,
  Enter opens the file at the hit's anchor.
- Back/forward history (⌘[ ⌘]).

### M3 — Wiring
- On vault open: create `SidecarStore`, `IndexStore`, `TrailStore`, `VaultWatcher`. Start a
  background reindex and show a thin progress hairline under the toolbar while it runs.
  `VaultWatcher.onChange` → `IndexStore.update` and refresh the file tree.
- `CaptureController.shared.currentTarget` returns the selected file and current anchor.
  `onComment` → `SidecarStore.append`, `TrailStore.record(.commented)`, refresh the rail.
  Call `installInAppHotkey()` once.
- `TrailStore.record(.opened)` on selection change (debounced so scrolling a list doesn't spam).
- Comments rail shows `CommentsRail(comments:onJump:)` for the selected file. `onJump` sets
  the preview's anchor.
- Graph: `IndexStore.buildGraph(extraEdges: trailStore.edges())`, cached, rebuilt when sidecars change.

### M4 — Polish
- Drag a folder onto the window or Dock icon to open it as a vault.
- Quick Look's "Open with" (⌘↓ or double-click) opens the file in its native app.
- Hover on a file row shows comment count as a small tertiary number on the right.
- Window remembers frame. Sidebar width remembers. Everything feels instant.

## Done means
`scripts/run.sh` launches, you can open a folder with a mix of pptx/docx/xlsx/pdf/usdz,
click through them with arrow keys and see each render, press ⌘⇧C and type a thought and
see it appear in the rail, press ⌘2 and see the graph, ⌘K and jump anywhere.

## Don't
- Don't implement sidecar parsing, extraction, hotkeys, or graph drawing yourself. Wire the
  module's API. If the stub still returns nothing, that's fine; it will fill in.
- Don't put labels on things. See DESIGN.md.

## Subagent ideas
One agent on the folder tree, one on the preview pane variants, one on the command palette.
They touch different files in your directory. You wire.
