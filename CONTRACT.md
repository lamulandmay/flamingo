# Flamingo — Contract

Flamingo is Obsidian for every file on your Mac. Open a folder, preview anything
(pptx, docx, xlsx, pdf, usdz, images, video, code, markdown) with Quick Look, press a
key to leave a thought on it, link thoughts with `[[wikilinks]]`, and see the graph of
how your real work connects. Flamingo never writes into your files. Everything it
knows lives in `<vault>/.flamingo/` as plain text you could read with `cat`.

What makes it better than Obsidian: it sees all your files, not just markdown, and it
builds thought chains from what you actually did (trails) instead of only from links
you remembered to type.

Ten sessions build this in parallel. This file is the one thing everyone reads first.

## Rules of engagement

1. **Read your plan.** `plans/NN-*.md`. It tells you what you own and what is frozen.
2. **Own your directory.** You only create or edit files under the paths your plan lists.
   Never touch another session's directory, `Package.swift`, or this file.
3. **Public API in the stubs is frozen.** You may add public API. You may not rename,
   remove, or change the signature of anything already public. Other sessions are
   coding against it right now.
4. **Keep the build green.** Run `scripts/build.sh` before you consider any milestone
   done. If it is red because of *another* module, do not fix their file. Note it in
   `plans/REQUESTS.md` and keep going.
5. **Need something from another module?** Append to `plans/REQUESTS.md`:
   `- [ ] (from 03 → 02) SidecarStore needs a `comments(matching:)` query`. Check that file
   every milestone for requests addressed to you. Do them; tick them.
6. **No git commits** except session 10. Everyone else just leaves files in place.
7. **Toolchain.** Build with `scripts/build.sh`, test with `scripts/test.sh`, run with
   `scripts/run.sh`. They set `DEVELOPER_DIR` to Xcode-beta, which has the SwiftUI
   macro plugin the Command Line Tools lack. A bare `swift build` will fail on `@State`.
8. **Zero external dependencies.** SQLite via `import SQLite3`, zips via `/usr/bin/unzip`,
   hotkeys via Carbon or `NSEvent`, graphs via `Canvas`. Apple ships everything we need.
9. **Subagents are encouraged.** Fan out research, parallel implementations of independent
   files, and review. You remain responsible for integration and for the build.
10. **Read DESIGN.md before writing any view.** No placeholder copy, no labels that restate
    the obvious, no emoji, no "Welcome". If a label can be removed, remove it.

## Module map

| Module | Path | Plan | Depends on |
|---|---|---|---|
| `Flamingo` (app) | `Sources/Flamingo` | 01 | everything |
| `FlamingoCore` | `Sources/FlamingoCore` | 02 | — |
| `FlamingoCapture` | `Sources/FlamingoCapture` | 03 | Core, Design, Trail |
| `FlamingoExtract` | `Sources/FlamingoExtract` | 04 | Core |
| `FlamingoIndex` + CLI | `Sources/FlamingoIndex`, `Sources/FlamingoIndexCLI` | 05 | Core, Extract |
| `FlamingoGraph` | `Sources/FlamingoGraph` | 06 | Core, Design |
| `FlamingoTrail` | `Sources/FlamingoTrail` | 07 | Core, Design |
| `FlamingoDesign` | `Sources/FlamingoDesign` | 08 | — |
| `FlamingoAsk` | `Sources/FlamingoAsk` | 09 | Core, Index, Design |
| build, fixtures, QA | `scripts/`, `Resources/`, `fixtures/`, `README.md`, `ISSUES.md` | 10 | — |

Tests live in `Tests/<Module>Tests` and belong to the module's session.

## Core types (frozen, in `FlamingoCore`)

- `Vault(root:)` — a folder. `stateDir` is `<root>/.flamingo`, `notesDir` is `<root>/.flamingo/notes`.
- `FileRef(relativePath:)` — identity of a file within a vault. `.name`, `.ext`.
- `FileAnchor(kind:value:)` — a place inside a file. Kinds: `page slide sheet cell time line node region`.
  Rendered `(slide 7)`, `(cell Q3!B12)`, `(time 1:23)`. Named `FileAnchor` because SwiftUI owns `Anchor`.
- `Comment(id:timestamp:anchor:text:)` — one thought. `.links` are the wikilink targets in `.text`.
  `.provenance` says who wrote it; `.meta` (`ThoughtMeta`) carries `uid`, thread `parent`, kind, state, due.
- `SidecarStore(vault:)` — reads/writes comments. `comments(for:)`, `append(_:to:)`, `update`, `delete`, `all()`.
  Background writers address a thought by uid: `comment(uid:in:)`, `update(uid:in:_:)`, `appendReply(_:toUID:in:)`.
- `Wikilink.parse(_:)`, `Wikilink.resolve(_:in:candidates:)`.
- `Graph { nodes: [Node], edges: [Edge] }` — `Node.id` is the relative path. `Edge.kind` is `link` or `trail`.
- `VaultScanner.files(in:)` — every user file, packages treated as single files.
- `FileIdentity.id(for:)` — UUID in xattr `com.flamingo.id`, survives rename.

## On-disk formats

Everything under `<vault>/.flamingo/`. Never anywhere else. Never inside user files.

### Sidecar notes — `.flamingo/notes/<relative/path/file.ext>.md`

```
---
target: decks/q3.pptx
id: 6F9619FF-8B86-D011-B42D-00C04FC964FF
---
- [2026-10-14 22:05] (slide 7) Pricing contradicts [[q3-model.xlsx]]
- [2026-10-14 22:09] Needs a better title
  Second line of the same comment is indented two spaces.
```

- Timestamp `yyyy-MM-dd HH:mm` local time. Anchor optional. Text may be multi-line.
- Wikilinks: `[[target]]`, `[[target|alias]]`, `[[target#slide 3]]`. Target resolves by relative
  path, then basename, then basename without extension.
- Obsidian can open this folder as a vault and the links work. That is intentional.

#### The hidden metadata line

A thought may carry one more line, indented two spaces, an HTML comment Obsidian does not show:

```
- [2026-10-16 18:40] (slide 7) review conflict between this and [[q3-model.xlsx]] before friday
  <!-- flamingo: {"intent":{"action":"review-conflict","objects":["decks/q3.pptx#slide 7","finance/q3-model.xlsx"]},"kind":"intent","kindBy":"model","origin":"human","uid":"t8m2k4q9xa"} -->
```

- One line per thought: a single JSON object with sorted keys that merges where the thought came
  from (`origin` `human`|`ai`, `model`, `appBundleID`, `appName`, `windowTitle`, `sourceURL`,
  `reason`), what Flamingo has decided about it, and any keys a newer build added (kept as they are).
- **It always has `origin`**, even for a thought typed by a person (`"origin":"human"`). Builds
  from before this line existed read it as provenance, which keeps it out of the thought's text.
  `>` is written `\u003e`, so `-->` never occurs inside it.
- Any hidden line under a thought is metadata, never text. A line that is not a JSON object is
  kept as it is.
- Keys: `uid` (`t` + nine Crockford base32 characters, stable when the text is edited),
  `parent` (the uid of the thought this answers), `kind` (`idea` `question` `todo` `intent`) and
  `kindBy` (`rules` `model` `user`), `state` (`open` `done` `snoozed` `dismissed`) and `stateAt`,
  `due` and `snoozeUntil` (`yyyy-MM-dd` or `yyyy-MM-dd HH:mm`), `modified`, `intent`
  (`action`, `objects`, `confidence`, `model`, `at`), `work` (a memo path relative to `.flamingo`).
- Only decisions are written. The kind and due date Flamingo reads from the words are worked out
  again from the text whenever they are needed. A thought gets a `uid` the first time something
  refers to it; notes are never rewritten in bulk.
- Comment ids are still derived from the content and never include the metadata line.

#### Threads

A reply is its own top-level bullet, placed right after the last reply under the thought it
answers, with `parent` set to that thought's `uid`. Nothing nests. Obsidian shows consecutive bullets.

#### Notes with no file behind them

- `_inbox/<yyyy-MM-dd>`: thoughts captured with nothing in front.
- `_web/<host>/<slug>-<hash6>`: thoughts about a web page, in `.flamingo/notes/_web/<host>/<slug>-<hash6>.md`,
  with `url:` and `title:` in the front matter (`hash6` is six hex digits of a stable hash of the URL).
- `<folder>`: thoughts about a folder, in `.flamingo/notes/<folder>.md` with `subject: folder` in the
  front matter. It cannot clash with a file's note: the file `x.md` has `x.md.md`.
- Selected text from another app is part of the thought, as indented `> ` quote lines.

### Work memos — `.flamingo/work/`

What the night shift (or "Work on this") writes about a thought, as Markdown Obsidian can read:
`.flamingo/work/<yyyy-MM-dd>/<slug>.md`. Front matter: `flamingo: memo`, `thought` (the uid), `on`,
`recipe`, `verdict`, `sources` (each `path#anchor · modified`), `model`, `provider`, `tokens`,
`created`; then `# title` and the memo. `.flamingo/work/ledger.jsonl` is the append-only record
of that work, one JSON object per line. The thought it answers gets a reply whose visible text
carries the summary and `[[links]]` to the sources and whose hidden `work` key names the memo.
Thoughts are only ever read by models running on this Mac.

### Index — `.flamingo/index.sqlite`
SQLite with FTS5. Schema is plan 05's. Other modules only use `IndexStore`.

### Graph — `.flamingo/graph.json`
`Graph` encoded with `JSONEncoder` (sorted keys). Rebuilt by `IndexStore.buildGraph`.

### Trail — `.flamingo/trail.jsonl`
One `TrailEvent` JSON per line, append-only. `opened`, `commented`, `searched`, `linked`.

## Keyboard map (shared between plans 01, 03, 08)

| Keys | Action |
|---|---|
| ⌘O | Open vault |
| ⌘K | Command palette: quick open any file, run any command |
| ⌘F | Search the vault |
| ⌘⇧C | Leave a thought on the current file (in-app) |
| ⌃⌥Space | Leave a thought from any app (global, opt-in, needs Accessibility) |
| ⌘1 ⌘2 ⌘3 ⌘4 | Files, Graph, Trail, Ask |
| ⌘⌥I | Toggle the comments rail |
| ⌘[ ⌘] | Back, forward |
| ⌘↑ ⌘↓ or ⌥↑ ⌥↓ | Previous/next anchor (page, slide) in the preview |
| ⌘⌥ (hold) | Recent files: a ring around the pointer; flick toward one, release to open it |
| ⌘\ | Split view: the file again beside itself, or back to one pane |
| ⌃⌥⌘1–5 | Layouts: single, two side by side, three columns, one and two, four |
| ⌥⌘→ ⌥⌘← | Next, previous pane |
| Esc | Dismiss |

## How the shell wires things (so you know where your work shows up)

`AppState` (plan 01) holds `vault`, `files`, `selected`, `anchor`, `mode`. On vault open the
shell creates `SidecarStore`, `IndexStore`, `TrailStore`, `VaultWatcher`, starts a reindex, and
hands `CaptureController.shared` closures for `currentTarget` and `onComment`. Mode views:
`GraphView`, `TrailView`, `AskView`. The right rail is `CommentsRail`. Preview is Quick Look,
with `PDFView` for PDFs and `AVPlayerView` for media so anchors can be tracked.
