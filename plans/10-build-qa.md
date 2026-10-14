# Plan 10 — Build, fixtures, QA, release

**You own:** `scripts/`, `Resources/Info.plist`, `Resources/Flamingo.entitlements`,
`fixtures/`, `README.md`, `ISSUES.md`, `Package.swift` (only to apply requests), and git.
**Read first:** `CONTRACT.md`. You are the only session that commits.

## Mission

Everyone else is heads-down in their module. You make sure the whole thing builds, runs,
and is demonstrable: a real `.app` with an icon, a demo vault full of real files, screenshots,
a README, and a commit history. You sweep `plans/REQUESTS.md` and unstick people.

## Milestones, in order

### M1 — Demo vault (first, others need it)
- `fixtures/vault/`: a believable small company folder. Create real files, not empty ones:
  - 2 pptx decks with 8–15 slides each, with titles and body text (use the `pptx` skill or
    python-pptx in a venv in the scratchpad; the output file is what matters).
  - 2 docx with headings and paragraphs. 2 xlsx with multiple named sheets and numbers.
  - 2 pdfs (export the docx via `textutil` + `cupsfilter`, or generate). 3 images, one with
    text in it. 1 short mp4 or m4a. 1 usdz (copy one from
    `/System/Library/...` or generate a cube with ModelIO). 4 markdown notes with wikilinks.
  - `.flamingo/notes/` with a dozen sidecars in the CONTRACT format, cross-linking files with
    anchors, and a `.flamingo/trail.jsonl` with two plausible sessions.
- `scripts/demo.sh` copies the fixture vault to the scratchpad and launches the app on it.

### M2 — A real bundle
- `Resources/Info.plist`: bundle id `com.flamingo.app`, name, version, `LSApplicationCategoryType`
  productivity, `NSAppleEventsUsageDescription` and `NSAccessibilityUsageDescription` strings
  (one sentence each, plain), `CFBundleIconFile` AppIcon, `CFBundleDocumentTypes` for folders.
- `Resources/Flamingo.entitlements`: not sandboxed (we need xattrs, Accessibility, FSEvents on
  arbitrary folders), hardened runtime, `com.apple.security.automation.apple-events`.
- `scripts/run.sh` copies the icns from `Resources/Assets/` when plan 08 produces it, signs
  with the ad-hoc identity and entitlements, launches. `scripts/release.sh` builds `-c release`,
  bundles, zips `build/Flamingo.zip`.
- `Makefile`: `make`, `make run`, `make test`, `make demo`, `make release`, `make clean`.

### M3 — Continuous QA
Every 15–20 minutes until the end:
- `scripts/build.sh && scripts/test.sh`. If red, find the module, append the exact error to
  `plans/REQUESTS.md` addressed to that plan. Don't fix their code.
- Sweep `plans/REQUESTS.md` for `Package.swift` requests; apply them.
- `git add -A && git commit -m "checkpoint: <what landed>"`. Only you commit.
- Launch on the demo vault, click through every mode, screenshot with
  `screencapture -l $(window id of Flamingo)` into `docs/screens/`. Log what's broken in
  `ISSUES.md` as a checklist with the owning plan number.

### M4 — Release
- `README.md`: one paragraph of what Flamingo is, one screenshot, the keyboard map, how to
  build (`make run`), where state lives (`.flamingo/`), Obsidian compatibility note. No
  badges, no roadmap, no "contributing".
- Tag `v0.1`. Zip in `build/`. Final `ISSUES.md` with what's left.

## Done means
A fresh clone, `make demo`, and a stranger sees the app, a vault full of real files, comments
on them, a graph, a trail, and can press ⌘⇧C and leave a thought.

## Don't
- Don't implement features. If something is missing, file it to the owner.
- Don't commit `.build/`, `build/`, or any `.flamingo/` outside `fixtures/`.
