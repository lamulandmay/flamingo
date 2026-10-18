# Flamingo — Handover

Flamingo is Obsidian for every file on a Mac. Native SwiftUI, no dependencies beyond a bundled 7-Zip for archives. Open a folder
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
  Sort By (2026-10-18, `ColumnSort.swift`) is in every column's context menu, on items and on
  the empty space: Finder's keys (Name, Kind, Application, Date Last Opened/Added/Modified/
  Created, Size, Tags) and which way. One order for every column, kept in `Defaults.columnSort`.
  Missing values (a folder's size, a date Spotlight never saw) go last; "Keep folders on top"
  counts only for Name, as in Finder; a package's size and Date Last Opened come from Spotlight.
- ⌘W closes one tab and never the window; closing the window only hides it
  (`applicationShouldTerminateAfterLastWindowClosed` is false); only ⌘Q quits.
- Chat (same day): a ranking prior that pushes package/build/tool files down
  (`FlamingoAsk/SourcePrior.swift`), the open file, folder and last week's opened files as
  context (`AskContext`), follow-ups only borrow the last question when they need it, a 5k local
  budget. "Claude" with no API key uses the installed Claude Code (`ClaudeCodeClient`);
  Automatic stays local unless a Flamingo API key is set.
- Settings (2026-10-17): Flamingo ▸ Settings… (⌘,, also in the palette) is a Finder-style
  window (`SettingsWindow.swift`) with General, Chat, Thoughts, Capture and Index panes. The
  Chat pane is `FlamingoAsk/AskSettings.swift`: provider, the Anthropic key (checked with a
  free `GET /v1/models` before it goes into the Keychain item `com.flamingo.anthropic`), the
  Claude model (`FlamingoClaudeModel`, Sonnet 5.5 by default), the local model folder and
  the Ollama model. Index edits `.flamingo/ignore` in place; saving rescans. Thought models
  are Ollama names only; nothing in Settings can send thoughts off the Mac. Only the app
  (bundle id `com.flamingo.app`, not under XCTest) touches that Keychain item
  (`KeyStore.keychainEnabled`): the item trusts the app that saved it, so tests and QA copies
  would raise an access prompt on the user's screen. They use `ANTHROPIC_API_KEY`.
- Keyboard shortcuts (2026-10-18): Help ▸ Keyboard Shortcuts (⌘/, also in the palette) is a
  searchable window (`ShortcutsWindow.swift`) over `ShortcutCatalog` (`Shortcuts.swift`): a
  "Start Here" primer, then every menu key and every key a focused view takes (graph, columns,
  inbox, connect mode, trail, wander, chat). `ShortcutCatalogTests` fails when a menu item's
  key isn't in the catalog, so add the line when you add a key. View-only keys aren't checked:
  update the catalog by hand when you change one.
- Archives (2026-10-18, `Unarchive.swift`): double-click or ↩ on a zip, rar, 7z, tarball, gz,
  cab... in the columns, tiles, explorer or search results expands it beside itself, as Finder
  does. One item out keeps its name; several go in a folder named for the archive; nothing is
  overwritten ("name 2"); quarantine carries over; an encrypted one asks for its password in a
  sheet. If the columns are still on the archive, what came out is selected; otherwise a toast
  offers Show. ⌘↩ still opens the archive in its default app. Zips go through ditto, tarballs
  through /usr/bin/bsdtar, the rest (and whatever those fail on) through 7-Zip, vendored
  unmodified at `Vendor/7-Zip/7zz` (LGPL; see its README) and bundled as
  `Contents/Helpers/7zz`. It is the app's one bundled tool. QA: the `dclick x y` verb. Typing
  into a secure field from the QA hook sends key code 0, so only an "aaa..." password works there.
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

## Pane tiling (plan 14, feature B)

- Four `DocumentPane`s live on `AppState` (`allPanes`); `tiling.arrangement` (layout + slot order)
  says which show. `AppState+Tiling.swift` has layouts, close, focus, open-in-pane, snapshots.
  `primaryPane`/`secondaryPane` are aliases for slots held by ids `.primary`/`.secondary`.
- Snapshots: legacy `primary`/`secondary` hold slots 0 and 1; `tiles` (optional, `try?`-decoded) wins.
- `PreviewPane.swift` is one container with one `ForEach` over visible panes, keyed by id: never
  branch the view tree on layout or panes remount. Chrome is in `TileChrome.swift`; launchers in
  `PaneLauncher.swift` (+ pure `PaneSuggestions.swift`, `VaultSession.paneEvidence`).
- QA: `scripts/tiles-qa.sh <scratch> [dark|light]`; QAHook verbs `tile`, `pane`, `launch`,
  `window`, `workspace undo|redo`. Divider drags and the ••• popover need a mouse.

## Conventions that matter

- Public API in Core is frozen for everyone else's sake: add, never rename.
- Keep `make test` green. Commit small. The only files no one should edit casually are
  `Package.swift` and `CONTRACT.md`.
- Before any view: DESIGN.md. If a label can be removed, remove it. No placeholder text, no emoji.
- User's hardware: M5 Pro, 64 GB. Ollama has gemma3:4b, llama3.2:1b, qwen2.5:1.5b.

## 2026-10-17 program: ring, tiles, thoughts v2, night shift, morning inbox

Plan: `plans/00-program-2026-10-17.md`. All merged on `feature/integration`.

**What exists and the keys**
- Radial recents: hold exactly ⌘⌥ for 0.3 s, a ring of up to 8 recent files (4 big compass slots with 4 or fewer) opens at the pointer; move to pick, release to open, Esc cancels, any other key closes it. `RadialRecents.swift`, `RadialRecentsView.swift`, `AppState+Recents.swift`. It never opens while the briefing is up.
- ••• N-pane tiles: up to 4 `DocumentPane`s, layouts (halves, thirds, grid), a launcher in an empty pane. `AppState+Tiling.swift`, `Tiling.swift`, `PreviewPane.swift` (one `ForEach`, never branch on layout), `TileChrome.swift`, `PaneLauncher.swift`, `PaneSuggestions.swift`.
- Thoughts v2: every thought has a `uid`, a kind (idea, question, todo, intent), a state (open, done, snoozed, dismissed), threads (replies via `parent`), web and folder notes, `[[file#^uid]]` links. Core: `ThoughtMeta`, `ThoughtRules`, `ThoughtUID`, `ThoughtAction`, `WebThought`. Rail: `CommentsRail`, `RailThreads`, `ThoughtsTab`. Links in the rail show the file name (or alias, or `name › anchor`); the stored text keeps the path.
- Recall and echo: semantic recall of earlier thoughts (`ThoughtSearch`, `ThoughtEcho`).
- Understanding: 2 s after a save a local model labels a thought (kind, and an intent with objects). `ThoughtReader` skips replies, AI thoughts, `@ai`/`@flamingo` asks, finished and person-decided thoughts. Replies keep the rules' kind.
- `@ai` / `@flamingo`: a local answer streams into the rail and is saved as an AI reply (`ThoughtAsk`).
- Night shift: overnight, local only, `FlamingoThoughts` (`NightShiftPlanner/Runner/Scheduler/Service`) plus recipes in `FlamingoAsk/WorkRecipes.swift` (review-conflict, compare-versions, summarize, answer, find-related). Memos land in `.flamingo/work/<day>/*.md`; the thought gets an AI reply with `work`. Memos reject invented quotes (`WorkOutput.validate`, alphanumerics only).
- Morning inbox ("briefing"): the first open of the day zooms the window and shows memo cards, the thoughts to address first, what needs attention and where you left off. Keys: j/k or arrows, Return opens (a memo card opens the MemoReader), e done, s snooze, r reply, a attach, backspace dismiss, Cmd-Z undo, Esc leaves. `BriefingView.swift`, `BriefingRows.swift`, `MemoCard.swift`, `MemoReader.swift`, `AppState+Briefing.swift`, `BriefingWorkflow.swift`, model in `FlamingoThoughts/Briefing*.swift`, `AttentionRanker`.

**QA scripts** (each needs `scripts/bundle.sh debug`, runs a copy under its own bundle id and QA channel, kills only its own pid): `scripts/radial-qa.sh`, `tiles-qa.sh`, `thoughts-qa.sh`, `briefing-qa.sh` (+ `briefing-seed.sh`), `headline-qa.sh <scratch> [dark|light]` for the whole evening thought, night memo, morning inbox scenario with `FLAMINGO_FAKE_LLM=1` (fixtures in `fixtures/fake-llm`). QAHook verbs: `clock <ISO>|reset`, `open path#anchor`, `thought`, `reply`, `ai`, `nightshift now|plan`, `briefing [zoom|reset|close|key|select|reply|attach|status]`, `tile`, `pane`, `launch`, `radial`.

**Privacy rule.** Thoughts never leave this Mac. Thought AI uses only the local engines (`completeLocally`/`LocalEndpoint`, `askStreamingLocally`, `ThoughtReader`, `engine.work`, `NightShiftService`). No `@claude`, no Claude or cloud in any thought path. `LocalOnlyTests` and `NightShiftLocalOnlyTests` guard it; do not weaken them.

**Known issues.** See `ISSUES.md`, "2026-10-17 program". The fake review-conflict canned reply can only answer the deck and model pair, so other review-conflict thoughts in the fixture vault (legal/supplier-agreement.pdf) are rejected by the validator, which is correct.

**Obsidian plugins: deferred.** Not part of this build.

## Thoughts v2 in the shell (feature/shell-thoughts)

Glue only; the engines are in FlamingoCore/Index/Ask/Thoughts. Privacy: thoughts only reach local models (`ThoughtReader`, `askStreamingLocally`, `NightShiftService`).
- `AppState+Thoughts.swift`: saving (`saveComment` stamps uids, edits go by uid with `modified`), state/kind/reply by uid, understanding 2 s after a save plus idle backfill (50/day, `Defaults.thoughtBackfill`), `@ai`/`@flamingo` and rail Ask AI (streams into `ThoughtJobsModel.pending`), night shift service+scheduler per vault, echo/recall, `[[file#^uid]]` links (`openLink`), resurface near visible files, Capture wiring, palette commands.
- `ThoughtsTab.swift`: Inspector Thoughts tab (rail modifiers, reply mode, echo, folder notes). `ThoughtWorkflow.swift`: pure helpers (`ThoughtLink`, `ThoughtTriggers`, `DailyBudget`, `QAClock`) and `ThoughtsRuntime`.
- For the briefing: `AppState.nightShiftCatchUp(onEvent:)`, `AppState.qaNow` / `AppState.now` (QA clock).
- QA: `reply`, `ai`, `nightshift now|plan`, `clock <ISO>|reset` verbs; `scripts/thoughts-qa.sh <scratch> [dark|light]`. `FLAMINGO_QA_STREAM_DELAY=<s>` paces canned answers word by word.
- The fake review-conflict memo works end to end for the deck and model pair (`scripts/headline-qa.sh`); other thoughts in the fixture vault are rejected by the validator.

## Feel, search results, navigation (2026-10-18)

- **Motion is springs** (DESIGN.md rule 7). `Theme.Motion.fast` / `normal` are critically damped
  springs; `press` / `release` / `glide` / `arrive` add the touch of overshoot where a hand let go
  or something was earned. AppKit uses `Motion.curve` (a Bézier within 1.3% of the spring),
  `Motion.spring(_:)` (a `CASpringAnimation`) or `Motion.settle(_:)` (frame loops, the graph).
  Reduce Motion turns every token into a short ease-out.
- **Every click is seen.** `.buttonStyle(.press)` replaces `.plain`: the label grows about 3.5pt
  (at most 12%) over a `Color.pressed` squircle and springs back. `.pressFeedback` does the same
  for `onTapGesture` views without adding a gesture (one `PointerPress` local monitor);
  `flamingoRow` has it built in; `PressAnimator` wraps `super.mouseDown` in the AppKit lists
  (explorer, columns, search results). Panels (palette, capture) arrive via `PanelMotion`.
- **Haptics and sound** go through `Feedback`: `.detent` / `.threshold` taps at `.drawCompleted`,
  at least 40ms apart, only on crossings; Finder's trash sound on delete, the Dock's poof on
  removing a bookmark. `Chime` is now a D5/A5/D6 bell with three voices per note.
- **Search results** (`SearchResults*.swift`, `AppState+SearchResults.swift`): ↩ in the palette
  with several files and no row picked opens Finder's list view in the content area: sortable
  headers, sort and Kind menus, live refine, Quick Look, its own History entry. QA: `scripts/results-qa.sh`.
- **Navigation**: swipes commit (`SwipeGate` / `SwipeProgress` in SwipeNavigation.swift, decisions
  logged as `swipe:` under `FLAMINGO_DEBUG`); the explorer's crosshair is a one-shot "Reveal
  current file" (⌘⇧J) with a pulse; following the open file is the Settings toggle, reset to on
  once (`autoRevealCrosshairReset`). QA: `scripts/nav-qa.sh`.
- **QA and tests need `ANTHROPIC_API_KEY=qa-placeholder`**, or the Keychain read behind
  `AskEngine.hasKey` / `AskRecoveryTests` puts a prompt on the screen and hangs the run.
  `hover|press|release|click x y` QA verbs post real mouse events (SwiftUI hover doesn't follow them).
