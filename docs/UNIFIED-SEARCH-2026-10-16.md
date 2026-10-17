# Unified search, file families, and file handoff

Flamingo searches the folder you open as it already exists. There is no import, tagging,
renaming, or rearranging step. Cataloged filenames and paths are searchable before their
content finishes indexing; content coverage and indexing progress remain visible. The
workspace's admission and ignore rules still apply.

## Find, recognize, use

Press **Command-K** or **Command-F** for the same search panel. Search names, folders,
document contents, or attached thoughts. Arrow keys select a result without replacing the
document in your editing pane. The adjacent preview shows the selected match and its file
family. Choose another match chip to inspect that location. Return or **Open** opens the
selected location; **Command-Return** opens the file in its default application.

**Control-Option-F** opens the search panel over the current app without bringing Flamingo's
main window forward. Drag a result into the destination app, or choose **Copy File** and
paste it there. Escape dismisses search. **Go → Search from Any App** toggles the global
shortcut; registration leaves a conflicting macOS or application shortcut with its owner.

Type **`>`** in search to find application commands. **Command-Shift-F** retains the sidebar
search view, with the same retrieval and filters. Its **Preview and File Family** action
opens the selected result in the larger panel.

## Queries

Filters can be combined with ordinary search text. The panel displays their interpreted
scope. Paths are relative to the open workspace, and a folder scope includes descendants.

| Query | Scope |
|---|---|
| `path:"Research Lab" budget` | Budget matches inside Research Lab |
| `type:pdf budget` | PDF files |
| `ext:pptx,pdf budget` | Either listed extension |
| `type:folder research` | Folder names and paths |
| `after:2026-10-01 before:2026-11-01 budget` | Files modified during October |
| `presentations revised budget` | Presentation files, searching the remaining words |
| `pdfs last week budget` | PDFs modified in the previous calendar week |

`type:` recognizes PDFs, presentations/decks, spreadsheets, documents, images, videos,
audio, and notes; it also accepts an extension. `ext:` accepts extensions directly.
Recognized leading type words work without `type:`. Folder searches use `type:folder`,
`folders`, or `directories`.

Dates use the Mac's current calendar and time zone. `after:` includes its date;
`before:` excludes its date. Natural date phrases are **today**, **yesterday**, **this week**,
**last week**, **this month**, **last month**, and **last 7 days**. These refer to modification
time, not the time a file was opened or submitted. Quoted phrases remain search text.
Invalid filters are reported instead of silently broadening the search.

## Preview and family evidence

PDF matches display the actual page. Addressable Office and text matches display the
matching extracted section, labeled **Extracted source**: for example a slide, heading,
sheet, cell, or text line. Audio/video matches with a time anchor seek to that timestamp.
Name-only results use a native file preview where available. Unavailable or missing
locations are reported; extracted Office text is not a rendering of the original slide layout.

Selecting a file automatically inspects a bounded set of indexed candidates:

- **Identical copy** means the inspected files have matching byte fingerprints.
- **Possible version** and **Related content** remain tentative, with their supporting reason.
- **Compare extracted sections** shows shared text and representative unmatched excerpts,
  with source links. Partial extraction is disclosed. Different pagination or missing
  extracted text does not establish that a whole slide or page is absent.

Families do not establish an editable original, export direction, approval, or submission
status. Inspection leaves source contents in place and reports limits or unavailable
evidence. It is not an exhaustive duplicate scan of the whole workspace.

File results, family members, explorer rows, folder items, bookmarks, and working tabs
provide standard macOS file URLs for handoff. **Copy File/Folder** copies the real file
reference; **Copy Path** remains a separate text action. The explorer's internal moves and
bookmark reordering remain available. External destinations decide which file types they accept.

## Verification

Checked on 2026-10-16:

- `scripts/test.sh`: 1,028 test cases, zero failures, 10 platform/fixture-dependent skips.
  The 45 focused cases cover unified retrieval, families, exact preview resolution,
  stale results, and native file URL handoff. Independent-reader regressions hold the
  graph reader and a write transaction open while interactive search returns a slide
  match; another verifies cache freshness after external index changes.
- `scripts/build.sh -c release` and the signed release app bundle build successfully.
- Live mixed-folder fixtures: the searched budget opens extracted PowerPoint slide 7;
  the PDF result previews actual page 2; Chinese text locates line 4. A renamed byte
  copy appears as an identical copy, while the old deck is tentative. Comparison
  links open the changed slide in the main source reader.
- Final release check in the existing home workspace: `librosshare` returns the
  existing internal and pitch decks while indexing is still active. The internal
  deck is correctly labeled **Content not indexed yet** and its native preview
  opens. This confirms the live filename catalog works ahead of extraction.
- Live **Copy File → Finder paste** creates a byte-identical PowerPoint copy. Both
  source and destination bytes were checked. Native drag providers are tested for
  readable original URLs, private internal payloads, spaces, Unicode, and folders;
  a physical cross-app drag gesture and individual destination-app compatibility
  were not established by this automated session.
- A read-only release benchmark using roughly 500,000 catalog entries measured
  blank search at 2 ms, PDF filtering at 158 ms, `flamingo` at 352 ms, and broad
  `budget` at 1.47 s warm / 1.96 s cold. These are retrieval timings on this Mac,
  not a guarantee of end-to-end latency during indexing or source preview loading.

`scripts/make-search-qa.py` recreates the disposable mixed-format fixtures under
`build/Unified Search QA`. Test logs for this run are in
`/tmp/flamingo-unified-full-final-tests.log`; release diagnostics are in
`/tmp/flamingo-unified-release-final-run.log`. Existing source folders were not
reorganized. The app was returned to the existing home workspace after fixture QA.
