I couldn't save the plan file because this session has no write tool, so the full plan is below.

# Plan: ⌘⌥ hold radial of recent files + ••• pane tiling with launchers

## 0. What I found that changes the brief

- **The last position in a file already comes back.** `AppState.select` (AppState.swift:1522) falls back to `activePane.anchors[path] ?? savedAnchors[path]` when no anchor is passed. So the radial calls `jump(to:anchor: nil)` and only passes Trail's last anchor when neither of those has one.
- **Headless QA can't reach a local event monitor.** QAHook delivers keys with `window.sendEvent` / `firstResponder.keyDown` (QAHook.swift:115). Local monitors only run inside `NSApp.sendEvent`, so they never see these events. The radial therefore needs a direct entry point that QAHook calls. Its "main window is key" check also needs a QA override, because the QA app is never key.
- **History times can't be used for recency.** Restored history entries get `pushedAt = Date()` (`SavedHistory.restored`, Workspace.swift:44), so every restored entry looks brand new. They are only usable as a fallback list with no times attached.
- **The connection model is reusable.** `FileConnections.merge(...)` is public and pure (FileConnections.swift:93), and each `FileConnection` already carries a 0–1 `strength`. The launcher can rank with it without the excerpt reads that `fileConnections(of:)` does.
- **Mentions and "opened together" only exist inside the built graph.** `state.graph.edges` is only built while Graph mode, the Connections tab or Wander is showing (AppState.swift:2021). The launcher has to get "opened together" from `TrailStore.edges()` itself.
- **The launcher's field should be `CommandField`** (NewFileSheet.swift:241). It already receives ↑↓, Return and Esc as editing commands. One change is needed: it always grabs focus on creation (`makeFirstResponder` at :266), so it needs an `autofocus: Bool = true` parameter.
- **CONTRACT.md:100 is the shared keyboard map.** New keys get added there as new rows. This is allowed but should be done with care.
- **Nothing is committed** (HANDOVER.md:136). Step one is to commit the current tree and branch.

## 1. Decisions

| Question | Decision |
|---|---|
| 8 slots or an outer ring | **8, no outer ring.** Above 8 slices, flick menus get noticeably less accurate. An outer ring needs distance thresholds that fight quick flicks. The 9th file onward is one ⌘K away. **With 4 or fewer files, use 4 compass slots** so the targets are bigger. |
| Exclude the current file | **Yes**, the active pane's file. A file showing in another pane stays in the ring; picking it focuses that pane instead of loading it twice. |
| Release in the dead zone | **Close without opening.** This also makes system ⌥⌘ shortcuts harmless (⌥⌘D, ⌥⌘Esc, accessibility zoom): the app never sees their keyDown, and releasing without moving the pointer does nothing. |
| Where the ranking lives | The pure ranking goes in **FlamingoTrail as new public API** (`TrailRecents`), tested in FlamingoTrailTests. Caching, file-exists checks, outside-edit detection and fallback live in the app's `RecentFilesModel`. |
| N panes | **A fixed pool of 4 `DocumentPane`s**: `DocumentPaneID { primary, secondary, third, fourth }`. Raw values stay strings, so old snapshots decode. An `order` list decides which panes show and where. Panes are never recreated, so their views stay mounted across layout changes. |
| How panes are laid out | **One custom container**, not nested split views. A flat `ForEach` over visible panes keyed by id, each placed in its frame, plus drag handles on the gaps. Changing layout or closing a neighbour only changes frames; no PDF, Quick Look or text view remounts. The old 2-pane-only divider grip (PreviewPane.swift:39-54) goes. |
| Where ••• sits | **On each pane, top center.** In tiled mode it's in the 36pt pane header; in single mode it's in the center of DocumentSurface's 30pt breadcrumb row. **The TopBar split button (RootView.swift:189-192) is removed.** ⌘\ and the menus remain. |
| What ⌘\ does | Unchanged: toggles single ↔ halves, and shows the current file twice if the second pane is empty. All 11 SplitWorkspaceTests stay as written. ••• and the Layout menu reveal new panes as **launchers**. |
| Layout keys | **⌃⌥⌘1–5** (Single, Two Side by Side, Three Columns, One and Two, Four). These are unused; ⌃⌘1–3 and ⌥⌘1/3 are taken. ⌥⌘→ becomes "Focus Next Pane" and ⌥⌘← "Focus Previous Pane". |
| Panes hidden by a smaller layout | They keep their file, for undo and the ⌘\ round trip. A larger layout chosen from ••• or the menu resets the panes it reveals, so they open as launchers. The undo snapshot keeps what was there. |

## 2. Feature A: hold ⌘⌥ for recent files

### 2.1 FlamingoTrail (new public API, nothing renamed)

New file `Sources/FlamingoTrail/TrailRecents.swift`:

```swift
public struct RecentFile: Sendable, Equatable, Identifiable {
    public var file: FileRef; public var score: Double
    public var lastTouched: Date; public var lastOpened: Date?; public var lastEdited: Date?   // saved/commented
    public var lastAnchor: FileAnchor?; public var thoughts: Int
    public var id: String { file.relativePath }
}
public struct RecentsTuning: Sendable, Equatable {
    public var window: TimeInterval = 30 * 86_400
    public var recencyHalfLife: TimeInterval = 6 * 3600, recencyWeight = 4.0
    public var frequencyHalfLife: TimeInterval = 3 * 86_400
    public var burst: TimeInterval = 30 * 60                     // ≤1 event per kind per file per burst
    public var weights: [TrailEvent.Kind: Double] = [.opened: 1, .saved: 2, .commented: 2.5, .linked: 1.5]
    public var editedBoost = 1.25
}
public enum TrailRecents {
    public static func rank(_ events: [TrailEvent], now: Date, limit: Int, tuning: RecentsTuning = .init()) -> [RecentFile]
}
extension TrailStore {   // call off the main thread; drops old events before sorting
    public func recentFiles(now: Date = Date(), limit: Int = 24, tuning: RecentsTuning = .init()) throws -> [RecentFile]
}
```

Score = `recencyWeight · 2^(−(now−lastTouched)/recencyHalfLife)` + Σ over burst-merged events of `w(kind) · 2^(−age/frequencyHalfLife)`, × `editedBoost` if edited in the last 7 days. Events are skipped when they have no file, are `.searched`, or point into `.flamingo/`. Ties break by path. `recentFiles` filters by date before sorting, unlike `events(since:)` at Trail.swift:343.

### 2.2 App: `RecentFilesModel`

New file `Sources/Flamingo/RecentFiles.swift`. It's a `@MainActor ObservableObject` held on AppState as `let recents = RecentFilesModel()`.

- `@Published private(set) var items: [RecentItem]` (up to 24). `RecentItem` has `file, lastTouched: Date?, edited: Bool, lastAnchor, score`.
- `thumbnails: [String: NSImage]`, pre-warmed for the top 9 with `Thumbnails.thumbnail(for:in:size:)` at 48pt @2x.
- `attach(_ session: VaultSession?)` is called from `AppState.open` (AppState.swift:314). `refreshSoon()` waits 400ms. `func ring(excluding: FileRef?) -> [RecentItem]`.
- It watches `TrailStore.didChangeNotification` itself, **only when `note.object === session.trail`**. Every live store posts the notification, including capture's temporary ones. `trailEnabled.didSet` (AppState.swift:206) also calls `refreshSoon()`.
- Refresh runs in a detached task:
  1. `trail.recentFiles(limit: 40)`.
  2. Stat each candidate and drop missing ones. This is used instead of `fileSet`, which is incomplete until the file listing finishes.
  3. If a candidate's disk mtime is later than `lastOpened + 2s`, mark it **edited** and use the mtime for recency. This is the only use of disk mtime, and only for files the user has opened before.
  4. Re-sort and keep 24.
- Fallback when the trail has nothing in the window: `openFiles.reversed()`, then non-transient `history.entries.reversed()`, deduplicated, with no times. If the trail has fewer than 8, `openFiles` fills the rest.
- Nothing is computed while ⌘⌥ is held. The radial only reads `items`.

### 2.3 How the hold behaves

New file `Sources/Flamingo/RadialRecents.swift` has three parts:

- **`RadialHoldMachine`**, a pure struct for tests: `mutating func handle(_: Input, now: TimeInterval) -> (effects: [Effect], passThrough: Bool)`.
  - Inputs: `.flags(ModifierFlags, buttonsDown: Bool)`, `.keyDown(UInt16)`, `.mouseDown`, `.scroll`, `.tick`, `.pointer(CGPoint)`, `.resign`.
  - Effects: `.schedule(delay)`, `.present(origin)`, `.highlight(Int?)`, `.commit(Int)`, `.dismiss(animated: Bool)`.
- **`RadialMenuModel`**, the published state for the overlay, held on AppState as `let radial`. Only the overlay observes it, so pointer moves don't redraw anything else.
- **`RadialRecentsController`**, created in AppDelegate after the SwipeNavigator (AppDelegate.swift:57). It has `static weak var shared`. It installs one local monitor for `[.flagsChanged, .keyDown, .left/right/otherMouseDown, .scrollWheel]`. While the ring is open it polls `window.mouseLocationOutsideOfEventStream` with `window.displayLink`, which keeps working over Quick Look's remote views and needs no `acceptsMouseMovedEvents`. It watches `NSWindow.didResignKeyNotification` and `NSApplication.didResignActiveNotification`.

| Phase | Event | Result |
|---|---|---|
| idle | flags become **exactly** ⌘⌥ (ignoring caps lock and fn), coming from fewer modifiers (so releasing ⇧ from ⌘⌥⇧ doesn't count), and all of these hold: main window key (or QA override), no sheet, `NSApp.modalWindow == nil`, no mouse button down, a vault is open, no marked IME text, at least 1 item | **armed**: timer `Defaults.radialHoldDelay` (0.30s) |
| armed | keyDown, mouseDown, scroll, any flags change, resign | idle; the event passes through, so ⌥⌘H/N/I/L/1/3/→ still work |
| armed | timer fires and flags are still exactly ⌘⌥ | **open**: center = pointer kept inside the window by 160+8pt; take a snapshot of `recents.ring(excluding: activePane.file)` limited to 8 |
| open | pointer moves | slot from movement since opening (not from the drawn center, which may have been shifted to fit); 28pt dead zone; 4° hysteresis at slot edges; 45° per slot (90° with 4 or fewer); no outer limit; a haptic `.alignment` on each change to a non-empty slot |
| open | ⌘ or ⌥ released | commit if a slot is highlighted, otherwise close |
| open | Esc | close; the key is consumed |
| open | other keyDown | close with no animation; the key passes through |
| open | mouseDown | close; the click passes through (protects ⌘⌥ drag-to-alias) |
| open | resign | close |

flagsChanged events are never consumed, so graph ⌥ handling still sees them (GraphGestures.swift:133).

**Commit** calls `state.reveal(file, anchor:)`:
- If a visible pane other than the active one already shows the file, activate and focus that pane.
- Otherwise call `jump(to:anchor:)`. Pass Trail's `lastAnchor` only when the pane and saved anchors have none.
- A file deleted while the ring was open is silently dropped and `refreshSoon()` runs.

### 2.4 What it looks like

New file `Sources/Flamingo/RadialRecentsView.swift`. It's a full-window overlay in RootLayout, placed after the drop overlay (RootView.swift:93), with `.ignoresSafeArea().allowsHitTesting(false)`.

- **Plate:** 320pt `Circle` (changed from a squircle after review: the menu is a dial), hub a 120pt `Circle`. Same recipe as PanelChrome: sidebar `VisualEffect`, hairline border, shadow 0.28 / 24 / y10. Drawn locally so FlamingoDesign doesn't change.
- **Hub:** 120pt `Squircle(radius: 36)` filled with `Theme.Color.fill`. Empty when nothing is highlighted. When something is:
  - name in `bodyMedium`, 2 lines, truncated in the middle;
  - folder in `monoSmall` `textTertiary`, truncated at the start;
  - one line in `small` `textSecondary`: a `pencil` glyph if edited, the abbreviated relative time, and `text.bubble` + count from `state.commentCounts` when above 0.
- **Tiles:** 56pt `Squircle(radius: Theme.Radius.m)` centered 116pt from the middle, slot 0 at 12 o'clock and going clockwise in rank order.
  - Contents: a 48pt thumbnail clipped to `ConcentricSquircle(parentRadius: 8, padding: 4)`, otherwise `FileGlyph(size: 22)`.
  - Edited files get a 6pt `Squircle(radius: 3)` dot in `textSecondary`, 4pt in from the top-trailing corner.
  - Highlighted tile: `Theme.Color.selection` fill plus `.focusRing(true, radius: 8)`. No size change.
  - I checked the spacing: diagonal tiles clear the hub by about 9pt, and outer tiles stay inside the plate corner.
- **Motion:** fades in over `Motion.fast`; highlight changes over `Motion.fast`; commit fades out 150ms while navigation happens at once; closing because of a key removes it with no fade. Nothing scales. Durations are multiplied by `FLAMINGO_SLOWMO`, read the same way as GraphModel.swift:852.

### 2.5 Discoverability, accessibility and QA hooks

- **Go → Recent Files** submenu, filled when opened through an `NSMenuDelegate` from `recents.ring(excluding:)`. File names as titles, `FileGlyph.nsImage` icons, no key. This gives VoiceOver users a route and lets QA use `menu <name>`.
- **QAHook** gets new commands:
  - `flags cmd opt` / `flags none`: builds a flagsChanged event and calls `RadialRecentsController.shared?.qaIngest(_:)`, with the QA key-window override on.
  - `radial <deg> [dist=80]` / `radial center`: sets a fake pointer offset that replaces the polled one.
  - `open <relpath>`: calls `state.jump`.
  - `send()` passes each synthesized keyDown to the radial first.
  - The key map gains `23: "5"`.
- **Log lines** for scripts to check: `radial: arm|open n=|highlight i path|commit path|cancel reason`.

## 3. Feature B: tiling with ••• and pane launchers

### 3.1 Layout model

New file `Sources/Flamingo/Tiling.swift`. Everything except the two ObservableObjects is pure and unit-tested.

```swift
enum TileLayout: String, Codable, CaseIterable { case single, halves, thirds, mainPlusStack, grid
    var count: Int; var collapsed: TileLayout        // grid→mainPlusStack, mainPlusStack/thirds→halves, halves→single
    var title: String; var symbol: String              // menus, palette, .help only
    func frames(in size: CGSize, _ f: TileFractions) -> [CGRect]   // slot rects, 1pt hairline gaps
    func dividers(in size: CGSize, _ f: TileFractions) -> [TileDividerSpec] }
struct TileFractions: Codable, Equatable { var columns: [Double]; var rows: [Double]   // halves [.5]; thirds [1/3,2/3]; mainPlusStack [.6]/[.5]; grid [.5]/[.5]
    func clamped(_ layout: TileLayout, size: CGSize, minW: CGFloat = 220, minH: CGFloat = 160) -> TileFractions }  // equal shares if too narrow
struct TileArrangement: Codable, Equatable {
    var kind: TileLayout = .single
    var order: [DocumentPaneID] = DocumentPaneID.allCases          // visible = order.prefix(kind.count)
    func resized(to: TileLayout, keeping anchor: DocumentPaneID) -> (TileArrangement, revealed: [DocumentPaneID])
    func closing(_ id: DocumentPaneID) -> (TileArrangement, successor: DocumentPaneID)?
    func neighbor(of: DocumentPaneID, step: Int) -> DocumentPaneID }  // wraps over visible panes
@MainActor final class PaneTiling: ObservableObject { @Published private(set) var arrangement = TileArrangement(); let geometry = TileGeometry() }
@MainActor final class TileGeometry: ObservableObject { @Published var fractions: [TileLayout: TileFractions] }  // divider drags; saved in Defaults.tileFractions on drag end
```

**Rules:**
- **Growing** keeps visible panes in their slots and reveals `order[old..<new]`.
- **Shrinking** keeps the clicked pane plus the other visible panes in slot order, cut to the new count and re-sorted by original slot. Example: grid [P,S,T,F], shrink to halves from F → [P,F].
- **Closing** moves the pane to the end of `order` and uses `kind.collapsed`. Focus goes to the previous slot, or to the new slot 0 if slot 0 was closed.

### 3.2 AppState changes

**Panes.** `let allPanes: [DocumentPane]` (4 panes) and `func pane(_:)`. `primaryPane` and `secondaryPane` become computed aliases, so tests compile unchanged. `let tiling = PaneTiling()`. `splitVisible` becomes computed `tiling.arrangement.kind != .single`. `activePaneID` stays `@Published`.

**Selection.** It works exactly as today. `selected`, `anchor`, `jumpRequest` and `sourceHighlight` follow `pane(activePaneID)`; inactive panes keep their own place. A launcher pane that is active means `selected == nil`, so the inspector shows nothing, and `CurrentFileTitle` shows nothing when tiled with an empty active pane.

**Loops.** Replace the hard-coded `[primaryPane, secondaryPane]` loops with `allPanes`, hidden panes included because they keep content. Locations:
- AppState.swift:267, 325, 822, 836, 868, 998, 1122, 1235, 1499
- the check at 1324
- `activatePane`'s guard (1384) becomes `tiling.arrangement.visible.contains(id)`

**New file `Sources/Flamingo/AppState+Tiling.swift`:**
- `setLayout(_:from:)`, recorded for undo as "Change Layout". Revealed panes are `reset()` and the first one gets focus through `focusWhenReady`.
- `closePane(_:)`, which replaces `closeActivePane` and stops copying the remaining pane into primary.
- `focusPane(step:)`, behind `focusOtherPane`.
- `open(_:inPane:anchor:)`.
- `reveal(_:anchor:)`.
- `savedSplit()` and `restoreSplit(_:in:)`.

**Existing functions rewritten:**
- `openBeside` targets the first empty visible pane, otherwise the next visible pane, otherwise switches to halves.
- `toggleSplit` and `closeSplit` keep their current meaning.

**Access changes** (private → internal, for the new file): `synchronizingPane`, `suppressActionHistory`, `undoWorkspaceSnapshot`, `recordWorkspaceChange`, `releaseTab`, `synchronizeActivePane`. This keeps AppState.swift from growing.

**Persistence** (Workspace.swift). Older builds can still read new snapshots:

```swift
struct SavedSplitWorkspace: Codable {
    var visible: Bool; var activePane: DocumentPaneID          // always .primary/.secondary = active slot 0/1
    var primary: SavedDocumentPane; var secondary: SavedDocumentPane   // slots 0 and 1, so an old build shows what it can
    var tiles: SavedTiles? = nil }                             // authoritative when present; decoded with try?
struct SavedTiles: Codable { var layout: TileLayout; var order: [DocumentPaneID]; var active: DocumentPaneID; var panes: [SavedTilePane] }
struct SavedTilePane: Codable { var id: DocumentPaneID; var pane: SavedDocumentPane }
```

- **Legacy snapshot** (no `tiles`): primary → `.primary`, secondary → `.secondary`, `visible ? .halves : .single`, default order.
- **Undo:** `persistWorkspace` (806) and `undoWorkspaceSnapshot` (2309) both use `savedSplit()`, so undo covers layout, order and all 4 panes. Divider fractions are global and not undoable, the same as sidebar widths.

### 3.3 Views

**PreviewPane.swift:**
- `TileContainer` replaces the `HSplitView`: GeometryReader → `ZStack` → `ForEach(visible panes, id: \.id)` placed with `.frame` + `.position`, then `TileDividerHandle`s. It observes `tiling` and `geometry`.
- Frames snap to place; newly shown panes fade in over `Motion.normal`.
- `DocumentPaneColumn` header (36pt, tiled only): glyph and name on the left, ••• centered, ✕ on the right (shown on every pane when tiled, calls `closePane`). Accessibility label "Pane n of N".
- An empty pane shows `FolderSurface` when single and `PaneLauncher` when tiled.

**New file `Sources/Flamingo/TileChrome.swift`:**
- `TileHandle` (•••): `ellipsis` 13pt in `textSecondary`. Opacity 0.3 at rest, 0.75 when the pointer is in the pane, 1 on hover or while the popover is open. 32×20 hit area, `.help("Arrange Panes")`.
- `TileLayoutPicker`: `.popover(arrowEdge: .bottom)` like Inspector.swift:89. A row of 5 `TileDiagram` buttons, each 40×30 holding a 28×20 diagram: outline `Squircle(radius: Theme.Radius.s)` with 1pt `textTertiary`, tiles as `Squircle(radius: 2)`. The current layout is drawn in accent. The hover background is `Squircle(radius: Radius.s).fill(hover)`, as in FolderStyleToggle. No text; ←/→ and Return via `.onKeyPress`.
- `TileDividerHandle`: like `ResizeHandle` (PanelLayout.swift:26). A 9pt invisible grip on the hairline, resize cursor, accent line at 0.6 while dragging, double-click resets. Clamped by `TileFractions.clamped`; saved on drag end. Exposed to accessibility as an adjustable element.

**Other view edits:**
- DocumentSurface.swift: in single mode, ••• goes in the center of the breadcrumb row.
- RootView.swift: remove the split button; a small subview observing `tiling` decides when `FolderStyleToggle` shows.
- WorkspaceBar.swift: clicking a tab calls `reveal`. Files showing in a non-active pane get a 1.5pt underline in `textTertiary` (accent stays for the active pane only). Add a context-menu item "Open in Empty Pane" when a launcher exists.

### 3.4 Pane launcher

New file `Sources/Flamingo/PaneLauncher.swift`.

**Layout:**
- A `CommandField(autofocus: false)` row, 28pt, `Squircle(radius: Radius.m-2)` fill and focus ring. No placeholder.
- A hairline, then up to `floor(height/26)` rows (at most 8) using `.flamingoRow`: `FileGlyph`, name, folder in `textTertiary` truncated at the start, and at the right up to 2 reason glyphs from `ConnectionReason.symbol` (ConnectionsTab.swift:8) with `.help(phrase)`. Picks chosen only by recency show no glyph.
- The first row is preselected, so Return opens the best guess. No empty-state text.

**`LauncherState`** (one per pane, held by `PaneLauncherModel`) handles typing:
1. Right away: fuzzy names through a shared `FileTableCache`, the palette logic from Palette.swift:271-289 moved into Fuzzy.swift.
2. After 120ms: `unifiedSearch(q)`.
3. After 550ms: `unifiedSearch(q, includeSemantic: true)`, keeping the current selection (as Palette.swift:319-343 does).

Keys: ↑↓ move, Return calls `state.open(file, inPane: id)`, Esc clears the query or else hands focus back to the previous pane, ⌘W closes the pane.

**`PaneLauncherModel`** (shared) works out the picks:
1. **Seeds:** files in visible panes, weight 1.0 for the active one and 0.8 for the others.
2. **Evidence:** a new `VaultSession.paneEvidence(for seeds: [FileRef], edges: [Graph.Edge]) async throws -> [FileRef: FileConnectionsSnapshot]`. It runs one detached task doing `relatedFiles` + `similarFiles(limit: 12)` + `trail.edges()` + `FileConnections.merge` with no excerpts.
3. **Ranking:** `PaneSuggestions.rank(seeds:evidence:recents:exclude:launchers:block: 8) -> [[Pick]]`, pure. Score = Σ seedWeight·strength + 0.3·(recency score ÷ top recency score). Files already showing are excluded.
4. **Sharing between launchers:** in slot order, launcher k gets ranked[8k ..< 8k+8]. If there aren't enough, the rest is filled from recents.
5. **Refresh:** only when the layout, a pane's file or `connectionsRevision` changes, debounced 150ms, keeping the old list on screen until the new one is ready. Trail ticks don't trigger it, so lists don't jump under the pointer.

### 3.5 Menus and palette (MainMenu.swift)

- View → **Layout** submenu: 5 items, ⌃⌥⌘1–5, current one checked.
- "Focus Next Pane" ⌥⌘→ and "Focus Previous Pane" ⌥⌘←.
- Validation: layouts need a vault; focus items need a tiled layout.
- Palette: "Layout: …" ×5 and Focus Next/Previous. The id `focus-other-pane` stays.

## 4. Milestones

| # | Work | Done when |
|---|---|---|
| M0 | Commit the current tree; branch | — |
| M1 | `TrailRecents` and `RecentFilesModel`, with tests | rank tests green; refresh happens off the main thread |
| M2 | Radial: machine, controller, overlay, Go → Recent Files, QAHook commands, `scripts/qa-post.swift`; `reveal()` written against the 2-pane model | machine tests green; QA steps A1–A8 |
| M3 | N-pane model with no UI change: pane IDs, `Tiling.swift`, `AppState+Tiling.swift`, snapshot v2 | **all 11 SplitWorkspaceTests unchanged and green**, plus new model and snapshot tests |
| M4 | Tile container, dividers, header with ••• and ✕, picker, menus and keys, TopBar cleanup, tab-strip marker | QA steps B1–B6; screenshots in light and dark at 1000×600 and full screen |
| M5 | Launcher: `FileTableCache`, `CommandField(autofocus:)`, `PaneLauncher`, `paneEvidence`, `PaneSuggestions` | suggestion tests green; QA steps B7–B10 |
| M6 | DESIGN.md, CONTRACT.md keyboard rows, HANDOVER.md, ISSUES; check the lag monitor log | `make test` green |

M1–M2 and M3 touch separate files and can run in parallel. The only thing they share is `reveal()`.

## 5. Tests

**`Tests/FlamingoTrailTests/TrailRecentsTests.swift`**
- One open 10 minutes ago beats 5 opens 6 days ago.
- saved > commented > opened at equal times.
- 30 opens within 10 minutes score like 1 open.
- `.searched` events, events with no file, and `.flamingo/` paths are ignored.
- `lastAnchor` is the latest event that has an anchor; `lastEdited` comes from saved or commented.
- Events older than the window are dropped; `limit` is respected; ties break by path; unsorted input works.
- 100k events rank in under 0.2s.

**`Tests/FlamingoAppTests/RecentFilesModelTests.swift`**
- A deleted file disappears after refresh.
- Bumping mtime after an open sets `edited`.
- With an empty trail, the fallback order is openFiles then history, with no times.
- The notification from a temporary capture store is ignored; the session's own store triggers one refresh.

**`Tests/FlamingoAppTests/RadialHoldMachineTests.swift`**
- Arms only on an exact ⌘⌥ reached from fewer modifiers; never from ⌘⌥⇧ → ⌘⌥, and never with a mouse button down.
- keyDown, mouseDown, scroll or an added modifier before the delay cancels and passes the event through.
- `tick` after 300ms opens.
- Offsets map to slots in both 4- and 8-slot modes; dead zone gives nil; hysteresis holds at 22.5° ± 3°.
- Releasing in a slot commits; releasing in the dead zone closes; Esc is consumed; other keys close and pass through; mouseDown while open closes and passes through.

**`Tests/FlamingoAppTests/TileLayoutTests.swift`**
- Frames at 1000×600 for all 5 layouts: right count, no overlap, gaps of 1pt.
- Clamping respects minimum sizes; a narrow width falls back to equal shares.
- Grow and shrink rules, including the grid shrink-from-F example.
- The collapse map and the successor after close.
- Neighbour cycling wraps.

**`Tests/FlamingoAppTests/TiledWorkspaceTests.swift`**
- `testLegacySnapshotDecodesWithoutSplitState` still passes.
- A legacy `split` with no `tiles` restores to halves.
- A snapshot whose active pane is `.third` writes `activePane == .primary` (slot mapping), and a copy of the legacy struct declared in the test can decode it.
- `setLayout(.thirds)` from single gives 2 empty revealed panes, with the first launcher active.
- Undo and redo of a layout change bring back the file and anchor.
- Closing the middle of thirds gives halves, with focus on the previous slot.
- `open(_:inPane:)` leaves the other panes alone.
- Rename and trash update the third and fourth panes, hidden ones included.
- `reveal` focuses the pane that already shows the file.

**`Tests/FlamingoAppTests/PaneSuggestionsTests.swift`**
- explicit > similar > together > recency.
- Scores from several seeds add up.
- Files already showing are excluded.
- Launcher blocks don't overlap; with no seeds, picks come from recents.

## 6. Headless QA script

**Setup.** Add `scripts/qa-post.swift`, compiled to `build/qa-post` like `window-id`. It posts `DistributedNotificationCenter.default().postNotificationName(name, object: cmd, deliverImmediately: true)`. Then:

```
SCR=<scratchpad>; CH=com.flamingo.qa.$$
cp -R build/Flamingo.app $SCR/FlamingoQA.app; cp -R fixtures/vault $SCR/vault
FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=$CH FLAMINGO_SLOWMO=6 $SCR/FlamingoQA.app/Contents/MacOS/Flamingo \
  -lastVault $SCR/vault -FlamingoAppearance dark > $SCR/qa.log 2>&1 &
Q(){ build/qa-post $CH "$*"; sleep ${W:-0.5}; }; shot(){ screencapture -o -x -l $(build/window-id --pid $PID Flamingo) $SCR/$1.png; }
```

**Radial**
1. **A1.** `Q open` 5 fixture files, 1.2s apart, so the trail records them.
2. **A2.** `Q flags cmd opt`, wait 0.8s, `shot radial-open`. Expect 8 or 4 tiles and an empty hub; the log has `radial: open`.
3. **A3.** `Q radial 90`, `shot radial-hl`. Expect a ring on the right tile and the hub filled.
4. **A4.** `Q flags none`. The log has `commit <path>`; `shot` shows that file's title.
5. **A5.** `Q flags cmd opt`, immediately `Q key 34 cmd opt` (⌥⌘I). Expect `cancel key` and the inspector toggled, with no ring in the screenshot.
6. **A6.** Open, then `Q key 53`, then `Q flags none`. The title doesn't change.
7. **A7.** Open, then `Q radial center`, then `Q flags none`. The title doesn't change.
8. **A8.** Relaunch with `light` and repeat A2–A3. Check that `main: worst lag` stays under 50ms.

**Tiling**
1. **B1.** `Q open decks/…`, then `Q menu Three Columns`, `shot`. Expect three panes, launchers in panes 2 and 3, and different picks in each; the log has `launcher: picks`.
2. **B2.** `Q launch 2 #0`. Pane 2 opens the top pick, and pane 3's picks update.
3. **B3.** `Q launch 3 q3`, `shot`. Fuzzy results show right away; a second log line shows the semantic results.
4. **B4.** `Q key 124 cmd opt` three times. The active underline moves around the panes and wraps.
5. **B5.** `Q key 13 cmd` (⌘W) on the middle pane, `shot`. Expect halves.
6. **B6.** `Q menu Undo`. Expect thirds back.
7. **B7.** `Q menu Four`, then `Q menu One and Two`, `shot` each.
8. **B8.** Quit and relaunch. The layout, panes and active pane come back.
9. **B9.** Legacy: before launch, `defaults write com.flamingo.app workspace.$SCR/vault -data <legacy JSON hex>`. Expect halves.
10. **B10.** Run the layouts at 1000×600 and full screen, in light and dark.

**Manual only** (drags can't be scripted): drag and double-click dividers, open the ••• popover with the mouse, check haptics on a Force Touch trackpad.

New QAHook commands for this part: `tile <layout>`, `pane <slot>`, `launch <slot> <query|#n>`.

**Caution:** the QA copy shares the real app's `com.flamingo.app` preferences. Workspace keys are per vault path, so a scratch vault is safe. The global keys `tileFractions`, `radialHoldDelay` and `trailEnabled` are not: read them before QA and write them back after.

## 7. Documentation

**DESIGN.md**, added to "Layout":

> *Recent files.* Hold ⌘⌥ for a moment: up to eight recent files form a ring around the pointer on a squircle plate; flick toward one, let go to open it. Nothing highlighted, nothing opens. The hub names the file, its folder and when you last touched it. A dot marks files you edited. Never labelled.
>
> *Panes.* Up to four documents tile the content: one, halves, thirds, one and two, four. ••• at the top center of a pane (dim until the pointer is in that pane) offers them as small squircle diagrams. A new tile is a launcher: a field with no placeholder, then the files most related to what's already on screen. Tiles meet at hairlines and resize by dragging them. One tab strip serves all panes; the active pane's tab has the accent underline, other visible ones a tertiary one.

**CONTRACT.md** keyboard map, new rows:
- ⌘⌥ (hold): recent files
- ⌘\ : split view
- ⌃⌥⌘1–5: layouts
- ⌥⌘→ / ⌥⌘←: next / previous pane

**HANDOVER.md:** short entries for both features.

## 8. Risks

1. **⌘⌥ held while looking for a key** (⌥⌘I, ⌥⌘N, ⌥⌘L) briefly shows the ring. The shortcut still fires because keys pass through. If testing shows this is common, raise the 0.30s delay toward 0.35s (it's a preference).
2. **Synthesized events skip monitors.** QA has to use `qaIngest`. Real ⌘⌥ handling can only be confirmed by hand on a key window.
3. **Container structure.** Pane views only stay mounted if the container never branches on layout. Keep a single `ForEach`.
4. **Loss of NSSplitView accessibility.** Removing it drops the built-in splitter behaviour, so the custom dividers need adjustable actions.
5. **Snapshot compatibility.** Legacy fields must only ever hold legacy-valid values, and `tiles` must be decoded with `try?` so a future layout value can't wipe the workspace.
6. **Launcher cost on a whole-home vault.** `relatedFiles` and `trail.edges()` run per refresh: detached, debounced, and only while launchers exist. Without embeddings, picks fall back to links, trail and recency.
7. **Outside-edit detection.** Cloud sync tools change mtimes and could falsely mark files as edited. This only applies to files you opened in the last 30 days, so the effect is small.
8. **Focus conflicts.** Several launchers will fight over focus unless `CommandField(autofocus: false)` is used and focus goes through `pane.requestFocus`.
9. **Haptics.** They do nothing without a Force Touch trackpad; that's acceptable.

### Critical Files for Implementation
- Sources/Flamingo/AppState.swift
- Sources/Flamingo/PreviewPane.swift
- Sources/Flamingo/Workspace.swift
- Sources/FlamingoTrail/Trail.swift
- Sources/Flamingo/QAHook.swift