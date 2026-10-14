# Flamingo — Design

The reference points are the macOS Finder and Preview, Obsidian's default theme, and
Premiere's panel system. Dark-first. Content fills the window. Chrome recedes.

## Principles

1. **If a label can be removed, remove it.** A list of files does not need a header that
   says "Files". A comment field does not need a placeholder that says "Type a comment".
   The cursor blinking in an empty field is the affordance.
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

## Tokens

Use `Theme` from `FlamingoDesign`. Never hardcode a color, font, or spacing in a view.
If the token you need doesn't exist, ask plan 08 via `plans/REQUESTS.md` and use the
closest existing one meanwhile.

## Layout

```
┌─────────┬────────────────────────────────────┬──────────┐
│ sidebar │ content (preview / graph / trail / │ comments │
│  240pt  │  ask)                              │  rail    │
│         │                                    │  280pt   │
└─────────┴────────────────────────────────────┴──────────┘
```

Titlebar is transparent; the traffic lights float over the sidebar. A segmented control
in the toolbar area switches mode (⌘1–4). The command palette (⌘K) and comment panel
(⌘⇧C) are floating panels centered in the window, 560pt wide, with the sidebar material
and a hairline.

## Before you ship a view, check

- Is there any text on screen that isn't the user's own data or a file name? Justify it.
- Does it look right in both light and dark? Toggle with System Settings.
- Does it look right at 1000×600 and at full screen?
- Could a Finder user guess what every control does without a label?
