# Flamingo daily-workflow implementation and acceptance

This implements the follow-up to [the whole-codebase audit](AUDIT-2026-10-15.md). The product now owns a complete loop: locate a file, create or edit it, save safely, capture a thought, follow an exact source, connect related work, and resume it later. This is a local macOS application, with native Office editors used for Office authoring.

## What to use

- **Command-K:** find and open files by name or path.
- **Command-Shift-F:** search document content and thoughts, including Chinese substrings and quoted folder paths. Matching thoughts appear beneath the parent file with a thought indicator and highlighted matching text.
- **Control-N:** type `powerpoint`, `ppt`, `pptx`, `word`, `excel`, `markdown`, or a supported source-code extension; enter a name; create and enter the editor. Templates are real Office documents, not empty files with renamed extensions. Existing files are never overwritten by creation.
- **Command-S:** save text or Markdown in Flamingo. Recovery copies survive restart. An external change produces a conflict with save-copy and explicit reload options.
- **Graph +++ / ---:** choose files, Command-click additional files, add a reason, and save or remove manual relationships. The inspector distinguishes explicit relationships from document links and shared activity.
- **Trail:** search, name and resume work at its recorded locations. Split, merge and exclude misleading activity groups.
- **Ask:** select current-file or workspace scope, configure the local model, ask follow-ups, follow citations and save a labeled AI thought.
- **Index health:** inspect searchable/partial/failed/name-only coverage and storage; pause, rescan or retry failures. **Inbox** attaches previously unassigned captures to their real files.

AI analysis after saves is enabled for this requested workflow and can be switched off in Index health. It applies to files deliberately edited/opened through Flamingo, not every file found during indexing. AI observations carry provenance and suggested links; they do not silently become manually endorsed graph connections.

## Audit disposition

| Audit | Implemented response | Verification |
|---|---|---|
| 1 Exact locations | Real PDF/media navigation; line navigation in text; explicit Office source reader for slides, headings, sheets and cells; unresolved locations say so | Live slide 2/3, Q3!B12, Word heading, scanned PDF page 2 and text-line navigation |
| 2 Failed capture | Acknowledged save/edit/delete, retained drafts, retry/copy, Trail only after successful persistence | Forced sidecar write failure in app; retry saved exactly one thought |
| 3 Invisible extraction failure | Durable coverage/error state, preserved last good content, retryable failures and health UI | Live malformed DOCX appeared under Needs retry; repairing and retrying restored searchable coverage |
| 4 Scanner/watcher mismatch | Shared admission/ignore behavior, hidden paths, root handling, initial-event replay, rescan request guards | Index and app lifecycle regression tests |
| 5 Selection disagreement | Shared shell/graph file and folder selection; folder surface; new-file destination follows active folder | Live graph selection, folder selection and creation |
| 6 Capture latency | Session catalog reuse and off-main matching/preparation | Capture regression suite; no new whole-home latency claim |
| 7 Chinese recall | Merge lexical strategies and deduplicate instead of stopping at first FTS match | Live `定价策略` found both standalone and embedded occurrences |
| 8 Folder search | Quoted Unicode path parsing; scope before limit; visible result cap; source and thought snippets | Live `path:"Research Lab" ORCHIDBUDGET` returned the correct slide |
| 9 Scans and unavailable files | PDF OCR with partial coverage; filename metadata for unsupported/large/cloud files | Live image-only page search and page navigation; extraction/index tests |
| 10 Word supplementary text | Explicit supplementary sections and retained searchable content | DOCX-to-index footnote regression |
| 11 Work surface | Typed creation, text editor, native Office bridge, working tabs, per-vault anchors/history/recovery | Live PowerPoint creation/edit/save and built-in text work |
| 12 First use / health | Explicit folder selection and visible indexing status, storage and controls | Live health/failure/retry; existing home index preserved |
| 13 Scale controls | Cancellable/coalesced scans, off-main graph scope work, bounded embedding batches and aggregate ZIP budgets | Regression suites; semantic ranking remains linear in corpus size |
| 14 Ask setup / scope | Visible readiness/provider/model setup and actual selected-file/workspace scope | Live local-model current-file and workspace questions |
| 15 Research persistence | Conversation context, durable history and save-answer-to-thought | Live follow-up and cited answer saved to the source file |
| 16 Long-source retrieval | Passage chunking and source expansion | Retrieval regressions |
| 17 AI provenance | Human/AI origin and model metadata retained through sidecars, UI and retrieval | Live labeled AI thoughts; provenance round-trip tests |
| 18 Truncated streams | Require completion marker; preserve partial answer as incomplete | Mock-stream EOF regression |
| 19 Graph omissions | Keep current selection beyond node cap; disclose limit and offer expansion | Live selected `file-419.md` in a folder with 421 files |
| 20 Layout / folder identity | Merge persisted layouts across scopes, unpin/reset controls, hollow folders through selection states | Layout regressions and live selected-folder visual inspection |
| 21 Meaningful connections | Explicit multi-file relationships with reasons, evidence inspector, consistent backlinks, Trail corrections | Live three-way add/remove/re-add; named session split/merge/exclude |
| 22 Resume / renames | Anchored history, stable identity, durable rename reconciliation, historical link aliases and recovery migration | App, Core, Index and Trail regressions; live rename acceptance recorded below |
| 23 Activity bridge | Save events for deliberately tracked native documents; searchable and resumable Trail | Live PowerPoint save appeared in Trail |
| 24 Unassigned capture | App/window/source provenance and an attachable Inbox | Live capture in folder context, Inbox review and one-copy attachment |
| 25 Bookmark corruption | Preserve malformed/unreadable input; explicit backed-up reset; acknowledged save errors | Bookmark corruption tests and checked shell integration |
| 26 Usability / accessibility | Explicit loading/empty/error/scope states; accessible graph list; real clickable Trail and rail links | Live native Trail link opened the actual spreadsheet cell; full VoiceOver audit not performed |
| 27 Product testing | New App test target, real extraction integration cases, failure/race regressions and actual-app acceptance | Full suite result below; live workflows throughout this report |
| 28 Integration / release | Shared save, selection, scope and rename contracts exercised across modules | Local bundle built and used; notarization and automatic updates remain release work |
| 29 Vault switching | Snapshot destination state before observer changes; per-vault restoration guarded during startup | App A→B→A tests and anchored restoration tests |

## Actual application acceptance

Tests used a disposable `build/Daily QA` project with real PPTX, DOCX, XLSX and PDF documents, bilingual notes, and 421 files in one folder. Input was sent through the actual macOS app. Source files and stored metadata were inspected where needed to distinguish apparent UI success from persistence.

1. Created `6767.pptx` using Control-N and a PowerPoint type alias. Microsoft PowerPoint opened the real document without repair. Edited its title to `Orchid research budget 6767` and saved. Flamingo refreshed the source, recorded the save and saved a local-model analysis thought.
2. Created a Markdown working note; saved it; introduced a conflicting external version. Saving refused to overwrite the newer disk file. Quit/relaunch recovered the unsaved draft. Explicit reload retained recovery and showed the external contents.
3. Forced a capture write to fail. The panel kept the text, showed Not Saved and offered Retry/Copy. Restoring write access and retrying produced exactly one saved thought. No successful capture was claimed before acknowledgment.
4. Searched the human thought token `RECOVERORCHID`. The result appeared beneath its file with a thought indicator; activation selected the correct thought and line. Rail and Trail links to `budget.xlsx#cell Q3!B12` displayed the actual `ORCHIDCELL6767` value.
5. Searched `SCANNEDORCHID`, which exists only on raster PDF page 2. The result opened that visible page. A current-file Ask question answered the budget with a page-2 citation; Save thought persisted the cited answer.
6. Added and removed three graph relationships using multi-selection, a reason and the +++/--- controls. Re-added them; inspected their persisted storage. Named a Trail session, excluded it from inferred graph connections, split it and merged it again.
7. Captured an unassigned Inbox thought, selected the evidence presentation as its destination and attached it. The Inbox emptied and the destination sidecar contained one copy.
8. Created `Keyboard Flow.md` entirely from the keyboard. After creation, the document editor held focus; typing and Command-S saved the expected text. A later review identified and corrected shortcut search focus and repeated-term source-navigation races.
9. Created an intentionally malformed disposable DOCX. Health showed one failed file with its error. Replaced it with valid DOCX contents and used Retry incomplete files; health returned to zero failed files.
10. Quit with `budget.xlsx` selected at cell Q3!B12, then externally renamed the fixture to `Budget 2027.xlsx`. Relaunch restored the renamed tab, selected file, exact cell and actual cell contents. Its manual graph relationships still displayed their reasons. Clicking an unchanged old-filename wikilink resolved to the new file and cell.
11. Added an unsaved `UNSAVEDRENAMEDRAFT` paragraph to `Keyboard Flow.md`, externally renamed the file while the app was open, and observed the new tab with the full unsaved text. Command-S saved the paragraph to `Keyboard Renamed.md`; the old file was not recreated. The durable rename outbox was empty after acknowledgment.
12. Retested Command-Shift-F followed immediately by `RECOVERORCHID`: all characters arrived in the search field and the expected thought appeared. The initial delayed-focus implementation had dropped a prefix; the native input replacement passed this real test.
13. Opened the actual `/Users/allenwu/Documents/Works` project (886 admitted files in the app). Command-K found `librosshare_internal.pptx`; its native preview and exact source slides opened. Searching `book recommendations` returned five matching sources across PowerPoint, PDF and Word. Activating the main Libros deck result displayed slide 28 of 49 with its actual source text. No personal document content was edited. The app is left open on this real workspace.

## Verification record

Final complete command: `scripts/test.sh`. **867 tests executed, 10 skipped, zero failures** across all eight targets. The skipped cases are optional fixture/environment/live-integration checks; the actual local-model and app workflows above were exercised separately. The full run completed after correcting a Graph test fixture that lacked actual source files, which are now required for identity tracking.

| Target | Tests | Skipped | Failures |
|---|---:|---:|---:|
| App | 36 | 0 | 0 |
| Ask | 77 | 1 | 0 |
| Capture | 55 | 0 | 0 |
| Core | 235 | 1 | 0 |
| Extract | 130 | 7 | 0 |
| Graph | 98 | 0 | 0 |
| Index | 98 | 1 | 0 |
| Trail | 138 | 0 | 0 |

Build/run: `scripts/run.sh debug --vault <Daily QA>`, successful local app bundle, then opened Works through the app. No production source changed after the final live-tested bundle. `git diff --check` passed. Final test compilation emitted no warnings.

Local logs: `/tmp/flamingo-full-final-tests.log`, `/tmp/flamingo-daily-run5.log`, `/tmp/flamingo-workspace-rename-tests.log`, `/tmp/flamingo-rename-identity-final.log`, `/tmp/flamingo-source-navigation-tests.log`. The runnable bundle is `build/Flamingo.app`.

## Practical limits

- Office authoring uses the installed native editor. Exact Office locations inside Flamingo use labeled extracted source text; they are not an embedded PowerPoint/Excel editor or a claim that the native editor opened at that location.
- External rename continuity requires a stable identity already assigned and observed by Flamingo. Deliberately used and manually connected files acquire one. Read-only files and filesystems without extended attributes can still be opened/searched but cannot promise this continuity.
- Internal filesystem moves and metadata journals are separate commits. Recovery/retry is durable after the journal is written; this does not claim a cross-file, crash-atomic transaction across every application.
- Coordinated atomic text saves detect external changes and preserve metadata. A non-cooperating writer can still race the final check/replace; there is no universal compare-and-swap guarantee across arbitrary native applications.
- OCR and extraction expose partial/failed coverage. A searchable filename does not mean every page or embedded object was extracted.
- Whole-home performance was not re-benchmarked. Semantic search uses bounded batches but still performs linear similarity work. The existing 13.6 GB home index was not deleted or rebuilt during this task.
- This is a local development bundle. Notarized distribution, automatic updates, a full VoiceOver audit and universal support for every file format are not claimed.
