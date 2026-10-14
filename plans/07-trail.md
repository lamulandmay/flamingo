# Plan 07 — Trails

**You own:** `Sources/FlamingoTrail/`.
**Read first:** `CONTRACT.md`, `DESIGN.md`. `TrailEvent`, `TrailSession`, `TrailStore`,
`TrailView` are frozen.

## Mission

Thought chains that build themselves. Flamingo records what you opened, what you said
about it, and what you searched, then shows your work as a timeline of sessions: "Tuesday
afternoon: the Q3 deck, then the model, then three thoughts linking them." Obsidian needs
you to type links. Flamingo noticed.

## Milestones, in order

### M1 — Recording
- `TrailStore.record`: append one JSON line to `.flamingo/trail.jsonl`, buffered and flushed
  within a second, never losing the last line on quit (flush on `willTerminate`; the shell
  will call `flush()`, add it).
- `events(since:)`: stream the file, parse, filter. Must handle a corrupted last line.
- Privacy: an `enabled` flag in UserDefaults (`trailEnabled`, default on) checked in `record`.

### M2 — Sessions
- `sessions()`: cluster events into `TrailSession`s. A gap of more than 25 minutes starts a
  new session. Within a session, `files` are ordered by first appearance, de-duplicated.
  Collapse rapid-fire `opened` events (arrowing through a list) into the ones the user dwelt
  on for more than ~3 seconds. Tune the thresholds on your own usage.
- `edges()`: `trail` edges between files that were open in the same session, weight = number
  of sessions they co-occurred in, decayed by age (last week counts more than last year). Cap
  the fan-out so one 50-file session doesn't produce 1,225 edges; connect consecutive files
  and files that had comments.

### M3 — The view
- `TrailView`: a vertical timeline, newest session at the top. Each session is a row: time
  range in tertiary mono on the left (`Tue 14:05 – 15:40`), then the files as a horizontal
  row of small thumbnails (ask plan 04's `Thumbnails`) or glyphs with names, in order, connected
  by a hairline. Comments made in the session appear beneath their file, indented, in body
  text. Searches appear as mono `⌕ query` between files.
- Clicking a file → `onSelect(file, anchor)`. Clicking a comment → the file at the comment's anchor.
- A session can be collapsed to a single line. Today's sessions are expanded; older are collapsed.
- A chain can be named: double-click the time range to give the session a title, stored in
  `.flamingo/trail-names.json`. Named sessions are what people will call "thought chains".

### M4 — Resume
- "Resume" on a session (⌘R while a session row is selected, or a tiny ↻ glyph on hover):
  reopens the files of that session as the shell's history so ⌘[ ⌘] walk through them. Expose
  `TrailSession.filesToReopen` and let the shell do the opening.

## Done means
Use the app for ten minutes on a real folder, open the Trail mode, and see your last ten
minutes as a chain you'd recognize. Edges from `edges()` show up in the graph as dashed lines.

## Don't
- Don't record anything outside the vault. Don't record file contents.
- No "Activity", "History", "Timeline" headers. The timeline is self-evident.

## Subagent ideas
One on the store and clustering with tests on synthetic event streams. One on the view.
