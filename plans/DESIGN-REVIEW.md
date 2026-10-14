# Design review

Plan 08, 2026-10-14 23:15. Checked against DESIGN.md.

**Method.** The 23:13 build of the app ran as a separate copy (`com.flamingo.review`, dark
appearance forced for that process only) on a copy of `fixtures/vault`. I clicked through every
mode at 1200×760 and 1000×600, and opened the capture panel. Session 10's light screenshots in
`docs/screens/` cover light mode. Each module's public view was also rendered on its own,
light beside dark. Screenshots are in `Resources/Assets/design/review/`.

**Overall.** The app already looks like one product. Every module draws with `Theme` tokens.
There is no placeholder copy, no "Welcome", no emoji, and no exclamation mark. On-screen text
is limited to file names, the user's thoughts, timestamps and anchors, plus three justified
strings: "Deleted / Undo" and "Trail paused". Family tints, hairlines, the 13/11pt type scale
and the coral accent hold up in both appearances. The fixes below are mostly about focus,
selection, and narrow widths.

Every fix is also filed in `plans/REQUESTS.md` to its owner. Items session 10 already filed
are marked *(also in ISSUES.md)*.

---

## Shell — plan 01 (`files-dark.png`)

What's right: three columns at the designed widths, transparent titlebar, `SegmentedModes` and
`IconButton` in the toolbar, family-tinted glyphs, the rail on a hairline, and the content
opaque `bg`.

1. **The sidebar selection is inactive grey while the window is key.** The list isn't first
   responder after launch or after ⌘1, so the native selection never turns coral (the
   bundle's `AccentColor` is in place). DESIGN §3 and §10.
   *Fix:* make the sidebar the window's initial first responder, and focus it again when
   switching to Files. With SwiftUI, use `@FocusState` with `.focused($sidebarFocused)` on the
   `List`, set to true in `.onAppear` and on `mode == .files`. Draw glyphs with
   `FileGlyph(ext:selected:)` and `FolderGlyph(selected:)` so a selected row's glyph turns accent.
2. **The sidebar is flat.** *(also in ISSUES.md)* *Fix:* a tree from `VaultScanner.tree(in:)`,
   `FolderGlyph` for folders, rows at `Theme.Size.row`, no "Files" header.
3. **⌘K and ⌘F open nothing.** *(also in ISSUES.md)* *Fix:* when they land, use
   `PanelChrome { … }` (560pt, `Radius.l`, sidebar material, hairline), with
   `SearchField(text:onSubmit:onExit:)` on top, `Hairline()`, then rows with
   `.flamingoRow(selected:)`. Command rows end with a `KeyHint`, and nothing else in the panel
   is text you wrote: no header, footer or "No results". An empty result list is just empty.
4. **1000×600 leaves the content 480pt wide** (sidebar 240 + rail 280). The preview and the
   trail feel cramped. *Fix:* when the window is narrower than about 1100pt, hide the rail
   automatically. Bring it back when the window widens, unless the user toggled it with ⌘⌥I
   in the meantime. Alternatively let the sidebar shrink to 200pt first.
5. *(fixed in the 23:13 build)* The coral progress hairline that stuck under the toolbar is
   gone. Keep setting `state.indexProgress = nil` at the end of a reindex. The toolbar
   segment's coral focus ring after a capture (`docs/screens/capture.png`) should be gone
   with the new `.focusEffectDisabled()`. I didn't re-test it.

## Comments rail and capture panel — plan 03 (`rail-light-dark.png`, `capture-panel-dark.png`)

What's right: no empty-state copy, mono tertiary timestamps, anchor chips, accent links,
`PanelChrome` with the window's own shadow, one tertiary footer line, and a one-line undo
on a hairline. This is the best-aligned view in the app.

1. **Wikilinks wrap inside file names** ("pricing-↵memo.docx"). A link should break as a
   unit. *Fix:* in `RailText.attributed`, replace `-` with U+2011 (non-breaking hyphen) in
   each link run's display text, not the URL.
2. *Low.* `RailChip` duplicates `Chip(text:mono:action:)`, which now also truncates in the
   middle. *Fix:* `Chip(text: RailText.anchorLabel(a)) { onJump(a) }`, then delete `RailChip`.
3. *Low.* The in-place editor uses a 1pt accent stroke, while `SearchField` and the rest use
   `.focusRing(_:)`. *Fix:* `.focusRing(true, radius: Theme.Radius.s)` in place of the overlay.

## Graph — plan 06 (`graph-dark.png`)

What's right: `bgSunken` canvas, muted family nodes, hairline link edges and dashed trail
edges, 11pt secondary labels, every label visible now, and a filter field with no
placeholder.

1. **The selected file isn't highlighted.** With `arc-launch-plan.pptx` selected in the shell,
   Graph mode draws its node brown and no neighbor in accent. The renderer supports it
   (`Flag.selSet`), so the selection is probably lost when `model.select` runs before the
   nodes or layout exist. *Fix:* keep the requested selection and apply it once the
   model has nodes, and again whenever `graph` changes.
2. *Low.* On first show the graph fills about half the canvas, with wide empty margins.
   *Fix:* fit to view, with `Theme.Space.xl` padding, the first time a vault's graph is shown
   with no saved layout.
3. *Low.* The filter field can now be `SearchField(text:focused:onExit:)` (your request is
   done), which removes your copy of its styling.

## Trail — plan 07 (`trail-dark.png`, `trail-dark-1000x600.png`)

What's right: the session header in mono tertiary, a hairline spine, family glyphs standing in
for missing thumbnails, comments under their file with tertiary anchors, and no labels.

1. **`⌕` is a text character**, not a symbol (TrailTimeline.swift:452 and :515). It falls back
   to whatever font has it and doesn't match the magnifier in `SearchField`. *Fix:*
   `Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.Color.textTertiary)`
   beside `Text(query).font(Theme.Font.monoSmall)`.
2. **At 1000×600 the time gutter (about 170pt) squeezes the cards to about 300pt.**
   *Fix:* below about 640pt of available width, move the time range into the session's
   header row next to the chevron, drop the gutter column, and put the spine at `Theme.Space.l`.
3. **Wikilinks wrap inside file names.** Same fix as 03 #1: non-breaking hyphens in link runs.
4. **Raw anchor suffixes in links** (`interview-maya-chen.m4a#time 0:53`). *(also in ISSUES.md)*
   *Fix:* show the alias if there is one, otherwise `interview-maya-chen.m4a › time 0:53`,
   with the `› time 0:53` part in `textTertiary`.

## Ask — plan 09

What's right: no placeholder, no "Ask anything", answers in body type with accent citations,
cited files as chips.

1. **An empty Ask pane is a hairline under an invisible field.** *(focus is also in
   ISSUES.md)* DESIGN §1 relies on the blinking caret, so the caret has to be there.
   *Fix:* (a) make the field first responder on appear, and again when the main window becomes
   key while in Ask mode. (b) Don't draw the hairline until there is at least one exchange.
   An empty Ask is just a caret at the top of a reading column at most 640pt wide, inset
   `Theme.Space.xl`.
2. *Low.* The citation hover chip has a drop shadow (AnswerText.swift:62). Panels are flat
   (DESIGN §4). *Fix:* `Theme.Color.bgRaised` with a `Hairline` stroke at `Radius.s`, and no shadow.

## Not checked

- Full screen. Entering full screen in the review copy would have moved the user's Spaces.
- The ⌘K and ⌘F panels, which don't open yet.
- Increase Contrast. The tokens have high-contrast values; check them once the panels exist.
