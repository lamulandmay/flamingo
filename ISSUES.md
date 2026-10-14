# Issues

What QA found running `make demo` on the Kestrel Works vault. Each line names the owning
plan. Owners tick their own lines; session 10 re-checks every loop and moves what's fixed
to the bottom. Screens are in `docs/screens/`.

## Open

### Pass 2 — 23:05
- [ ] (01) The sidebar is still a flat list. `decks/`, `docs/`, `finance/` and the rest never appear, and files from every folder are interleaved under no headings. The plan and DESIGN.md call for a collapsible folder tree.
- [ ] (01) ⌘K does nothing. Clicking Go › Open Quickly… in the menu does nothing either: no panel opens, and System Events sees only the main window.
- [ ] (01) A short coral hairline, about 56pt, sits at the left end of the toolbar's bottom edge under the Files segment. It stays in every mode for more than five minutes after launch. If it's the reindex progress hairline, it never finishes; the CLI indexes the same vault in 0.3s. See `docs/screens/files.png`.
- [ ] (01) Thoughts left on a pptx have no anchor: ⌘⇧C on `arc-launch-plan.pptx` wrote `- [23:02] QA check…` without a `(slide N)`. Quick Look doesn't report the current slide. If that can't be fixed, consider stepping slides with ⌘↑/⌘↓ yourself, so the anchor is known for decks at least.
- [ ] (09) Ask mode is still an empty pane with one hairline (pass 3). No cursor blinks, so nothing says "type here". It no longer takes key status off the main window.
- [ ] (05) Wikilinks in the body of markdown notes don't become graph edges, only links in comments do. `weekly-sync-2026-10-08.md` links four files and is an island in the graph. Obsidian users will expect these edges. This is outside plan 05 as written, so it's filed as a request.
- [ ] (07) Low priority: links in comments render with their raw anchor suffix, e.g. `interview-maya-chen.m4a#time 0:53`. `interview-maya-chen.m4a › time 0:53`, or the alias when there is one, would read better.

### Pass 3 — 23:22
- Nothing new. The sidebar, ⌘K, the hairline, pptx anchors, Ask and markdown-body edges are as in pass 2.

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
