# Flamingo performance audit, 2026-10-16

Scope: every source of perceptible lag. I fixed what lives in the modules I own: Core, Extract, most of Index, the Trail model, and the graph layout files. The work is in `scratchpad/tree-perf`. Findings for the UI owner and for the Search/UnifiedSearch owner come with concrete fixes and are listed below.

## Files changed (copy these verbatim from `tree-perf/`)

| File | Status |
|---|---|
| `Sources/FlamingoIndex/Compaction.swift` | new |
| `Sources/FlamingoIndex/IndexStore.swift` | modified |
| `Sources/FlamingoCore/FinderOrder.swift` | new |
| `Sources/FlamingoCore/VaultScanner.swift` | modified |
| `Sources/FlamingoCore/IgnoreRules.swift` | modified |
| `Sources/FlamingoCore/Wikilink.swift` | modified |
| `Sources/FlamingoCore/SidecarStore.swift` | modified |
| `Sources/FlamingoCore/FileIdentity.swift` | modified |
| `Sources/FlamingoExtract/Extract.swift` | modified |
| `Sources/FlamingoExtract/Formats/ImageExtractor.swift` | modified |
| `Sources/FlamingoExtract/Formats/PDFExtractor.swift` | modified |
| `Sources/FlamingoTrail/Trail.swift` | modified |
| `Sources/FlamingoTrail/TrailThumbnails.swift` | modified |
| `Tests/FlamingoIndexTests/CompactionTests.swift` | new |
| `Tests/FlamingoCoreTests/PerformancePathTests.swift` | new |
| `Tests/FlamingoExtractTests/ExtractCancellationTests.swift` | new |

- A unified diff of all of the above is at `scratchpad/perf-changes.diff`. Its baseline is `scratchpad/orig/`, a copy of the 16:20 snapshot that matches `tree-perf` everywhere I didn't edit.
- Public API was only added to, never renamed or removed: `IndexStore.compactSearchIndex(force:shouldCancel:)`, `IndexStore.searchIndexNeedsCompaction()`, `IndexStore.autoCompact`, `FinderOrder`, `FileIdentity.existingID(atPath:)`, `VaultScanner.Limits.allowsExtraction(atPath:)`.
- On-disk formats are unchanged. Compaction only rewrites FTS5's own segment b-trees, which any older Flamingo reads normally.
- I did not touch `GraphGestures.swift` or `GraphInputView.swift`.

**Tests:** `scripts/test.sh` runs 1040 tests, 0 failures, 10 skipped. The baseline before my changes was 1028 tests, 0 failures, the same 10 skipped. The difference is the 12 new tests.

## How this was measured

- **Builds and machine:** release builds on the M5 Pro. Other agent sessions were building and testing on the same machine at the same time, so treat wall-clock numbers as ±20%.
- **`vaults/big`, 35,500 files:**
  - 30,000 md/txt notes with `[[wikilinks]]`, spread over 3,080 folders up to 8 deep.
  - 5,500 copies of the fixture pptx/docx/xlsx/pdf/jpg/png files.
  - 1,420 sidecars holding 4,952 thoughts, and 15k trail events.
  - The index is 387 MB with 91,500 sections. The graph has 37k nodes and 124k edges.
- **`vaults/wide`:** one folder with 30,500 entries.
- **Vocabulary caveat:** the generator uses 55 words, so any query word matches about a third of all sections. Common words in a real vault ("meeting", "project") behave like this; rare words are cheaper.
- **Tools used only for measurement, not shipped:**
  - A copy of the app with a run-loop stall logger added to `QAHook` (any main-thread pass over 16 ms), plus scroll injection.
  - A `PerfBench` executable that times the module APIs in-process.
  - `xctrace` Time Profiler.

## Summary, worst first

| # | What the user feels (35.5k-file vault) | Before | After | Owner |
|---|---|---|---|---|
| 1 | ⌘K: results arrive long after typing | in-process query 1.3–1.6 s; in-app "budget" 1.73 s to first results | 0.37 s in-process, 0.61 s in-app; **0.07 s once the SQL fix in #2 lands** | Fixed (Index) |
| 2 | ⌘K, Ask and the search tab: FTS re-runs once per candidate row | 1.3 s per query; Ask/search-tab section search >100 s | 5 ms for that statement | **Search/UnifiedSearch owner** |
| 3 | Graph rebuild after launch and after every file open: CPU busy for 20 s, then a main-thread hitch | 17.8 s per build (CLI), 19.5–20 s in-app; 55–134 ms stall when it lands | 1.8 s (CLI), 2.0–3.4 s in-app; stall unchanged | Build speed fixed (Index); rebuild frequency and stall are UI |
| 4 | Clicking a `[[link]]` freezes the window | 126 ms × 2 per click (2.4 s × 2 at 532k files) | 1.9 ms (29 ms at 532k) | Fixed (Core); caching suggested to UI |
| 5 | Expanding a big folder in the sidebar freezes | 374 ms main stall (30.5k entries) | 163 ms | Partly fixed (Core); moving the listing off main is UI |
| 6 | At launch, ⌘K and the sidebar wait for the file walk | 1.9 s to list 35.5k files | 0.26 s | Fixed (Core) |
| 7 | Every launch spends CPU re-checking the index (holds the write lock, churns the WAL) | 4.6 s warm reindex | 1.9 s | Fixed (Index/Core) |
| 8 | Saving a thought while a reindex ends waits on the sidecar lock | lock held for the whole reconcile, about 93 ms (plus a full vault xattr walk if any note lost its file) | lock held only for the moves | Fixed (Core) |
| 9 | Indexing memory and CPU contention | peak footprint 381 MB on a mixed 1.5k-file batch; extractor threads at default QoS | 305 MB, same or better throughput; threads at the caller's QoS (utility in the app) | Fixed (Extract/Index) |
| 10 | Moving through palette results or files quickly leaves whole-file extractions running | unbounded queue of extractions | a cancelled task skips queued work | Fixed (Extract) |
| 11 | Trail graph edges; Trail thumbnail rows stat on main | 144 ms; 3 stats per row per render | 73 ms; one stat per second per file | Fixed (Trail) |
| 12–22 | UI-shell invalidation, selection, startup, editor, rail, capture and more | see the UI-owner section | — | UI owner |

---

## Fixed in my modules

### 1. Fragmented FTS5 index: every MATCH walked about 20 segments

- **What the user feels:**
  - Slow ⌘K for any query.
  - Slow search tab and Ask retrieval.
  - Slow graph build (mention discovery runs up to 6,000 MATCH queries).
  - Slow related-files and family lookups.
- **Root cause:**
  - FTS5 writes one segment per transaction. The shell indexes in 200-file batches (`IndexStore.swift:666`, `writer.transaction` per batch), so a full pass left 23 segments in `sections_fts` and 17 in `comments_fts`.
  - Nothing ever merged them. FTS5's automerge only combines segments on the same level.
  - Every query term then merges 23 iterators: `fts5MultiIterNext` plus memcmp took 75% of profile samples.
- **Fix:** `Compaction.swift`.
  - Merges each FTS table into one segment with FTS5's incremental `merge` command, run as `-500` pages per transaction. One step takes at most about 90 ms, so a thought's index write waits for at most one step.
  - It runs automatically 3 s after the last index write, and stops as soon as another write arrives.
  - It runs synchronously at the end of `IndexStore.reindex` (the CLI path).
  - It only runs when worthwhile: 8 or more segments, or new data of at least 1/8 the size of the largest segment. That bounds rewrite amplification on huge indexes.
  - Read-only stores never compact.
  - The writer now sets `journal_size_limit = 64 MB`, so the WAL shrinks back after a burst.
- **Cost:** 2.5 s in 40 steps for the 387 MB index (23 segments → 1). Verified in the app: after a cold index, both FTS tables have 1 segment.
- **Measured:**

  | Workload | Before | After |
  |---|---|---|
  | 200 mention queries (graph build pattern) | 1.10 s | 0.04 s |
  | Graph build, CLI `--graph` | 17.8 s | 1.8 s |

  Warm in-process `unifiedSearch`, limit 100 (the ⌘K call), in ms. "Before" is on the original 23-segment index. "+ SQL fix" is projected: I applied the change from #2 below in a measurement copy only.

  | Query | Before | After (compaction + reader mmap) | + SQL fix from #2 |
  |---|---|---|---|
  | `b` | 38 | 21 | 19 |
  | `bu` | 815 | 102 | 88 |
  | `bud` | 534 | 78 | 73 |
  | `budget` | 1309 | 366 | 73 |
  | `pricing memo` | 1614 | 376 | 66 |
  | `runway forecast` | 1333 | 377 | 76 |
  | `q3` | 136 | 25 | 24 |

  In the app, typing "budget" in ⌘K showed first results 1.73 s after the last key before (the launch graph build was competing), and 0.61 s after.
- **Reader mmap** (`IndexStore.init`): the reader connection now uses `PRAGMA mmap_size = 1 GB`. This halved the remaining query time (127 → 75 ms on `budget` with the SQL fix). A bigger `cache_size` made no difference. It is enabled only when `.flamingo` is on an internal, local, non-removable volume, because a mapped file on a drive that gets unplugged faults instead of returning an error.

### 2. Link click resolved against the whole vault, twice

- **What the user feels:** a `[[link]]` click freezes the window.
- **Root cause:** `Wikilink.resolve(_:in:candidates:)` (`Wikilink.swift:149-157`) built a full `Resolver` for a single lookup: 8 NFC-normalised, lowercased dictionary keys per file. `AppState.openLink` (`AppState.swift:1405-1406`) calls it up to twice, on the main thread.
- **Fix:** `Wikilink.resolveOnce`.
  - A byte-level pass keeps only candidates whose basename, or basename without extension, could equal the target's last component.
  - Candidates under an alias target folder are kept too, so renamed paths still resolve.
  - It then builds a `Resolver` over just those, so the tie-breaking and alias rules are exactly the same.
  - Non-ASCII names, or names with `\`, take the exact slow path.
- **Measured:** 126 → 1.9 ms per call at 35.5k candidates; 2,433 → 29 ms at 532k.
- **Test:** `PerformancePathTests.testOneShotResolveMatchesTheFullResolver` checks 200+ targets against the full `Resolver`: case, NFD, the Kelvin sign, İ, CJK, aliases, and with and without a source file.

### 3. Vault scanning and folder listing

- **Root causes:**
  - `VaultScanner.scan` built a URL per file and fetched resource values for each.
  - For vaults under a symlinked root (`/tmp`, `/var` → `/private/...`), every path missed the root-prefix test and fell back to `Vault.relativePath(of:)`. That ran `standardizedFileURL` twice per file and was 21% of the warm-reindex profile.
  - `children(of:)` did the same per entry, then sorted with `localizedStandardCompare`, which bridges both strings and looks up the locale on every comparison.
  - `IgnoreRules.verdict` split the whole path into an array once per file, and `isIgnored` rebuilt every ancestor path string.
- **Fix:**
  - `readdir` with `d_type`, string paths, and a depth-first recursion in the same order as before. A directory is checked for being a package only when it has no known package extension. `DT_UNKNOWN` falls back to `lstat`.
  - `FinderOrder`: each name is bridged to `NSString` once and the locale fetched once per sort, using Foundation's own options. Tested equal to `localizedStandardCompare` on a tricky corpus.
  - Allocation-free basename and suffix matching in `IgnoreRules`, and ancestor checks on slices.
- **Measured:**

  | Operation | Before | After |
  |---|---|---|
  | `scan` of `big` | 1,366 ms | 114 ms |
  | `files(in:)` (sorted) | 1,565 ms | 397 ms |
  | `children` of a 30.5k-entry folder | 327 ms | 100 ms |
  | Same folder expanded in the app (main thread) | 374 ms | 163 ms |
  | In-app file catalog ready ("files: 35500") | 1.92 s | 0.26 s |

  For the scan, about 0.8 s of the "before" was the `/tmp`-symlink fallback. On a home folder (no symlink) the gain is about 5×, not 12×.

### 4. Warm reindex on every launch

- **What the user feels:** on every launch the index re-checks every file in the background, holding the write lock and churning the WAL.
- **Root causes:**
  - `replaceComments` (`IndexStore.swift:728-741`) deleted and re-inserted every target's thoughts on every pass. That rewrote the comment FTS entries and the WAL on each launch.
  - The per-file stat, xattr and extraction-eligibility checks built a URL each time.
- **Fix:**
  - Compare the stored rows with the sidecar and skip unchanged ones.
  - Use path-based `lstat`, `getxattr` (`FileIdentity.existingID(atPath:)`) and `allowsExtraction(atPath:)`.
- **Measured:** CLI warm reindex 4.62 s → 1.86 s. Combined with the compaction speedup of the graph step that follows, CLI reindex plus graph went from 23.7 s to 3.6 s.

### 5. Sidecar reconcile held the lock that thought saves need

- **Root cause:** `SidecarStore.reconcile()` (`SidecarStore.swift:210-228`) checked every note's target with `existsExactly`, and could walk the whole vault for identities, all while holding the process lock and `flock`.
- **Why it matters:** the UI calls `append`, `update` and `delete` on the main thread (see U8), so a thought saved at the end of a reindex blocked until reconcile finished.
- **Fix:**
  - The existence checks, id reads and `FileIdentity.carriers` walk now happen before taking the lock. Each candidate is re-checked under the lock before it moves.
  - `sidecarRefs` uses `readdir` instead of `FileManager.enumerator` with `standardizedFileURL` per note.
  - `carriers` uses the unsorted scan; only the short per-id lists are sorted.
- **Measured:** `sidecarRefs` 73 → 29 ms. `reconcile` takes 46 ms total, almost all of it outside the lock.

### 6. Indexing contention and memory

- **QoS:**
  - The extractor threads (`ExtractionQueue`, `IndexStore.swift:781-786`) were `Thread.detachNewThread`, which runs at default QoS even under the app's utility reindex queue.
  - They now run at the caller's QoS: utility in the app, so performance cores are left for the UI.
  - In-app cold index of `big`: the main thread stayed under 60 ms in both builds. Throughput was not worse (413 files/s after versus 279 before, under different machine load).
- **OCR memory:**
  - Eight threads each held a decoded bitmap (up to 64 MB) while waiting in Vision.
  - Image decode plus OCR now goes through 4 slots (`ImageExtractor.withOCRSlot`, also used for PDF OCR pages).
  - 300 photos: 20.7 s before, 20.2 s after; peak footprint 345 → 273 MB. Two slots halved throughput (48 s), so the class doc's claim that Vision runs one request at a time is wrong.
  - Mixed batch of 1,500 files: 23.3 → 21.7 s; peak footprint 381 → 305 MB.
  - In the app during a cold index: footprint peaked at 418 MB versus 648 MB before (noisy).
- **Background extraction:**
  - `Extract.extractInBackground` now skips work for a task cancelled before its turn.
  - The palette detail and the source reader use `.task(id:)`, so holding ↓ no longer stacks up full-file extractions.

### 7. Trail

- `TrailStore.edges()` stats each distinct file by path string instead of building a URL: 144 → 73 ms. This runs on the graph queue at every graph build.
- `TrailThumbnails.key` did a `resourceValues` stat on the main thread up to three times per row per render. It now reuses a modification date read in the last second.

---

## For the Search/UnifiedSearch owner (highest impact remaining)

### S1. `rowid IN (…)` next to `MATCH` re-runs the FTS query once per listed row

- **Root cause:** SQLite passes `rowid IN (…)` to FTS5's `xBestIndex` as a rowid-equality constraint. FTS5 then evaluates the whole MATCH expression once per listed rowid. A prefix term with no prefix index (4+ characters, such as `budget*`) is re-expanded every time.
- **Measured with `sqlite3` on the 35k index:**
  - The snippet query at `UnifiedSearch.swift:445-452` with 401 picked rowids: 1,293 ms. With `+rowid`: 5.8 ms.
  - The comment at `Search.swift:226` claims the `picked` CTE avoids this. It doesn't: 1.5 s.
  - `Search.swift:258` and `:287` put **every** section or comment rowid in the list when no folder is given. A single common term did not finish in 300 s (still over 100 s on a second run with a timeout). After compaction it takes 24 s; with `+rowid`, 0.26 s.
- **Who hits it:**
  - Ask retrieval: `Retrieval.swift:157-158` calls `searchSections` and `searchComments` per reformulation.
  - `VaultSession.searchAll`.
  - The CLI.
- **Fix:** prefix `rowid` with `+` so it is filtered after the match, not pushed into FTS5. Results are identical.

```swift
// UnifiedSearch.swift:449 and :464
... WHERE sections_fts MATCH ?1 AND +rowid IN (SELECT value FROM json_each(?2))
... WHERE comments_fts MATCH ?1 AND +rowid IN (SELECT value FROM json_each(?2))
// Search.swift:233, :258, :287
... sections_fts MATCH ?1 AND +rowid IN picked
... AND +rowid IN (SELECT rowid FROM sections WHERE 1 = 1 \(Self.folderPredicate(folder))) ORDER BY rank LIMIT ?2
... AND +rowid IN (SELECT rowid FROM comments WHERE 1 = 1 \(Self.folderPredicate(folder))) ORDER BY rank LIMIT ?2
```

- **Better still for `:258` and `:287`:** with no folder, drop the `IN` entirely. With a folder, join `sections s ON s.rowid = sections_fts.rowid` and put the path range on `s.path`, as `Search.swift:212` already does.
- **Effect:** ⌘K "budget" goes from 366 to 73 ms with compaction (1,309 ms at baseline). Ask's section search drops from minutes to under 0.3 s.

---

## For the UI owner

Ranked by impact. Line numbers refer to `orig/` and `tree-perf/`, which are identical for these files.

- **Measured:** U1, U2, U6, U7, U9, U10 (in-app stall log or bench).
- **From code reading:** U3–U5, U8, U11 (read, and spot-checked). The QA build runs in a background window, and macOS doesn't render occluded windows, so per-frame invalidation can't be timed from here. Profile these with Instruments, using the SwiftUI template, on a key window.

### U1. Graph rebuilt after every file open, with a main-thread hitch when it lands

- **Root cause:**
  - `trailChanged()` (`AppState.swift:1713`) → `markGraphStale()`, which rebuilds 1.5 s later even when Graph mode isn't on screen.
  - Every selection records `.opened` 0.8 s later (`AppState.swift:1421`), so every file you open triggers a full `buildGraph`.
  - The rail's `LocalGraphView`, the stated reason for this, is unused.
- **Measured:** two full builds in the first 40 s after launch. Each took 19.9 s before my Index fix and 2.0–3.4 s after.
- **The hitch when it lands:** `graph = g` (`AppState.swift:1721`) caused a 55–134 ms main-thread stall in Graph mode. That cost is `GraphModel.show`:
  - `newGraph == graph` and `edges !=` are O(N+E) (`GraphModel.swift:241,253`).
  - `GraphTopology(newGraph)` takes 88 ms at 37k nodes/124k edges (bench).
  - The old graph is freed on main.
- **Fix:**
  - In `trailChanged`, ignore `.opened` and `.searched`: they only add trail edges, which can wait.
  - Rebuild only when `mode == .graph`; otherwise mark stale and rebuild on entering Graph mode.
  - Build `GraphTopology` off main next to `buildGraph` and pass it as `preparedTopology`.
  - Compare graphs with a cheap generation token, not `==`.

### U2. ⌘K palette per keystroke

- **What the user feels:** the list blanks on every key. `Palette.swift:316` calls `model.setItems([])` before the debounce; the logs show `palette: []` after every keystroke, then results about 0.6 s later.
- **Fix:** keep the old items until the new response arrives, and dim them with `searching = true`.
- **Main-thread work per query:** `UnifiedSearchWorkflow.swift:18-23` walks every loaded tree node (`collect(tree.root)`). Keep a `Set<String>` of folder paths in `TreeModel`, updated when nodes load.
- **Detail pane:**
  - `SearchResultDetail` observes `AppState` and stats the file in its body (`UnifiedSearchUI.swift:56,69,219-244`).
  - Debounce the preview by about 150 ms.
  - `extractInBackground` is now cancellable, so `.task(id:)` cancellation already stops queued work.
- **Dead code:** `Fuzzy.FileTable` / `refreshTable` (`Palette.swift:268-287`) is never called.

### U3. One `AppState` (about 45 `@Published` properties) invalidates the whole window

- **Root cause:** `AppState.swift:62-200`. RootView, about 25 views, and every visible sidebar row's `NSHostingView` (`Sidebar.swift:644`, `SidebarRow.swift:10,60`) re-evaluate on any publish.
- **High-frequency publishers:**
  - `swipeAmount` at 60–120 Hz (`SwipeNavigation.swift:51`, `RootView.swift:29`).
  - `windowWidth` per live-resize tick (`AppDelegate.swift:111`).
  - `sidebarWidth` per divider tick, which also writes UserDefaults per tick (`AppState.swift:161`, `RootView.swift:213`).
  - `anchor` on every PDF page change, every second of media playback, and every caret line change (U5).
- **Each publish re-runs:**
  - A LaunchServices lookup (`DocumentSurface.swift:34`).
  - Stats (`:43-49`).
  - An O(document) string compare (`TextDocumentEditor.swift:484`).
  - The rail's attributed-string rebuild and measurement (U11).
- **Fix:**
  - Move to `@Observable` (macOS 14) or split into small observable objects.
  - Put `swipeAmount` in its own object read only by the offset and the chevron.
  - Publish `railShown` only when the 1100 pt threshold is crossed.
  - During the divider drag, hold the width in `@State` and commit it plus Defaults in `onEnded`.
  - Give `SidebarRow` a plain `count` value instead of `environmentObject`.
  - Assign `commentCounts` and `treeRevision` only when they change.

### U4. Every selection does several synchronous jobs on main

- **Workspace saves:** `persistWorkspace()` runs three times per selection (`AppState.swift:1380`, `:84`, `:1461`). Each JSON-encodes the full snapshot into UserDefaults, and `savedAnchors` grows without bound.
- **Undo:** `recordWorkspaceChange` encodes two more snapshots with `.sortedKeys` (`:1950`).
- **Three renders:** the selection, then `comments`, then `sections` (`:1377-1378`).
- **Rail rebuilt:** `Rail` has `.id(file)` (`RootView.swift:277`), which tears down and rebuilds every `NSTextView`.
- **Fix:**
  - One debounced save (about 500 ms) that encodes off main, and an LRU cap of about 500 on `savedAnchors`.
  - Compare structs instead of encoding them for undo; skip undo for transient hops.
  - Publish comments and sections in one assignment.
  - Drop `.id(file)` and reset the rail's state in `.onChange(of: file)`.

### U5. Anchor changes trigger a workspace save and a full render

- **The chain:** `DocumentPane.anchor` `didSet` (`DocumentPane.swift:13-18`) → `AppState.anchor` `didSet` (`AppState.swift:79-86`).
- **Sources:**
  - Every `PDFViewPageChanged` (`PreviewPDF.swift:150-163`).
  - Once per second of media playback (`PreviewMedia.swift:94,166`).
  - Every caret line change (`TextDocumentEditor.swift:436,560-563`).
- **Fix:** keep the live anchor in the pane, read only by the chip view. Mirror it to `AppState` and persist after 300–500 ms of quiet.

### U6. Startup blocks first paint

- **The chain:** `applicationDidFinishLaunching` → `restoreLastVault()` → `open()` runs synchronously (`AppDelegate.swift:74`). `VaultSession.init` (`VaultSession.swift:80-97`) then opens `IndexStore` on main.
- **What the open includes:**
  - WAL recovery and migrations.
  - When `Extract.version` changes, `UPDATE files SET size = -1`: 0.19 s at 35.5k rows, so about 5 s at 1M rows, once per extractor update.
  - Busy retries of up to 100 × 10–30 ms.
- **Measured:** 160–286 ms worst main-thread lag in the first 10 s on `big`.
- **Fix:** show the window first, build `VaultSession` in `Task.detached` (the stores are `Sendable`), and assign the result on main. Load the restored expanded folders asynchronously (U7).

### U7. Folder listing on main, repeated on every watcher batch

- **Where:** `FileTree.load`/`refresh` → `VaultScanner.children`, called from the outline data source (`Sidebar.swift:564-573`, `FileTree.swift:115-130,193`). Date sorts also call `resourceValues` per file (`FileTree.swift:211-215`).
- **Measured:** 374 ms before, 163 ms now, for the 30.5k-entry folder.
- **Watcher fan-out:** each batch (every 0.55–3 s) on main:
  - Bumps `treeRevision`, which re-lists loaded folders, reloads FolderSurface and re-queries the related panel.
  - Republishes `commentCounts`.
  - Calls `sidebarSearch.refresh()` (`AppState.swift:1193`) even with an empty query and the Search tab hidden. That runs a full `unifiedSearch`, including U2's tree walk.
- **Fix:**
  - List in `Task.detached`, then `reloadItem(node, reloadChildren: true)`, diffing before reload.
  - Refresh search only when the query is non-empty and the tab is visible.

### U8. Sidecar and other store work on main

- **Sidecar calls:** `changeComments`, `restoreComments`, `attachInboxThought`, `relocate` and `applyIndexedRenames` call `SidecarStore` synchronously (`AppState.swift:1585-1590,1073`). My Core change shortens the lock they can wait on, but they still do disk I/O plus `flock` on main.
- **Relocate:** `relocate` (`:941-985`) also runs `sidecarRefs()`, `trail.reconcile` (`io.sync`, a full trail read and rewrite), and the connection and alias reconciles on main.
- **File-list rewrites:** `setFiles(Array(Set(files.map…)))` runs once per rename (`:1097`): four O(N) passes per move.
- **Fix:** route everything through `VaultSession.onStore` or `filesQueue`, and apply renames as one batch.

### U9. Wikilink resolution in the UI

- `openLink` (`AppState.swift:1405-1406`) is now about 2 ms per call (Core fix).
- Still: build one `Wikilink.Resolver` off main per `filesVersion` and reuse it. A warm `resolve` is about 1 µs, which covers the rail and Trail.

### U10. Graph mode (`GraphModel` / `GraphView`)

- **Opening Graph mode (bench, 37k nodes):**
  - `GraphModel.init` takes 76 ms on main, including `GraphTopology` (88 ms standalone).
  - `LayoutStore.load` decodes on main: 41 ms for a 3.5 MB layout. This applies to graphs of 10k nodes or fewer; the layout file keeps every node from every view.
  - `GraphOverviewLayout.initial` takes 23 ms.
  - The unscoped model is built and then thrown away when `refreshScope` lands (`GraphModel.swift:137-145`).
  - **Fix:** start empty, as the deferred path already does, and prepare topology and layout off main.
- **Drawing:** `Canvas` draw takes 10 ms per frame at 37k nodes/124k edges at fit, before rasterisation, on main. Try `Canvas(rendersAsynchronously: true)`.
- **Per-frame extras in `advance`** (`GraphModel.swift:605-666`):
  - `detailOpacity` is mapped over all nodes, with string hashing for folders.
  - `fitCamera()` runs up to 3 times per frame.
  - **Fix:** cache `detailOpacity` by (zoom bucket, selection, chosen) and compute the fit once per frame.
- **`GraphGestures.swift` / `GraphInputView.swift`** (now UI-owned): no perf problems found.
  - Scroll and magnify are O(1) per event.
  - Hover calls `GraphModel.node(atScreen:)`, which is O(N) but measured 0.3 ms per mouse move at 37k nodes.
  - Nothing to change for performance.
  - Separately, HANDOVER item 5: `GraphInputNSView` takes first responder when it enters a window.

### U11. Rail, capture, Trail, Ask, previews

- **Comments rail:**
  - `rows` sorts in the body inside a non-lazy `VStack` (`CommentsRail.swift:84-100`).
  - `RailRichText` rebuilds its attributed string and runs a full TextKit layout in both `updateNSView` and `sizeThatFits` (`RailRichText.swift:39-47`).
  - **Fix:** cache the string and height per (id, text, width); use `LazyVStack`.
- **`[[` completion:**
  - `LinkMatcher` is rebuilt on every panel open (`CommentPanel.swift:96-102`), creating four `[Character]` arrays per file.
  - Each keystroke does a full O(N·L) scan with no debounce, and cancelling doesn't stop it (`LinkCompletion.swift:8-13,87-134`, `ThoughtTextView.swift:56-58`).
  - **Fix:** one byte-level matcher per `filesVersion`, a 50 ms debounce, and a cancellation check inside the loop. HANDOVER item 4 says the same.
- **Capture from the frontmost app:** AX and AppleScript calls with 0.5–1 s timeouts, plus a title match across all files, run on main (`CaptureController.swift:149-150`, `FrontmostContext.swift:102-203`). Show the panel first and probe in the background.
- **Trail view:**
  - `filteredSessions` (`TrailView.swift:134-142`) runs per body evaluation and per keystroke, with no debounce.
  - `rows()` and `TrailMetrics.gutter` (`TrailTimeline.swift:21-95`) run per render.
  - **Fix:** precompute off main.
- **Ask streaming:** each token re-renders the whole answer through `MarkdownLite`, which is O(n²) (`AskView.swift:189`, `AnswerText.swift:18`). Throttle to about 30 Hz.
- **Previews and menus:**
  - `PDFDocument(url:)` is created on main in `updateNSView` (`PreviewPDF.swift:98`).
  - `MainMenu.validateMenuItem` does a LaunchServices lookup (`MainMenu.swift:274`).
  - The `ExactSourceReader` picker holds one item per section (`DocumentSurface.swift:88-94`).

### Already fine

- The file walk and listing patches run on `filesQueue`.
- Comments and sections are read on `storeQueue`.
- Palette and sidebar queries are debounced and cancellable.
- The force simulation runs on its own thread: 26 ms per tick at 37k nodes, 7 ms at 10k.
- The renderer is batched and culled, and `LabelPlacer` doesn't allocate per frame.
- The timeline pauses when idle.
- Main-thread lag stayed under about 60 ms during a cold index, both before and after my changes.

## Things I deliberately did not change

- **The extract-version stale marking at open** (`UPDATE files SET size = -1`). Making it lazy would change retry semantics. Moving the open off main (U6) is the right fix.
- **`writeLock` during extraction.** `updateImpl` holds `writeLock` while a batch extracts, so a thought's index update can wait for one batch (seconds when it is OCR-heavy). The rail is unaffected because it reads the sidecar. Splitting extraction out of the lock is a larger reliability change.
- **Compaction write cost on very large indexes.** After a full reindex, compaction rewrites the FTS b-trees once. That is several GB of writes on a whole-home index, run in the background at utility QoS, and it stops whenever a write arrives.
