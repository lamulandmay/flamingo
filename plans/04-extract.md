# Plan 04 — Extract

**You own:** `Sources/FlamingoExtract/`, `Tests/FlamingoExtractTests/` (including a
`Fixtures/` folder of small real files you create).
**Read first:** `CONTRACT.md`. `Extracted`/`Section`/`Extractor` are frozen.

## Mission

Turn any file on a Mac into text plus structure, so search finds the right slide and
comments can be anchored to it. Office formats parsed natively; everything else falls back
to Spotlight. Fast enough to index ten thousand files without the user noticing.

## Milestones, in order

### M1 — Office, natively
pptx/docx/xlsx are zip + XML. Use `/usr/bin/unzip -p file member` through `Process` to read
members, and `XMLParser`. No third-party libraries.
- **pptx**: one `Section` per slide, `FileAnchor(.slide, "N")`, title = the title placeholder's
  text, text = all `a:t` runs in reading order. Notes slides appended to the slide's text.
- **docx**: one `Section` per heading-delimited chunk (`w:pStyle` Heading1–3), anchor `.page`
  isn't knowable so use `.node` with the heading text; full text from `w:t` in order. Tables included.
- **xlsx**: one `Section` per sheet, `FileAnchor(.sheet, name)`, text = cells row-major with
  shared strings resolved, tab-separated. Cap at ~50k cells per sheet.
- Register them in `Extract.extractors` from a static initializer the shell can call
  (`Extract.registerDefaults()`; add it).

### M2 — Apple formats and PDF
- **pdf**: `PDFKit`, one `Section` per page, `.page`. Outline titles if present.
- **key/pages/numbers**: these are packages with a `preview.jpg` and an `Index.zip` of IWA
  protobufs. Don't parse IWA. Use the Spotlight fallback for text, and for Keynote get slide
  count from `Metadata/DocumentIdentifier`… if that's a rabbit hole, slide count via the
  number of `Data/st-*` thumbnails or just Spotlight. Time-box it.
- **md/txt/code**: direct read, `Section` per `#` heading (`.line` anchors with the line number).
  Code: `.line` per function is overkill; one section, full text.

### M3 — Spotlight fallback and media
- `SpotlightExtractor`: `mdimport -t -d2 <file>` prints the importer's attributes including
  `kMDItemTextContent`; parse that. Fall back to `mdls -name kMDItemTextContent -raw`. Also pull
  `kMDItemTitle`, `kMDItemAuthors`, `kMDItemKind`. This covers everything you didn't write.
- **images**: `Vision` `VNRecognizeTextRequest` for OCR when the image is larger than an
  icon. Store as text. Section-less.
- **audio/video**: `AVAsset` metadata (title, duration, chapters as `.time` sections). Optional:
  `Speech` transcription behind a flag, off by default.
- **3D (usdz, obj, stl, glb)**: `ModelIO` for mesh and material names, vertex/face counts. One
  section per named node (`.node`). Text = names + counts.

### M4 — Thumbnails and speed
- `Thumbnails.thumbnail(for:size:scale:)` via `QLThumbnailGenerator`, cached on disk in
  `<vault>/.flamingo/thumbs/<sha of path+mtime>.png`. Expose `Thumbnails.cachedURL(for:)`.
- Benchmark: extract a 200-slide deck, a 100-page PDF, a 20-sheet workbook. Each under a
  second. Run extraction on a background queue; never block the caller's thread longer than
  needed.

## Done means
`scripts/test.sh --filter FlamingoExtractTests` passes against your fixtures and asserts
specific slide titles, sheet names, page counts. `Extract.extract` on a random Downloads
folder never throws for unsupported types; it returns empty text instead.

## Don't
- Don't add package dependencies. Don't write into user files. Don't parse IWA.

## Subagent ideas
One agent per format. They're independent files. You own `Extract.swift` and registration.
