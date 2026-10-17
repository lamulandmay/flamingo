# Flamingo — Design

The reference points are the macOS Finder and Preview, Obsidian's default theme, and
Premiere's panel system. Dark-first. Content fills the window. Chrome recedes.

## Principles

1. **If a label can be removed, remove it.** A list of files does not need a header that
   says "Files". A comment field does not need a placeholder that says "Type a comment".
   The cursor blinking in an empty field is the affordance. One exception: the Thoughts
   tab's composer reads "Thought on q3.pptx". Unlabeled, people couldn't tell it was where
   thoughts are written.
2. **No copy that talks to the user.** No "Welcome to Flamingo". No "Get started by…".
   No "No results found 😔". Empty states are either nothing, or one short noun phrase in
   tertiary color ("No vault open"). No exclamation marks. No emoji anywhere.
3. **One accent.** Flamingo coral (`Theme.Color.accent`) appears only for the selection,
   focus ring, links, and the single primary action on screen. Everything else is grey.
   Never colored text for decoration.
4. **Hairlines, not boxes.** Separate regions with 1px hairlines or material changes, not
   borders and cards. Panels are flat.
5. **System type, three weights.** SF Pro via `.system`. 13pt body, 11pt secondary, 15pt
   semibold for the rare title. Regular, medium, semibold. Monospace for paths and anchors.
6. **4pt grid.** Spacing from `Theme.Space`. Radii from `Theme.Radius`.
7. **Motion is 150–220ms ease-out.** Nothing springs, bounces, or slides in from offscreen.
   Hover states change opacity, not size.
8. **Keyboard first.** Every action has a key. Key hints are shown in menus and the command
   palette only, never as on-screen badges.
9. **Density like Finder, not like a web app.** 24–28pt rows. Sidebar uses the sidebar
   material. Content is opaque.
10. **Monochrome SF Symbols.** Icons at 13–14pt, `secondary` color, `accent` when selected.
    The one exception is file glyphs and graph nodes. They carry a muted family tint
    (`FileGlyph`, `Theme.Color.family(ext:)`) so a deck and a sheet can be told apart at a glance.

## Tokens

Use `Theme` from `FlamingoDesign`. Never hardcode a color, font, or spacing in a view.
If the token you need doesn't exist, ask plan 08 via `plans/REQUESTS.md` and use the
closest existing one meanwhile. Every color is dynamic: light, dark, and both Increase
Contrast variants. AppKit code (`NSTextView` attributes, `CALayer`s, `NSPanel`s) uses the
same values through `Theme.NS`, never `NSColor.labelColor` and friends.

| Token | Use |
|---|---|
| `Color.accent` | Coral. Dark `#FF7A88`, light `#D23B57`. Both pass 4.5:1 on `bg`. Selection, focus, links, one primary action. |
| `Color.bg` / `bgRaised` / `bgSunken` | Content `#1C1C1E` (white in light). Raised `#232326` for in-window popovers and toasts. Sunken `#161618` for canvases. |
| `Color.text` / `textSecondary` / `textTertiary` | 88 / 56 / 36% white (86 / 55 / 36% black in light). |
| `Color.hairline` | White 8% (black 8% in light). |
| `Color.selection` | Accent at 26% (16% in light). Text on it stays `text`. |
| `Color.fill` / `hover` | Translucent greys for fields, chips, row hover. They work on material and on `bg`. |
| `Color.onAccent` | Text on a solid accent fill (rare). |
| `Color.thought(level)` | A saved thought's strength: blush (spark), the accent (solid), flamingo (woven). Only while a new connection is shown off: its line, the drop at its head, the rings on both ends. |
| `Color.family(ext:)` | Nine muted hues: deck, document, sheet, pdf, image, media, model, code, note. `FileFamily(ext:)` gives the family itself. |
| `Font.body` 13, `small` 11, `title` 15 semibold | Text. `bodyMedium` for emphasis. |
| `Font.mono` 12, `monoSmall` 11 | Paths, anchors, the target line under the comment field. |
| `Font.caps` + `capsTracking` | The rare section marker. Use `SectionMarker("Pinned")` or `.capsStyle()`. |
| `Space` xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32 | Everything. |
| `Radius` s 4 · m 8 · l 12 | Rows and chips, fields and toasts, panels. Draw every rounded shape as `Squircle(radius:)` (continuous curvature: cubic Béziers, zero curvature at the edges, peak at the 45° apex), never `RoundedRectangle`, `cornerRadius` or an arc. A shape nested with uniform padding inside another is `ConcentricSquircle(parentRadius:padding:)`, the parent's outline offset along its normals, never a smaller copy. AppKit uses `NSBezierPath(squircleIn:radius:)` and `CALayer.applySquircle`. |
| `Motion.fast` 150ms, `normal` 220ms | Ease-out. `fastSeconds` / `normalSeconds` for AppKit. |
| `Size.row` 26 · `sidebar` 240 · `rail` 280 · `panel` 560 · `icon` 14 · `iconSmall` 13 | Layout. |
| `Opacity.rest` .75 · `dimmed` .3 · `disabled` .35 | Hover raises `rest` to 1. Graph and faded history use `dimmed`. |

## Components

Use these before drawing your own. `DesignPreview()` in `FlamingoDesign` shows all of them
in light and dark. Screenshot it and you have the style guide.

| Component | What it is |
|---|---|
| `Hairline()` / `VHairline()` | 1pt separators. |
| `FileGlyph(ext:size:)` / `FolderGlyph(size:)` | Family symbol, family tint. Turns accent inside a selected `flamingoRow`, or pass `selected:` in native rows. Fixed width so names align. AppKit cells use `FileGlyph.nsImage(ext:)` tinted with `Theme.NS.family(ext:selected:)`. |
| `.flamingoRow(selected:)` | 26pt row, `Space.s` inset, hover fill, accent-tinted selection, `Radius.s`. For custom lists. A native `List` draws its own selection, which is coral too via the bundle's `AccentColor`. |
| `Chip(text:mono:action:)` | Anchors and tags: `slide 7`. Mono by default. With `action` it's clickable. |
| `KeyHint("⌘K")` | Menus and the command palette only. |
| `EmptyState("No vault open")` | One tertiary line, centered. |
| `SectionMarker("Pinned")` | 11pt medium, tracked, uppercase, tertiary. Rare. |
| `PanelChrome(width:shadow:) { … }` | Command palette, search, comment panel: sidebar material, `Radius.l`, hairline, shadow. In an `NSPanel`, pass `shadow: false`. |
| `VisualEffect(material:blending:state:)` | `NSVisualEffectView` for SwiftUI. Sidebar background. |
| `SegmentedModes(selection:)` | Three symbols (`FlamingoMode.views`: files, graph, trail), no text, accent when selected. `.ask` is the inspector's Chat tab. `FlamingoMode.title` and `.key` feed menus. |
| `SearchField(text:focused:onSubmit:onExit:)` | No placeholder. Accent focus ring. |
| `IconButton(_:help:isOn:action:)` | 13pt symbol. `help` is the tooltip and VoiceOver label, never drawn. |
| `ProgressHairline(value:)` | 2pt accent line. Fades at 1. `nil` pulses. |
| `Toast(_:action:perform:)` | One line, at most one action (`Undo`). |
| `.focusRing(_:radius:)`, `.pointingHandCursor()`, `.capsStyle()`, `.appearance(_:)` | Small modifiers. `.appearance(.dark)` pins a subtree for previews. |
| `FlamingoMark()`, `FlamingoMark.menuBarImage()` | The mark as a `Shape` and as a template `NSImage` for a status item. |

## Brand

The mark is a flamingo on one leg with an S-curved neck and a dark-tipped beak. It is drawn
in code (`FlamingoMarkPath`), and the same geometry makes the app icon, the menu bar
template and `FlamingoMark()`. The app icon is a white mark on a coral plate. That plate is
the only gradient in the product. `Resources/Assets/make-icon.swift` regenerates
`AppIcon.icns`, `Assets.car` (AppIcon + AccentColor), and `MenuBarIconTemplate.png`. The
asset catalog's `AccentColor` is what makes native controls (List selection, toggles,
focus rings, text selection) coral instead of system blue. It needs `NSAccentColorName`
in Info.plist.

## Layout

```
┌──┬─────────┬──────────────────────────────────────┬──────────────┐
│r │ sidebar │ content (files / graph / trail)      │ inspector    │
│i │ ⇔ 180–  │                                      │ ⇔ 260–720pt  │
│b │  480pt  │                                      │ thoughts ·   │
│  │         │                                      │ connections ·│
│  │         │                                      │ outline·chat │
└──┴─────────┴──────────────────────────────────────┴──────────────┘
```

Titlebar is transparent; the traffic lights float over the sidebar. Both sidebars put their
tab icons in the title bar row and resize by dragging their hairline (double-click resets).
The toolbar switches between three views (⌘1–3). Chat is not a view: it is the inspector's
last tab, reachable from every view with ⌘4. The command palette (⌘K) floats near the top of
the window like Spotlight; the comment panel (⌘⇧C) is centred, 560pt, sidebar material.

With no file open the content is the folder surface: Finder's column view (one list per
folder, the selection opening the next, a preview column for a file) or its icon view, toggled
by two icons in the toolbar. Finder's Favorites sit above the file tree, unlabelled, with
Finder's own glyphs. Column rows use real system icons, like thumbnails, because they are the
user's data.

*Recent files.* Hold ⌘⌥ for a moment: up to eight recent files form a ring around the pointer on a
round plate (a circle, because it is a dial, not a panel); flick toward one, let go to open it. Nothing highlighted, nothing opens. The hub names
the file, its folder and when you last touched it. A dot marks files you edited. Never labelled.

There is no status bar. Indexing shows as a 2pt accent line under the title bar; a warning
icon appears in the toolbar only when something needs attention (it opens Workspace Health).

## Connections

One pair of files is one connection; every reason is evidence on it.

- Explicit, drawn solid: a `[[link]]` written in a thought or note (either direction), or a
  connection made by hand (⌥-drag between graph nodes, + in the Connections tab, accepting
  a suggestion).
- Suggested, drawn dashed: one file names the other, the two say similar things, one is a
  copy or likely version of the other, or they were opened in the same sessions. A suggestion is accepted (✓, becomes hand-made) or dismissed
  (×, hidden everywhere, stored in `.flamingo/connections-dismissed.json`).
- Folder containment is structure, drawn faint, and never listed as a connection.

A new connection is shown off once. Saving a thought that links files, or ⌥-dragging one
file onto another, draws the line in: in Graph the camera settles on the pair; anywhere else
a small graph appears in the top-right corner (of the window, or of the screen when the
thought came from another app), does the same, and goes. The line's tint is the thought's
strength (`ThoughtStrength`: a link, a reason, specifics). It leaves with one note and lands
with the rest, a tap with each (`Chime`); a thought that links nothing gets only the notes.
Hovering holds the corner graph; clicking it opens Graph on the file.

The Connections tab lists explicit connections, a hairline, then suggestions, each with the
line of evidence worth reading and the reasons as glyphs (link, pin, doc-on-doc, quote,
square-on-square, clock). Wander (dice) walks suggestions across the whole vault one pair at a time.

## Before you ship a view, check

- Is there any text on screen that isn't the user's own data or a file name? Justify it.
- Does it look right in both light and dark? Toggle with System Settings.
- Does it look right at 1000×600 and at full screen?
- Could a Finder user guess what every control does without a label?

The latest review of every view is in `plans/DESIGN-REVIEW.md`.
