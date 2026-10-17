# Flamingo — Handover

Flamingo is Obsidian for every file on a Mac. Native SwiftUI, zero dependencies. Open a folder
(or `~`), preview anything with Quick Look, press ⌘⇧C to leave a thought on the slide, page,
cell or moment you're looking at, link thoughts with `[[wikilinks]]`, and see a graph of how the
files connect. It never writes into user files; everything lives in `<vault>/.flamingo/`.

Read in this order: `CONTRACT.md` (rules, module map, on-disk formats, keyboard map),
`DESIGN.md` (aesthetic rules; no labels, no copy, one accent), then this file.

## Build and run

```
make run        # builds a .app with scripts/run.sh and launches it
make test       # all suites; ~690 tests, all green at handover
make demo       # launches on fixtures/vault, a fake company with real pptx/docx/xlsx/pdf/usdz
```

Plain `swift build` fails: the Command Line Tools SDK lacks the SwiftUI macro plugin. The
scripts set `DEVELOPER_DIR` to Xcode-beta via `scripts/env.sh`. Always use the scripts.

Index CLI for checking things without the app:
```
.build/debug/flamingo-index <vault>                 # reindex, prints counts
.build/debug/flamingo-index <vault> --search "q"    # hits with anchors
.build/debug/flamingo-index <vault> --graph         # rebuilds .flamingo/graph.json
```

## Layout

| Module | What |
|---|---|
| `Sources/Flamingo` | The app: window, sidebar (pinned folders, lazy tree), preview, modes, palette (⌘K), search (⌘F), history, swipe navigation, wiring of everything |
| `FlamingoCore` | `Vault`, `FileRef`, `FileAnchor`, `Comment`, sidecar read/write, wikilinks, `Graph`, scanner with `.flamingo/ignore`, file identity via xattr |
| `FlamingoCapture` | ⌘⇧C panel, `[[` completion, comments rail, global hotkey (⌃⌥Space or ⌃⌥⌘Space), frontmost-app anchors via AppleScript/AX |
| `FlamingoExtract` | pptx/docx/xlsx parsed natively (unzip + XMLParser), PDFKit, Vision OCR, AVFoundation, ModelIO for 3D, Spotlight fallback, thumbnails |
| `FlamingoIndex` | SQLite FTS5 index, FSEvents watcher, hybrid keyword + meaning search (Int8 vectors in memory, `VectorIndex.swift`; see `docs/SEMANTIC-SEARCH-2026-10-16.md`), file similarity, connections model (`FileConnections.swift`), graph builder, mention discovery |
| `FlamingoGraph` | Force-directed Canvas graph, folder scoping, hollow folder nodes, click/double-click, filter |
| `FlamingoTrail` | Session recording (`trail.jsonl`), clustering into sessions, timeline view, trail edges |
| `FlamingoAsk` | Retrieval + Claude, Ollama or local llama-server with citations; `ChatPanel` is the inspector's chat |
| `FlamingoDesign` | `Theme` tokens and components. Never hardcode a color, font or spacing |

State on disk, all under `<vault>/.flamingo/`: `notes/<path>.md` sidecars (Obsidian-compatible),
`index.sqlite`, `graph.json`, `graph-layout.json`, `trail.jsonl`, `pins.json`, `ignore`.

## Connections: one pair, many reasons

`FlamingoIndex/FileConnections.swift` is the model. A pair of files is one `FileConnection`;
each reason is `ConnectionEvidence`:

| Reason | Source | Explicit? | Graph |
|---|---|---|---|
| `yours` | `.flamingo/connections.json` (`ConnectionStore`): ⌥-drag in Graph, + in the inspector, accepting a suggestion | yes | solid |
| `linked` | `[[wikilinks]]` in thoughts and Markdown, either direction (`relatedFiles`) | yes | solid |
| `version` | byte-identical copy or likely version (`fileFamily`, read second because it reads files) | no | — |
| `mentioned` | a file's text names another (`Mentions.swift`), excerpt via `mentionExcerpt` | no | dashed |
| `similar` | embeddings nearest neighbours (`similarFiles`, `similarPairs` → `.related` edges) | no | dashed |
| `together` | same Trail sessions | no | dashed |

Folder containment (`.folder` edges) is structure: faint, never listed. `GraphTopology` merges
every edge of a pair into one, drawn as its strongest kind (`Edge.precedence`). Dismissed
suggestions live in `.flamingo/connections-dismissed.json` (`DismissedConnectionStore`) and are
filtered from the inspector, Wander and the graph; a dismissal never hides an explicit link.

## How work was organised

Twelve plans in `plans/`, each owned one directory, built in parallel by separate agents.
Cross-agent asks go in `plans/REQUESTS.md` (append-only, tick when done). QA findings are in
`ISSUES.md`. The plans are still the best description of intent per module; if something looks
half-done, its plan says what "done" was supposed to mean.

## State at handover (2026-10-16)

The 2026-10-15/16 Codex pass (uncommitted, see `docs/`) added a lot of function with a lot of
chrome. The 2026-10-16 pass kept the function and rebuilt the surface to DESIGN.md:

- Right sidebar is the inspector (`Inspector.swift`): Thoughts (rail + inline composer),
  Connections (`ConnectionsTab.swift`: local graph, explicit, hairline, suggestions with ✓/×),
  Outline (slides/pages/headings), Chat (`FlamingoAsk/ChatPanel.swift`). ⌘4 opens Chat from any
  view; `FlamingoMode.ask` redirects there. ⌃⌘1–3 open the other tabs. Both sidebars and the
  local graph resize by dragging; widths live in `PanelLayout`, not `AppState`.
- Removed: status bar (indexing is an accent hairline, problems are a toolbar warning icon),
  `RelatedFilesPanel`, graph toolbar/inspector/+++/---, red segmented controls, explanatory copy
  in Ask, palette, folder page, trail, inbox, health, new-file sheet.
- Semantic search rebuilt (qwen3-embedding via Ollama, Apple on-device fallback): palette
  recall@5 0.33 → 0.99 on a bilingual benchmark, 5 ms queries at 500k passages.
- Lag pass (`docs/PERF-AUDIT-2026-10-16.md`): FTS compaction after indexing, `+rowid` in FTS
  queries, mmap'd readers, cached link resolution and name index, graph rebuilt only while
  something shows it (Graph mode, Connections tab, Wander), graph compared by fingerprint and
  revision instead of `==`, palette keeps results while typing, per-frame graph fade cached,
  chat tokens rendered at ≤30 Hz, anchor-driven workspace saves debounced. On a 35k-file
  vault ⌘K went from ~1.3 s to ~0.37 s per query and the graph build from 18 s to 2 s.
- Opening a vault no longer walks every file (another session, same day): `index.sqlite` meta
  keeps an FSEvents checkpoint (`ScanCheckpoint.swift`); launch replays changes since it
  (`VaultWatcher.start(since:)`) and re-reads stale rows (`VaultSession.refreshStale`). A full
  walk runs only with no checkpoint, lost root events, changed ignore rules, or a walk older
  than 7 days. Packages are stamped by contents; unchanged re-extractions keep model titles;
  OCR has a 90 s watchdog. Schema is v8; a future bump is v9.
- Every rounded shape is a continuous-curvature squircle (`FlamingoDesign/Squircle.swift`):
  cubic Béziers only, zero curvature at the edges, peak at the 45° apex, nested shapes as
  true normal offsets (`ConcentricSquircle`). Never use `RoundedRectangle` or `cornerRadius`.
- Fun: Wander (dice in Connections), graph Replay History (right-click or palette), Resurface a
  Thought, ⌥-drag to connect with haptics, Quick Look thumbnails on the folder page, drop a file
  on the chat to ask about it.

- Finder column view (2026-10-16, `ColumnBrowser.swift`, `ColumnPreview.swift`,
  `FinderFavorites.swift`): with no file open the folder surface is Finder's columns (default) or
  its icons, ⌥⌘1/⌥⌘3 or the toolbar toggle. Finder's own Favorites (read from
  `~/Library/Application Support/com.apple.sharedfilelist/…FavoriteItems.sfl4`, never written)
  sit above the file tree with Finder's glyphs, and work outside the vault (/Applications).
  `AppState.browser` holds the place: it follows the sidebar folder only when that changes,
  keeps the column selection when the folder is already inside the columns, and history
  entries carry a `place` for folders outside the vault. Opening a vault file shows it here;
  apps and outside files open as Finder would. Go menu has Finder's keys. The ribbon's second
  button (and ⌥⌘3) shows the open file's folder in columns with the file selected; again goes back.
- ⌘W closes one tab and never the window; closing the window only hides it
  (`applicationShouldTerminateAfterLastWindowClosed` is false); only ⌘Q quits.
- Chat (same day): a ranking prior that pushes package/build/tool files down
  (`FlamingoAsk/SourcePrior.swift`), the open file, folder and last week's opened files as
  context (`AskContext`), follow-ups only borrow the last question when they need it, a 5k local
  budget. "Claude" with no API key uses the installed Claude Code (`ClaudeCodeClient`);
  Automatic stays local unless a Flamingo API key is set.
- Calmer graph (same day): mentions skip machine listings and keep the strongest 20 per source,
  5 per file; dashed suggestions draw only for the selected or hovered node; selection dims
  the rest; labels fade in by degree; clicks in the graph don't re-scope it; the local graph
  shows 12 neighbours. Not done: defaulting to a focus graph around the selection.
- Saving a thought rewards (same day): `ThoughtStrength` (Core) grades the text (spark, solid,
  woven); `Chime` (Design) is three synthesized mallet notes plus trackpad taps, respecting
  "Play user interface sound effects". `AppState.celebrate` shows the new link: in Graph,
  `GraphModel.celebrate` settles the camera on the pair and draws the line in the strength's
  tint (`Theme.Color.thought`); elsewhere `ConnectionPiP` (FlamingoGraph) floats a small
  graph top right, window or screen, never key. ⌥-drag connections celebrate too. QA:
  `FLAMINGO_SLOWMO=6`, `FLAMINGO_PIP_IN_WINDOW=1`, `FLAMINGO_QA_CHANNEL`, and QAHook's `menu <title>` and `thought <text>`. The capture
  panel's footer shows the target's glyph and the glyphs of files linked so far.

Nothing is committed. A tarball of the tree before the 2026-10-16 pass was kept in that
session's scratchpad only; commit before the next big change.

**Open, in priority order**

1. Copies and versions show in Connections but not yet as graph edges (the family check reads
   files, so it runs per selection, not vault-wide).
2. Remaining lag items from the audit (U3, U6, U8, U9, U11 partly): move the vault open off
   main before first paint, sidecar writes and rename reconcile off main, one cached
   `Wikilink.Resolver` per file list, `[[` completion matcher per file list.
3. `AppState` is one 2,000-line `ObservableObject`; any `@Published` change re-renders every view
   reading it. Split per concern (selection, comments, graph) as profiling demands.
4. pptx anchors drift from the Quick Look preview (ISSUES.md).
5. Remaining items in `ISSUES.md` and `plans/REQUESTS.md`.

## Conventions that matter

- Public API in Core is frozen for everyone else's sake: add, never rename.
- Keep `make test` green. Commit small. The only files no one should edit casually are
  `Package.swift` and `CONTRACT.md`.
- Before any view: DESIGN.md. If a label can be removed, remove it. No placeholder text, no emoji.
- User's hardware: M5 Pro, 64 GB. Ollama has gemma3:4b, llama3.2:1b, qwen2.5:1.5b.
