# Issues

What QA found running `make demo` on the Kestrel Works vault. Each line names the owning
plan. Owners tick their own lines; session 10 re-checks every loop and removes what's fixed.
Screens are in `docs/screens/`.

## Open

### Pass 1 — 22:45
- [ ] (01) The shell is still the 22:02 scaffold. On the demo vault the sidebar is a flat list of names with no folders: `decks/`, `docs/`, `finance/` and the rest are flattened. Selecting a file shows no preview. There is no comments rail and no mode switcher. ⌘O "Open Vault…" is in the File menu but opens no panel. ⌘1–4, ⌘K, ⌘⇧C and arrow-key selection do nothing. See `docs/screens/files.png`.
- [ ] (01) The sidebar opens at about 360pt, the `maxWidth`. DESIGN.md says 240pt.
- [ ] (05, cc 04) The index has no file text, only comments. `flamingo-index <copy of fixtures/vault>` reports "19 extracted · 26 sections", but `--text` is empty for pptx, docx, xlsx and even `notes/open-questions.md`. `legal/supplier-agreement.pdf` shows `(page 1)`…`(page 4)` with no words. `--search clamp` finds only the two comments, not the brief, slides 6 and 10, or the open-questions note. The path having a space is not the cause; a copy at `/…/kestrel` behaves the same. FlamingoExtractTests pass, so the loss is between `Extract.extract` and the FTS rows, or in how `--text` reads them back.
- [ ] (07) FlamingoTrailTests: `testCompleteLastLineWithoutNewlineIsReadOnce` fails at `TrailStoreTests.swift:128` (events after `record`+`flush` are `[]`), then crashes on `after[0]`. That makes `scripts/test.sh` exit 1.
- [ ] (04) Heads-up: Quick Look thumbnailing of any `.usdz` (ours, and Apple's `shaderball.usdz`) never returns from `qlmanage -t` here. If `Thumbnails` uses `QLThumbnailGenerator` for usdz, give it a timeout and fall back to the glyph so the graph and trail don't wait on it.

## Working
- Build is green. Every test bundle except Trail passes: Core, Extract, Index, Graph, Ask.
- The bundle has its icon and asset catalog from 08, a hardened-runtime ad-hoc signature, and the Apple Events entitlement.
- Index CLI on the demo vault: 23 comments indexed, comment search with anchors and highlights, backlinks for `finance/q3-model.xlsx` (2), and a 19-node, 19-edge link graph built in 0.05s.
- File glyphs from 08 render tinted per family in the sidebar.
