# Plan 03 — Capture

**You own:** `Sources/FlamingoCapture/`.
**Read first:** `CONTRACT.md` (keyboard map, sidecar format), `DESIGN.md`. Code against
`FlamingoCore` as it is now; plan 02 fills in the bodies.

## Mission

The signature interaction. Press a key, a quiet panel appears, you type a thought, press
Enter, it's gone and saved to the right file at the right slide. From inside Flamingo
first; from any app on the Mac second. This is the feature Obsidian cannot have.

## Milestones, in order

### M1 — The panel
- `CommentPanel`: a floating `NSPanel` (non-activating, `.hudWindow` off, sidebar material,
  hairline border, 560pt wide, grows with text up to ~8 lines). One text view. No title, no
  label, no buttons. The only chrome: a single tertiary line at the bottom showing the target
  file name and anchor in mono, e.g. `q3.pptx · slide 7`. Enter saves, Shift-Enter newlines,
  Esc cancels. Panel fades 150ms.
- `[[` triggers an inline completion list of vault files (use `VaultScanner.files` on the
  vault of the target). Arrow keys, Enter to complete. Matches on basename, fuzzy.
- `CaptureController.installInAppHotkey()` registers ⌘⇧C via a local `NSEvent` monitor and
  calls `show()`. `show()` asks `currentTarget()` for the file and anchor, presents the panel
  centered over the key window, and on submit calls `onComment(file, comment)`.

### M2 — Comments rail
- `CommentsRail`: the list of existing thoughts for the selected file. Each row: timestamp in
  tertiary small caps-free mono (`22:05`, or `Oct 12` if not today), anchor as a clickable
  mono chip (`slide 7`) that calls `onJump`, text with wikilinks rendered as accent-colored
  links. Double-click edits in place. Right-click or ⌫ deletes with no confirmation but a
  5-second undo toast (one line, bottom of rail). Newest at the bottom, auto-scroll to it.
- Empty rail is empty. Not "No comments yet".

### M3 — Global capture (the magic)
- `installGlobalHotkey()`: ⌃⌥Space via Carbon `RegisterEventHotKey` (works without
  Accessibility). Behind a UserDefaults flag `captureGlobal`; the shell may expose a toggle.
- `FrontmostContext.current()`:
  - frontmost app via `NSWorkspace.shared.frontmostApplication`.
  - document URL via Accessibility (`AXDocument` on the focused window). Needs the
    Accessibility permission; request it with `AXIsProcessTrustedWithOptions` and show
    nothing else, the system prompt is enough.
  - anchors via AppleScript for the apps that expose them: Keynote (current slide number),
    Preview (current page, via AX if scripting is unavailable), Pages (page), Numbers (active
    sheet + selection range → `cell`), Excel and PowerPoint (via their scripting dictionaries),
    QuickTime/Music (`time`), Xcode/VS Code (line, via AX value of the focused editor is
    hard; file-level is fine).
  - Return nil anchor when unknown. Return nil entirely if the document isn't inside any open
    vault (ask the shell for the list via a `vaults: () -> [Vault]` closure you add to
    `CaptureController`).
- When triggered globally, the panel appears over whatever app is frontmost without stealing
  focus from it longer than needed; on Esc or Enter focus returns to that app.

### M4 — Nice
- A capture with no vault file in front falls back to a daily note:
  `.flamingo/notes/_inbox/<yyyy-MM-dd>.md` in the most recently used vault.
- Attach a thumbnail of the current screen region? Skip unless trivial.

## Done means
In Flamingo: select a pdf, go to page 4, ⌘⇧C, type `see [[q3.pptx#slide 2]]`, Enter, it's in
the rail with a clickable `page 4` chip. In Keynote with a deck from the vault open on slide
7: ⌃⌥Space, type, Enter, and the sidecar now has `(slide 7)`.

## Don't
- Don't write sidecar files yourself. Call `SidecarStore` through the shell's `onComment`.
- Don't add buttons to the panel. Keys only.

## Subagent ideas
One agent per target app for the AppleScript anchor probes; they're independent and fiddly.
One agent on the panel UI. One on the `[[` completion.
