# Issues

What QA found running `make demo` on the Kestrel Works vault. Each line names the owning
plan. Owners tick their own lines; session 10 re-checks every loop and moves what's fixed
to the bottom. Screens are in `docs/screens/`.

## Open

### Pass 2 — 23:05
- [x] (01) The sidebar is still a flat list. `decks/`, `docs/`, `finance/` and the rest never appear, and files from every folder are interleaved under no headings. The plan and DESIGN.md call for a collapsible folder tree. — Fixed: NSOutlineView folder tree, folders first, depth-0 expanded, expansion remembered per vault.
- [x] (01) ⌘K does nothing. Clicking Go › Open Quickly… in the menu does nothing either: no panel opens, and System Events sees only the main window. — Fixed: ⌘K/⌘F open a child panel over the main window (fuzzy files + commands; full-text search with anchors).
- [x] (01) A short coral hairline, about 56pt, sits at the left end of the toolbar's bottom edge under the Files segment. It stays in every mode for more than five minutes after launch. If it's the reindex progress hairline, it never finishes; the CLI indexes the same vault in 0.3s. See `docs/screens/files.png`. — Can't reproduce on the current build: with `FLAMINGO_DEBUG=1` the app logs `reindex: 0% → 5% → 95% → 100%, done in 0.39s` on a copy of the demo vault at a path with a space, and the line fades out. If it recurs, launch `build/Flamingo.app/Contents/MacOS/Flamingo -lastVault <path>` with `FLAMINGO_DEBUG=1` and send 01 the `reindex:` lines.
- [x] (01) Thoughts left on a pptx have no anchor: ⌘⇧C on `arc-launch-plan.pptx` wrote `- [23:02] QA check…` without a `(slide N)`. Quick Look doesn't report the current slide. If that can't be fixed, consider stepping slides with ⌘↑/⌘↓ yourself, so the anchor is known for decks at least. — Done: when the preview can't report a position, ⌘↑/⌘↓ (and ⌥↑/⌥↓) step through the file's indexed sections (slides, sheets, headings); the current anchor shows next to the file name in the title strip and ⌘⇧C uses it.
- [ ] (09) Ask mode is still an empty pane with one hairline (pass 3). No cursor blinks, so nothing says "type here". It no longer takes key status off the main window.
- [x] (05) Wikilinks in the body of markdown notes don't become graph edges, only links in comments do. `weekly-sync-2026-10-08.md` links four files and is an island in the graph. Obsidian users will expect these edges. This is outside plan 05 as written, so it's filed as a request.
- [ ] (07) Low priority: links in comments render with their raw anchor suffix, e.g. `interview-maya-chen.m4a#time 0:53`. `interview-maya-chen.m4a › time 0:53`, or the alias when there is one, would read better.

### Pass 3 — 23:22
- Nothing new. The sidebar, ⌘K, the hairline, pptx anchors, Ask and markdown-body edges are as in pass 2.

### Pass 4 — 23:35
- [x] (01) Dark mode can't be checked without changing the system appearance. I've asked for a `FlamingoAppearance` launch default (see REQUESTS.md). Until that exists, every screenshot here is light only. — Done: `-FlamingoAppearance dark|light` at launch.
- The trail now shows real thumbnails (slide, page, sheet) next to file names.
- `run.sh` only replaces the instance running from this repo's bundle and launches with `open -n`, so other sessions' test builds keep running.

### Pass 5 — 23:50
- [ ] (01) Reopened: pptx anchors don't match what's on screen. On `arc-launch-plan.pptx` I pressed ⌘↓ twice, then ⌘⇧C. The thought was written as `(slide 2)` and the title bar says `slide 2`, but the preview still shows slide 1, the title slide. Two presses should also reach slide 3. Either move the preview with the anchor, or don't anchor at all. A wrong anchor is worse than none.
- [ ] (01) Sidebar names are truncated in the middle with plenty of room left: `arc-launc…plan.pptx`, `q3-board…view.pptx`, `whiteboa…ricing.jpg`. The 240pt sidebar fits all of them in full.
- [ ] (01) The rail's mini-graph shows in Graph mode too, so the same graph is drawn twice. Hide it there.
- [ ] (01) The palette lists "Capture From Other Apps ^⌥Space", but on this Mac Capture falls back to ⌃⌥⌘Space (plan 03's conflict note). Show what `CaptureController.shared.globalShortcuts` reports.
- Verified fixed: the folder tree, the ⌘K palette (commands with symbols and key hints, no header), the stray hairline, and dark mode via `-FlamingoAppearance dark`. Dark screens are `docs/screens/*-dark.png` and look right: dark surfaces, coral selection and links, slides on white.
- Verified fixed (05): markdown body wikilinks are edges now, so `weekly-sync-2026-10-08` is connected.

### Carried over
- [ ] (04) Heads-up: Quick Look thumbnailing of any `.usdz` (ours, and Apple's `shaderball.usdz`) never returns from `qlmanage -t`. Put a timeout on usdz thumbnails and fall back to the glyph.

## Working
- A fresh `git clone` followed by `make demo` builds in about 9s, launches the clone's own binary, and opens Kestrel Works with comments in the rail (pass 3).
- Build is green. All 7 test bundles pass: Core, Extract, Index, Graph, Trail, Capture, Ask.
- The demo opens the vault straight into Files mode. pptx previews render, and the rail shows each comment with a time, an anchor chip and coral links.
- ⌘⇧C → type → Return appends to `.flamingo/notes/decks/arc-launch-plan.pptx.md` in the contract format, records a `commented` trail event, and the rail updates immediately. See `docs/screens/capture.png`.
- ⌘1–4 switch modes. The graph draws 19 family-tinted nodes, solid link edges and dashed trail edges. The trail shows sessions with comments under their files and `⌕ lead time` between them, and it records new opens live.
- Index: file text is now in, so `clamp` finds the brief, slides 6 and 10, and `open-questions.md` as well as the two comments. A full reindex of the vault takes 0.32s.
- The bundle is signed with the Apple Development identity, so Accessibility and Automation grants survive rebuilds. It carries 08's icon, asset catalog, accent and menu bar template.

## Fixed
- (06) Graph labels: every node is labeled at default zoom, including `q3-board-review` and `q3-model` (pass 3).
- (06) The GraphHarness window no longer floats over QA (pass 3).
- (08) The mode switcher uses the four symbols from `SegmentedModes`, with coral for the selected mode (pass 3).
- (05) The index had no file text, only comments (pass 1).
- (07) FlamingoTrailTests crashed (pass 1).
- (01) The shell was the scaffold, with no preview, rail, modes or capture (pass 1).
