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
| `FlamingoIndex` | SQLite FTS5 index, FSEvents watcher, hybrid search, graph builder, mention discovery (`Mentions.swift`), embeddings (in progress) |
| `FlamingoGraph` | Force-directed Canvas graph, folder scoping, hollow folder nodes, click/double-click, filter |
| `FlamingoTrail` | Session recording (`trail.jsonl`), clustering into sessions, timeline view, trail edges |
| `FlamingoAsk` | Retrieval + Claude or local llama-server (Qwen3.8-27B) with citations |
| `FlamingoDesign` | `Theme` tokens and components. Never hardcode a color, font or spacing |

State on disk, all under `<vault>/.flamingo/`: `notes/<path>.md` sidecars (Obsidian-compatible),
`index.sqlite`, `graph.json`, `graph-layout.json`, `trail.jsonl`, `pins.json`, `ignore`.

## Graph edges, and where they come from

- `link` — wikilinks in comments and markdown bodies
- `mention` — discovered: a file's text names another file (`Sources/FlamingoIndex/Mentions.swift`)
- `trail` — files touched in the same session (dashed)
- `folder` — containment, only in a folder-scoped view (hollow folder nodes)
- `related` — not built yet; see REQUESTS (embeddings nearest-neighbours)

## How work was organised

Twelve plans in `plans/`, each owned one directory, built in parallel by separate agents.
Cross-agent asks go in `plans/REQUESTS.md` (append-only, tick when done). QA findings are in
`ISSUES.md`. The plans are still the best description of intent per module; if something looks
half-done, its plan says what "done" was supposed to mean.

## State at handover (2026-10-15)

Working and verified end to end: open a vault, browse, preview every type, ⌘⇧C writes a sidecar
and the rail updates, search across pptx/docx/xlsx/pdf/OCR/3D, graph with folder scoping and
discovered connections, trails, swipe back/forward with full state (file, anchor, mode, folder),
whole-Mac vault with hidden folders and pinned sidebar.

**Uncommitted work in the tree** from the last agent on plan 11 (ribbon + status bar, M4):
`README.md`, `Sources/Flamingo/{AppState,Defaults,FileTree,MainMenu}.swift`. Check it builds,
finish or revert, then commit.

**Open, in priority order**

1. Ask mode: verify the question field takes focus on ⌘4 and that the local provider
   (`LlamaServer.swift`, `Provider.swift`) actually starts llama-server and answers offline. Plan 12
   landed the files; nobody has run it end to end. Model: `~/codex/cgnsa/data/models/qwen3.8-27b/`.
2. Embeddings: `Embeddings.swift`/`Semantic.swift` exist; confirm `ollama pull nomic-embed-text`
   is used, hybrid search works, then add `related` graph edges (REQUESTS.md, last entry).
3. pptx anchors drift from the Quick Look preview (ISSUES.md). Likely fix: render slides from the
   extracted structure instead of relying on Quick Look's page.
4. Capture walks the whole vault for `[[` completion; on `~` that's slow. Use `IndexStore.files(matching:)`.
5. `GraphInputNSView` grabs first responder when it enters a window (rail mini-graph steals keys).
6. Remaining items in `ISSUES.md` and the 14 unticked lines in `plans/REQUESTS.md`, mostly design nits.

## Conventions that matter

- Public API in Core is frozen for everyone else's sake: add, never rename.
- Keep `make test` green. Commit small. The only files no one should edit casually are
  `Package.swift` and `CONTRACT.md`.
- Before any view: DESIGN.md. If a label can be removed, remove it. No placeholder text, no emoji.
- User's hardware: M5 Pro, 64 GB. Ollama has gemma3:4b, llama3.2:1b, qwen2.5:1.5b.
