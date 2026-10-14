# Plan 05 — Index and search

**You own:** `Sources/FlamingoIndex/`, `Sources/FlamingoIndexCLI/`, `Tests/FlamingoIndexTests/`.
**Read first:** `CONTRACT.md`. `IndexStore`, `SearchHit`, `VaultWatcher` are frozen.

## Mission

Everything in the vault, searchable in milliseconds, kept fresh without the user doing
anything, and the link graph built from sidecars and trails. SQLite with FTS5, FSEvents,
no dependencies.

## Milestones, in order

### M1 — The store
- `import SQLite3`. Open `<vault>/.flamingo/index.sqlite` with WAL. Migrate with a
  `user_version`. Tables: `files(path PRIMARY KEY, id, mtime, size, ext, title, indexed_at)`,
  `sections(path, anchor_kind, anchor_value, title, text)`, an FTS5 virtual table over
  sections (`content=sections`, tokenizer `unicode61 remove_diacritics 2`, prefix index),
  `comments(path, id, ts, anchor_kind, anchor_value, text)` with its own FTS5.
- `reindex`: scan with `VaultScanner`, skip files whose mtime+size are unchanged, extract
  with `Extract.extract` on a concurrent queue (4–8 wide), batch inserts in transactions of
  ~200. Report progress. Also ingest every sidecar via `SidecarStore.all()`.
- `update(_:)` and `remove(_:)` for incremental changes.

### M2 — Search
- `search(_:limit:)`: FTS5 `MATCH` with `bm25` ranking, boosting title and comment matches.
  Build the query so a plain phrase works, `"quoted"` works, and a trailing word gets a prefix
  `*`. Snippets via `snippet()` with `«` `»` markers. Return the best section's anchor so the
  shell opens at the right slide or page.
- Searching comments returns the comment's file and anchor.
- Also `recent(limit:)` and `files(matching: "fuzzy name")` for the command palette.

### M3 — Watcher
- `VaultWatcher`: `FSEventStreamCreate` on the vault root, latency 0.5s, file-level events,
  ignore `.flamingo/`. Coalesce into one `onChange([FileRef])` per burst. Detect renames via
  `FileIdentity` where possible so a renamed file keeps its row (update the path).
- When a sidecar changes (someone edited it in Obsidian), re-ingest comments for that target.

### M4 — Graph
- `buildGraph(extraEdges:)`: nodes = all files + orphan sidecar targets; `link` edges from
  every comment's `links` resolved via `Wikilink.resolve`, weight = count; merge `extraEdges`
  (trail edges from plan 07). Write `.flamingo/graph.json` with sorted keys. Return it.
- Also `backlinks(to:) -> [(FileRef, Comment)]` for the shell to show "mentioned in".

### M5 — CLI
- `flamingo-index <vault>` reindexes and prints a summary. `--watch` keeps running.
  `--search "q"` prints hits as `path  (anchor)  snippet`. `--graph` prints node/edge counts.
  Use it to validate everything above without the app.

## Done means
Index a folder with a thousand mixed files in under a minute, search returns in <20ms,
touching a file updates the index within a second, and `graph.json` shows edges for every
wikilink in every sidecar.

## Don't
- Don't link against anything but libsqlite3 that macOS ships. Don't parse file formats; call
  `Extract`.

## Subagent ideas
One on the SQLite layer and query building, one on FSEvents, one on the CLI and a benchmark
script. You own `IndexStore.swift`.
