# Plan 08 — Design system and brand

**You own:** `Sources/FlamingoDesign/`, `Resources/Assets/` (create it).
**Read first:** `DESIGN.md`. You are its keeper. `Theme` token *names* and the component
signatures in `Components.swift` are frozen; their values and bodies are yours.

## Mission

Make Flamingo look like Apple shipped it and Obsidian users feel at home. Tokens, components,
the file glyph set, the app icon, and a design review of every other session's views near
the end.

## Milestones, in order

### M1 — Tokens
- Real values for `Theme.Color` in light and dark. Dark surfaces near `#1C1C1E` / `#161618`,
  raised `#232326`, hairline white at 8%. Light: system window colors, hairline black at 8%.
  Accent: a flamingo coral that passes contrast on both. Add `Theme.Color.family(ext:)`
  returning one of nine muted family hues (deck, document, sheet, pdf, image, media, model,
  code, note) at low saturation, for graph nodes and glyph tints.
- `Theme.Font`: confirm sizes and add `.caps` (11pt medium, tracking 0.6) for the rare
  section marker. `Theme.Space`, `Radius`, `Motion` as in DESIGN.md.

### M2 — Components (keep existing signatures, add new ones)
- `FileGlyph(ext:size:)`: SF Symbol per family, tinted by `family(ext:)`. Table of ~60
  extensions → family.
- `Hairline()` horizontal and `VHairline()`.
- `Chip(text:mono:)` for anchors (`slide 7`), `KeyHint("⌘K")`, `EmptyState("No vault open")`
  (single tertiary line, centered), `PanelChrome { content }` for floating panels (sidebar
  material, hairline, radius l, shadow), `SegmentedModes(selection:)` with four SF symbols for
  files/graph/trail/ask (no text), `SearchField(text:)` with no placeholder, `ProgressHairline(value:)`.
- `View.flamingoRow(selected:)` modifier: 26pt row, selection background with `Theme.Radius.s`.
- A `DesignPreview` SwiftUI preview page that shows every component in light and dark so a
  screenshot of it is the style guide.

### M3 — App icon
- A flamingo mark: single-color silhouette or a two-tone abstraction, macOS-style rounded
  rect with subtle gradient, no text. Draw it in code with CoreGraphics in a small Swift
  script (`Resources/Assets/make-icon.swift`) that renders 16–1024 PNGs and builds
  `AppIcon.icns` with `iconutil`. Commit the icns. Plan 10 copies it into the bundle.
- A 22pt menu bar template icon of the same mark for later.

### M4 — Design review
- Once other sessions have views (check `Sources/Flamingo`, `FlamingoCapture`, `FlamingoGraph`,
  `FlamingoTrail`, `FlamingoAsk`), run the app, screenshot each mode, and write
  `plans/DESIGN-REVIEW.md`: per view, what violates DESIGN.md and the exact fix. File each
  fix as a request in `plans/REQUESTS.md` addressed to the owning session. Do not edit their files.

## Done means
Every view in the app uses only `Theme` tokens and your components. The icon in the Dock
looks like it belongs next to Finder and Notes. The design review has been filed.

## Don't
- No illustration, no gradients beyond the icon, no custom fonts.
