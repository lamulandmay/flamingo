# Plan 11 — Whole-Mac index and pinned sidebar

**You own:** `Sources/FlamingoCore/`, `Sources/Flamingo/`, `Tests/FlamingoCoreTests/`.
**Read first:** `CONTRACT.md`, `DESIGN.md`, `ISSUES.md`. Frozen API rules still apply: add, never rename.
Plan 12 is working in `FlamingoAsk` and `FlamingoIndex` at the same time; don't touch those.

## Mission
The vault is the user's whole Mac, hidden folders included. The sidebar shows only the folders
the user pins. Everything else is reachable by ⌘K and search.

## Milestones
### M1 — Scanner handles a whole disk
- Drop `.skipsHiddenFiles`. Hidden files and dot-folders are indexed.
- Default exclusions, editable in `<vault>/.flamingo/ignore` (gitignore syntax, one per line,
  written with defaults on first run): `.flamingo`, `.git`, `.build`, `node_modules`, `.Trash`,
  `.cache`, `.npm`, `.cargo/registry`, `Library/Caches`, `Library/Containers`, `Library/Developer`,
  `Library/Application Support/Google`, `*.photoslibrary`, `*.app`, `.ollama`, `.docker`,
  `Downloads/*.dmg`. Packages are still single files. Symlinks never followed.
- Files over 50 MB get metadata only (name, ext, size), no extraction. Expose `VaultScanner.limits`.
- `VaultScanner.files(in:)` streams (`AsyncSequence` or callback) so a million files don't sit in
  an array before the first one is indexed. Keep the old array API working.
- Tree is lazy: `VaultScanner.children(of folder:)`, never a whole-disk tree.

### M2 — Pins
- `Pins` in `.flamingo/pins.json`: an ordered list of relative folder paths. API in Core.
- Sidebar shows pinned folders as top-level roots, expandable lazily via `children(of:)`.
  Reorder by drag. Unpin via right-click or ⌫ with no confirmation and an undo toast.
- Pin via: palette "Pin Folder…" (NSOpenPanel), drag a folder onto the sidebar, right-click a
  folder anywhere in the tree. First run with an empty pins list pins Desktop, Documents, Downloads.
- ⌘O now means "Open Vault" (choose root). Default root on first launch is `~`. Offer `/` in the
  panel; warn nothing, just index it. Store root in UserDefaults as today.

### M3 — Indexing at scale without hurting the UI
- Reindex runs at `.utility` QoS, commits every 200 files, and the progress hairline shows
  files/sec in the palette's status line (not on screen). Cancel on vault change.
- Watcher ignores paths matching the ignore file. Coalesce 2 s.
- First-run over `~` on this Mac must finish without the app stuttering. Measure and write the
  numbers into `ISSUES.md`.
- Full Disk Access: if `~/Library/Mail` or `~/Library/Messages` is unreadable, add one palette
  command "Grant Full Disk Access" that opens the System Settings pane. No banner.

## Done means
Root `~`, hidden folders indexed, Desktop/Documents/Downloads pinned by default, pin any folder
from the palette, ⌘K finds a file in `~/.config`, the app stays smooth during first index.

## M4 — Ribbon, status bar, graph scope (added 2026-10-15)
- **Ribbon.** A 40pt icon strip on the far left, like Obsidian's: Files, Search, Graph, Trail,
  Ask at the top; Pin Folder, Settings at the bottom. Monochrome SF Symbols, accent when
  active, tooltips only. Clicking Graph/Trail/Ask switches mode (same as ⌘1–4); Files toggles
  the sidebar. The sidebar material extends behind it.
- **Status bar.** One 22pt hairline-topped strip at the bottom, tertiary 11pt: backlink count
  for the selected file (from `IndexStore.backlinks`), comment count, current anchor, and
  index progress while indexing. Nothing else. No labels, numbers with one-word nouns.
- **Graph scope.** The graph follows the sidebar: when a pinned folder or subfolder is
  selected, show only files under it plus their direct neighbours outside it drawn dimmed.
  A segmented control in the graph's filter row switches `folder | vault`. The selected file
  is always highlighted (fixed in FlamingoGraph on 2026-10-15; pass `selected:` through).
