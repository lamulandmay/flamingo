# Issues

What QA found running `make demo` on the Kestrel Works vault, over six passes from 22:45 to
00:10. Each line names the owning plan. Screens are in `docs/screens/` (light, and `-dark`).

## Open at v0.1

- [ ] (09, cc 01) Ask has no question field that takes focus. Repro: ⌘4, type "What price did the board see for Arc?", press Return. The keystrokes go to the sidebar's type-to-select (it selected `whiteboard-pricing.jpg`) and Return jumps back to Files. Ask is still an empty pane with one hairline.
- [ ] (01) pptx anchors don't match the preview. After ⌘↓ ⌘↓ on `arc-launch-plan.pptx` the anchor and title say `slide 2`, but Quick Look still shows slide 1, so ⌘⇧C pins the thought to a slide the user isn't looking at. Two presses should also reach slide 3. Last checked in pass 5.
- [x] (01) Sidebar names are middle-truncated with room to spare (`arc-launc…plan.pptx`). Plan 11: the row's trailing padding is `Space.s`, not `Space.l`. Not re-checked on the demo vault.
- [x] (01) The rail's mini-graph is drawn in Graph mode too, so the same graph appears twice. Plan 11: hidden in Graph mode.
- [x] (01) The palette lists "Capture From Other Apps ^⌥Space", but on a Mac where ⌃⌥Space switches input sources the live shortcut is ⌃⌥⌘Space. It already shows `CaptureController.shared.globalShortcuts.first`.
- [ ] (07) `TrailSharedStoreTests.testThrowawayStoreFlushesAndNotifiesTheLongLivedOne` was reported red by plan 04 ("no such file" on `trail.jsonl`). It passed in all six of my runs, so it looks flaky (timing or a shared temp dir).
- [ ] (human) CONTRACT.md's keyboard map says ⌃⌥Space. On this Mac macOS owns ⌃⌥Space for switching input sources, so Capture falls back to ⌃⌥⌘Space. The README documents both. Whether the contract changes is your call.

## Plan 11: whole Mac (2026-10-15)

Measured on this Mac (M5 Pro, 64 GB) with the vault at `~`, a debug build, `FLAMINGO_DEBUG=1`.

- Walk: `VaultScanner.scan` lists 896,239 files in `~` in 33 s cold (20–30 s warm). The first file comes after 2 ms. The biggest trees are `codex` (313k), `.claude-science` (218k) and `Library/Application Support/Claude` (65k). The palette gets a partial list every 2 s, and ⌘K found `~/.config/gh/hosts.yml` while indexing.
- Index throughput: 180–500 new files/s, depending on content. Files already indexed are skipped at about 6,000/s. Two runs reached 347,800 files. **A full first pass was not measured to the end.** Both long runs (16:46–17:01 and 17:04–17:22) ended in a normal `terminate:` while the window was frontmost: ⌘Q or a quit from another script, not a crash. At those rates the rest of `~` is roughly another 20–40 minutes.
- **Index size is the real problem:** 8.5 GB `index.sqlite` at about 350k files, so expect 20 GB or more for all of `~`. It's mostly site-packages and conda trees (filed to plan 12).
- Main thread during indexing, worst lag per 10 s window: before the fixes, 200+ ms in every window. The causes were the file set being built and freed on the main thread, `files.removeAll` on every watcher batch, and reindex ticks redrawing the whole window. After the fixes it is 1–25 ms. The remaining spikes (100–240 ms, worst 2.4 s) were sampled: they are another process's Accessibility queries on the PDF preview (`PDFAccessibilityNodePage accessibilityNumberOfCharacters`, which lays out the whole page in PDFKit on the main thread), not indexing. The last run's steady ~195 ms windows weren't sampled.
- Graph: on `~` every indexed file is a graph node. `buildGraph` takes 3–9 s off the main thread and rewrites a 22 MB `graph.json` (it grows with the index). The shell keeps only connected or commented nodes above 5,000 and rebuilds at most every 30 s on disk churn (filed to plan 12).
- Pins, unpin with ⌫ plus the Undo toast and ⌘Z, the lazy tree, dotfiles listed, and ⌘K into `.config` were all checked in the app. "Pin Folder…", drag to reorder and drop-to-pin weren't driven (NSOpenPanel and drags can't be scripted headlessly).
- Full Disk Access: the palette command appears only when `~/Library/Mail` or `~/Library/Messages` can't be listed. This Mac grants it to the test runner, so the command didn't show.

- [ ] (12) `IndexStore` metadata-only rows for files over 50 MB and iCloud placeholders. The shell keeps both out of `update` for now, so they are findable by name in ⌘K but not in search.
- [ ] (12) Index size and graph size on a whole disk, above.
- [ ] (03, unowned) Capture walks the whole vault itself (`loadCandidates`, and `TitleIndex` every 30 s). On `~` that is a 30 s walk. See REQUESTS.md.
- [ ] (06, unowned) `GraphInputNSView` takes first responder whenever it enters a window, so the rail's mini-graph took the keyboard from the sidebar after every selection. The shell's `MainWindow` refuses that outside Graph mode; the real fix belongs in the graph.

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
