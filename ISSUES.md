# Issues

What QA found running `make demo` on the Kestrel Works vault, over six passes from 22:45 to
00:10. Each line names the owning plan. Screens are in `docs/screens/` (light, and `-dark`).

## Open at v0.1

- [ ] (09, cc 01) Ask has no question field that takes focus. Repro: ⌘4, type "What price did the board see for Arc?", press Return. The keystrokes go to the sidebar's type-to-select (it selected `whiteboard-pricing.jpg`) and Return jumps back to Files. Ask is still an empty pane with one hairline.
- [ ] (01) pptx anchors don't match the preview. After ⌘↓ ⌘↓ on `arc-launch-plan.pptx` the anchor and title say `slide 2`, but Quick Look still shows slide 1, so ⌘⇧C pins the thought to a slide the user isn't looking at. Two presses should also reach slide 3. Last checked in pass 5.
- [ ] (01) Sidebar names are middle-truncated with room to spare (`arc-launc…plan.pptx`).
- [ ] (01) The rail's mini-graph is drawn in Graph mode too, so the same graph appears twice.
- [ ] (01) The palette lists "Capture From Other Apps ^⌥Space", but on a Mac where ⌃⌥Space switches input sources the live shortcut is ⌃⌥⌘Space. Show `CaptureController.shared.globalShortcuts`.
- [ ] (07) `TrailSharedStoreTests.testThrowawayStoreFlushesAndNotifiesTheLongLivedOne` was reported red by plan 04 ("no such file" on `trail.jsonl`). It passed in all six of my runs, so it looks flaky (timing or a shared temp dir).
- [ ] (human) CONTRACT.md's keyboard map says ⌃⌥Space. On this Mac macOS owns ⌃⌥Space for switching input sources, so Capture falls back to ⌃⌥⌘Space. The README documents both. Whether the contract changes is your call.

## Working at v0.1

- `git clone` then `make demo`: builds in about 9s and opens Kestrel Works with comments, a graph and a trail. `make release` writes `build/Flamingo.zip` (2.7 MB, signed with the Apple Development identity when there is one). The release build launches and restores the last vault and selection.
- 683 tests across 7 bundles, 0 failures, 7 skipped. The skips are opt-in fixture regenerators.
- Files: a folder tree with family-tinted glyphs and coral selection. Quick Look previews every fixture type, including pptx, docx, xlsx, pdf, images, video, audio and usdz.
- ⌘⇧C → type → Return writes the thought to `.flamingo/notes/<path>.md` in the contract format, logs a `commented` trail event, and updates the rail at once. The rail shows time, anchor chip, coral links and a neighbourhood graph.
- Rename healing: `mv design/moodboard.jpg design/moodboard-october.jpg` while the app is running moves the sidecar and rewrites `target:` within 4 seconds.
- Graph: 19 nodes, comment links, markdown body links and dashed trail edges, all labeled, with the selection's neighbours highlighted.
- Trail: sessions newest first, with thumbnails (the usdz lamp too), comments under their files, and `⌕ query` between them. It records live, and `demo.sh` shifts the fixture's dates so the newest session is today.
- ⌘K palette with commands and key hints. Search hits file text and comments with anchors (`clamp` finds the brief, slides 6 and 10, a note, and two comments). A full reindex of the vault takes 0.3s.
- Dark mode works throughout. Check it with `scripts/demo.sh -FlamingoAppearance dark`.

## Fixed during the build

- (01) The shell was the scaffold, with a flat list and no preview, rail, modes or capture (pass 1 → 2).
- (01) No folder tree, ⌘K did nothing, and a stray hairline never cleared (pass 2 → 5).
- (01) There was no way to see dark mode without changing the system setting. `-FlamingoAppearance` added (pass 4 → 5).
- (04) usdz thumbnails hung Quick Look. The trail now shows the lamp (pass 1 → 6).
- (05) The index had comments but no file text (pass 1 → 2). Markdown body wikilinks weren't graph edges (pass 2 → 5).
- (06) Unlabeled hub nodes, and a floating test harness covered the app (pass 2 → 3).
- (07) FlamingoTrailTests crashed the test run (pass 1 → 2).
- (09) Switching to Ask took key status off the main window (pass 2 → 3).
- (10) `build.sh` and `test.sh` exited 0 on failure. Ad-hoc signing reset Accessibility grants on every build. `run.sh` killed other sessions' test builds. All fixed.
