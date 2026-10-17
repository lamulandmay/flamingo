> **OVERRIDES (user decisions 2026-10-17), these win over anything below:**
> - **Thoughts never leave this Mac.** Every AI path that reads a thought (understanding, `@ai`/`@flamingo` replies, night shift, memos, echo, briefing) uses only local models: llama-server on loopback, Ollama, Apple on-device. Never Claude, Claude Code, an API key or any cloud provider. No setting, no consent prompt, no fallback. The endpoint type can only be constructed for 127.0.0.1/localhost. There is no `@claude`.
> - Chat may keep its remote provider for questions about files, but `AskEngine.run` must strip every thought passage, thought-derived section and thought text in history before calling any non-local provider (today thoughts leak via Retrieval.swift:157-262). Test it.
> - Night shift window: 22:00–06:00, idle ≥ 15 min, AC power. Catch-up at first open as designed.
> - Approved: `Package.swift` target `FlamingoThoughts` (+ tests), CONTRACT.md format additions. Scope excludes Obsidian plugins.
> - Ignore the "Risks → Privacy" and "Decisions needed" bullets about Claude below; they are superseded.

# Flamingo plan: thoughts v2, semantic recall, night shift and the daily briefing

I checked the brief against the code. Most of the facts it lists hold. Eleven findings change the design, so they come first.

## 0. Findings that change the brief

1. **Old Flamingo builds can read v2 notes if `origin` is always written.**
   - Old builds decode the metadata line as `CommentProvenance`. JSONDecoder ignores unknown keys, so the line stays hidden as long as it has `origin`.
   - If `origin` is missing, the bug at `SidecarFormat.swift:386` turns the line into thought text.
   - Rule: every metadata line written from now on includes `"origin"`, even for human thoughts.
   - Cost: an old build that rewrites a note drops the new keys. It never shows them as text. Flagged under Risks.
2. **`SidecarDocument.normalize()` drops new fields.** It rebuilds each comment at `SidecarFormat.swift:187` with only `provenance`. It must carry `meta` too. `contentKey` (:193) must use the merged metadata line.
3. **State changes would churn vectors.** `IndexStore.replaceComments` (:833-853) deletes and reinserts a file's rows on any change. A done or snooze would then delete the vector and copy it back from the cache. Fix: when only metadata changed, `UPDATE` the row in place so its rowid and vector stay.
4. **Folder thoughts fit at `.flamingo/notes/<folder>.md`.**
   - It can't collide with a file's note: file `x.md` maps to `x.md.md`, and a file and a folder can't share a name in one parent.
   - It is Obsidian's "folder note outside the folder" convention.
   - Graph folder nodes use ids like `decks/` (`GraphFolders.pathComponents`), so `GraphBuilder` must add folder-thought counts to those nodes.
5. **Don't add a `FlamingoMode` case.** `Mode.allCases` drives the ⌘1–⌘4 palette entries (`AppState.swift:2172`) and `SegmentedModes`. The briefing should be overlay state on `RootLayout`.
6. **⌘0 is free** in `MainMenu.swift`.
7. **QA would touch your real settings.** A QA build shares the `com.flamingo.app` defaults with your installed app. The new keys (such as `lastBriefingDay`) need a switchable suite, set by `FLAMINGO_DEFAULTS_SUITE`.
8. **The vault is the whole Mac (896k files).** The briefing must not build the graph (2.7 s). Centrality comes from SQL counts, and links resolve through the cached `LinkResolver` (`GraphBuilder.swift:110`).
9. **Obsidian can't see `.flamingo/work`.** CONTRACT has Obsidian open `.flamingo/notes`. So the AI reply's visible text carries the TL;DR and source wikilinks. The memo's path goes in the hidden metadata.
10. **`NSDataDetector` can't take a reference date.** "Tomorrow" must mean the day after the thought was written. A small relative parser anchored at the thought's timestamp handles that. `NSDataDetector` is used only for absolute dates.
11. **`JSON` in FlamingoAsk is internal.** So the LLM recipes live in FlamingoAsk, like `FileAnalysis.analyze`, and expose typed public results.

---

## M0 Pre-flight (needs your approval)

- Nothing in the tree is committed, and HANDOVER says to commit before the next big change. Commit the current tree first.
- New module `FlamingoThoughts`: the night shift, ranking and briefing engine, with no views. It depends on Core, Index, Ask and Trail, plus a test target `FlamingoThoughtsTests`. This is a `Package.swift` edit, which CONTRACT reserves, so you need to approve it.
  - Fallback if you'd rather not: put the same files in `Sources/Flamingo` and test through `FlamingoAppTests`.

---

## 1. Data model and on-disk formats

### 1.1 Thought metadata (Core, additive)

New file `Sources/FlamingoCore/ThoughtMeta.swift`:

```swift
public enum ThoughtKind: String, Codable, Sendable, CaseIterable { case idea, question, todo, intent }
public enum ThoughtState: String, Codable, Sendable { case open, done, snoozed, dismissed }
public enum ThoughtDecider: String, Codable, Sendable { case rules, model, user }
public struct ThoughtIntent: Hashable, Codable, Sendable {
    public var action: String          // review-conflict | compare-versions | summarize | answer | find-related | remind | connect | open
    public var objects: [String]       // "finance/q3-model.xlsx" or "decks/q3.pptx#slide 7", at most 6
    public var confidence: Double?; public var model: String?; public var at: String?   // "yyyy-MM-dd HH:mm"
}
public struct ThoughtMeta: Hashable, Codable, Sendable {
    public var uid: String?            // "t" + 9 Crockford base32 chars, stable across text edits
    public var parent: String?         // thread parent uid (same sidecar)
    public var kind: ThoughtKind?; public var kindBy: ThoughtDecider?   // only model/user decisions are persisted
    public var state: ThoughtState?; public var stateAt: String?
    public var due: String?; public var snoozeUntil: String?           // "yyyy-MM-dd" or "yyyy-MM-dd HH:mm", local
    public var modified: String?
    public var intent: ThoughtIntent?
    public var work: String?           // memo path relative to .flamingo, on AI memo replies
    var extra: [String: MetaJSON] = [:]   // unknown keys, round-tripped (forward compatible)
    var unparsed: String?                 // a metadata line that isn't a JSON object, kept verbatim
}
```

`Comment` gains three things. The existing public `init` is untouched.

```swift
public var meta: ThoughtMeta?
public init(id: UUID, timestamp: Date, anchor: FileAnchor?, text: String, provenance: CommentProvenance?, meta: ThoughtMeta?)
public var uid: String?   // meta?.uid
public func stamped(now: Date = Date()) -> Comment   // adds a uid; origin defaults to human
```

Rules for the metadata:
- **Only decisions are persisted.** The deterministic kind and due date are recomputed from the text and timestamp at index time, so improving the rules updates every thought without rewriting notes. A new thought only gets `uid` and `origin`.
- **Legacy thoughts get a uid lazily**, the first time something refers to them (a reply, a state change, a model intent, a work item). No mass rewrite of your notes.

### 1.2 Sidecar format: parse and render changes (`SidecarFormat.swift`)

- **Render:** merge the provenance keys, the meta keys and the extras into one sorted JSON object. Add `"origin":"human"` when meta exists and provenance doesn't. Keep the existing `>` → `\u003e` escape, so `-->` can never appear.
- **Parse (bug fix):** any two-space `<!-- flamingo: … -->` line under a thought is metadata, never text.
  - A JSON object is split into provenance (when any provenance key is present), meta and extras.
  - Anything else is stored in `meta.unparsed` and written back byte for byte.
- **Comment ids stay derived.** Metadata is not part of the id, so a state change never changes it.

Example of a v2 sidecar, using fixture data:

```
---
target: decks/q3-board-review.pptx
id: 3F2C9A0E-5B1D-4C7E-9A63-1E0B6D2F8C41
---
- [2026-10-13 14:11] (slide 7) Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229.
- [2026-10-16 18:40] (slide 7) review conflict between this and [[q3-model.xlsx]] before friday
  <!-- flamingo: {"intent":{"action":"review-conflict","at":"2026-10-16 18:41","confidence":0.92,"model":"gemma3:4b","objects":["decks/q3-board-review.pptx#slide 7","finance/q3-model.xlsx"]},"kind":"intent","kindBy":"model","origin":"human","uid":"t8m2k4q9xa"} -->
- [2026-10-17 02:14] (slide 7) Conflict. Slide 7 prices Arc at $249; [[q3-model.xlsx#cell Revenue!C12]] still multiplies by $229, so modelled November revenue is about 8% under the deck. [[pricing-memo.docx]] option C would make the deck right.
  <!-- flamingo: {"model":"qwen3.8-27b","origin":"ai","parent":"t8m2k4q9xa","reason":"review-conflict","uid":"t2c7w5n1pd","work":"work/2026-10-17/arc-price-q3-board-review-q3-model.md"} -->
- [2026-10-17 09:05] Fixed the model; deck stays at $249
  <!-- flamingo: {"origin":"human","parent":"t2c7w5n1pd","uid":"t5r8b3j6ke"} -->
```

- **Threads:** replies are separate top-level bullets placed right after the parent's last descendant, with `parent` in their metadata.
  - Nested `  - ` bullets are impossible: two-space lines are continuation text in today's format.
  - Obsidian shows the thread as consecutive bullets. Nothing about the format changes.
- **Selections from other apps:** the selected text becomes indented quote lines in the thought text, e.g. `  > Arc — $249 retail`.
  - Obsidian renders them as a blockquote inside the list item.
  - The rail draws a hairline left rule.
  - The quote gets embedded too, which helps recall.
- **URLs:** `.flamingo/notes/_web/<host>/<slug>-<6 hex of the URL hash>.md`. Its front matter holds `target: _web/…`, `url:` and `title:`, and old builds preserve unknown front matter keys.
  - Add `FileRef.webDirectory = "_web"`, `isWeb` and `isVirtual` (true for `_inbox` and `_web`).
  - Update the `isInbox` call sites to use `isVirtual`: `GraphTypes.swift:81,129`, `GraphFolders.swift:62` and `Resurface.swift`.
- **Folders:** `.flamingo/notes/<folder>.md`, with a front matter key `subject: folder`.
- **Thoughts on thoughts:** these are replies.

New `SidecarStore` API, all of it locked read-modify-write, so background writers address thoughts by uid and never by derived id:

```swift
public func comment(uid: String, in ref: FileRef) throws -> Comment?
@discardableResult public func update(uid: String, in ref: FileRef, _ change: (inout Comment) throws -> Void) throws -> Comment
public func ensureUID(forCommentID id: UUID, in ref: FileRef) throws -> String
@discardableResult public func appendReply(_ reply: Comment, toUID parent: String, in ref: FileRef) throws -> Comment
public func append(_ comment: Comment, to ref: FileRef, frontmatter: [String: String]) throws
```

### 1.3 Work memo (`.flamingo/work/<yyyy-MM-dd>/<slug>.md`)

The type is `WorkMemo` in `Sources/FlamingoCore/WorkMemo.swift`. Rendering and parsing are pure. Add `Vault.workDir`. Example:

```
---
flamingo: memo
thought: t8m2k4q9xa
on: "decks/q3-board-review.pptx#slide 7"
recipe: review-conflict
verdict: conflict
sources:
  - "decks/q3-board-review.pptx#slide 7 · 2026-10-13 14:02"
  - "finance/q3-model.xlsx#cell Revenue!C12 · 2026-10-12 19:30"
model: qwen3.8-27b
provider: llama
tokens: 7412
created: 2026-10-17 02:14
---
# Arc price: deck $249, model $229

Slide 7 prices Arc at $249; the Q3 model still multiplies November retail units by $229, so modelled revenue is about 8% under what the board saw.

## Where they disagree
1. **Arc retail price.** [[q3-board-review.pptx#slide 7]] "Arc — $249 retail" · [[q3-model.xlsx#cell Revenue!C12]] `=229*C11`
2. **Retail launch week.** [[q3-model.xlsx#cell Revenue!C12]] assumes launch week; [[arc-launch-plan.pptx#slide 5]] says week two.

## Next step
Change Revenue!C12 to $249, or footnote slide 7 with option C from [[pricing-memo.docx]].
```

The ledger at `.flamingo/work/ledger.jsonl` is append-only, one JSON object per line. Events: `night-start`, `queued`, `started`, `finished` (with memo, tokens, seconds), `replied`, `failed`, `night-end`. A job id is `<uid>:<recipe>:<8 hex of the sorted source path|mtime|size>`.

---

## 2. Schema v9 (`Schema.swift`, `IndexStore.swift`: `schemaVersion = 9` plus a step after :661)

```sql
ALTER TABLE comments ADD COLUMN uid TEXT;
ALTER TABLE comments ADD COLUMN parent TEXT;
ALTER TABLE comments ADD COLUMN kind TEXT;          -- meta kind, else rules kind (always set)
ALTER TABLE comments ADD COLUMN kind_by TEXT;       -- rules|model|user
ALTER TABLE comments ADD COLUMN state TEXT NOT NULL DEFAULT 'open';
ALTER TABLE comments ADD COLUMN due REAL;           -- meta due, else rules due from text+timestamp
ALTER TABLE comments ADD COLUMN snooze_until REAL;
ALTER TABLE comments ADD COLUMN modified REAL;
ALTER TABLE comments ADD COLUMN origin TEXT NOT NULL DEFAULT 'human';
ALTER TABLE comments ADD COLUMN action TEXT;        -- intent.action
ALTER TABLE comments ADD COLUMN meta TEXT;          -- full metadata JSON
CREATE INDEX comments_uid ON comments(uid);
CREATE INDEX comments_parent ON comments(parent);
CREATE INDEX comments_triage ON comments(state, kind, due);
INSERT OR REPLACE INTO meta(key, value) VALUES ('comments_reload', '1');
PRAGMA user_version = 9;
```

- `VaultSession` sees `comments_reload` and calls `reloadComments()` once, then clears the flag.
- Vectors survive. The delete triggers copy them into `semantic_cache`, so re-embedding is all cache hits.
- `StoredComment` (:856) includes the metadata JSON.
- `insertComments` (:873) fills the new columns using `ThoughtRules`.
- `Search.comment(_:_:provenanceColumn:)` (:463) gains a `metaColumn:` overload.

---

## 3. Milestones

Each milestone ends with a green `make test`.

### M1 Core: thoughts v2 and deterministic understanding

**Files (`Sources/FlamingoCore/`)**
- Add:
  - `Sources/FlamingoCore/ThoughtMeta.swift`
  - `Sources/FlamingoCore/MetaJSON.swift` (internal JSON value type)
  - `Sources/FlamingoCore/ThoughtUID.swift`
  - `Sources/FlamingoCore/ThoughtRules.swift`
  - `Sources/FlamingoCore/DueParser.swift`
  - `Sources/FlamingoCore/ThoughtAction.swift`
  - `Sources/FlamingoCore/WorkMemo.swift`
- Change:
  - `Sources/FlamingoCore/Comment.swift`
  - `Sources/FlamingoCore/SidecarFormat.swift`
  - `Sources/FlamingoCore/SidecarStore.swift`
  - `Sources/FlamingoCore/Vault.swift`
  - `Sources/FlamingoCore/GraphFolders.swift`

**`ThoughtRules.read(_ text:, at timestamp:, calendar:)`**, which ignores quote lines:
- **question:** ends in `?`/`？`, starts with an interrogative, or contains `吗`/`为什么`.
- **intent:** an AI-doable verb (review, compare, reconcile, summarize, check, verify, find, research, draft) plus a link, an anchor, or conflict/contradict/version wording.
- **todo:** an imperative first word from a list (say, name, cut, put, send, fix, update, add, remove, call, email, link, follow up…), or need to / have to / must / remember to / todo. The fixture has "Say both.", "Name the two retail buyers…" and "Cut to 180".
- **idea:** everything else.
- It also detects `@ai` and `@flamingo` mentions.

**`DueParser`**, anchored at the thought's timestamp:
- today/tonight/eod; tomorrow/tmr/明天
- weekday names and 3-letter abbreviations: the next occurrence strictly after the thought's day
- next week/下周 (Monday); in N days; eow (Friday)
- `NSDataDetector` only when the matched range contains a month name or a numeric date.

**`ThoughtAction`:**

```swift
public enum ThoughtAction: Hashable, Codable, Sendable {
    case ask(mention: String, scope: [String])
    case remind(at: Date)
    case connect(String, String)
    case open(String, FileAnchor?)
    case work(recipe: String, objects: [String])
    public static func proposed(for: Comment, rules: ThoughtReading, resolvedLinks: [FileRef]) -> [ThoughtAction]
}
```

**Tests** (`Tests/FlamingoCoreTests/`):
- `SidecarV2Tests.swift`:
  - Round trip: every fixture sidecar is unchanged after parse and render.
  - A v2 note with threads, intent, work, `unparsed` and unknown keys is byte-exact after parse and render.
  - A metadata line without `origin` becomes meta. A non-JSON metadata line stays verbatim and never becomes text (regression for :386).
  - `normalize`, `merge` and `update` preserve meta.
  - A text edit keeps the uid and changes the derived id. A state change keeps the derived id.
  - `appendReply` places the reply after the parent's last descendant.
  - `update(uid:)` still finds a thought whose text changed concurrently.
- `ObsidianReadabilityTests.swift`:
  - Every body line is a bullet, a two-space continuation, or a two-space `<!-- flamingo: … -->`.
  - No `-->` appears inside the JSON.
  - Removing the HTML comments leaves exactly the v1 rendering.
  - A **frozen copy of today's parser**, kept as a test fixture, reads v2 output with no metadata leaking into text. This is the old-build proof.
- `ThoughtRulesTests.swift`: all 23 fixture thoughts labelled by hand, at least 90% agreement; Chinese cases.
- `DueParserTests.swift`: injected reference date, DST weeks, "fri" written on a Friday means next Friday.
- `WorkMemoTests.swift`: render/parse round trip; YAML quoting of `#`, `!` and `:`.

### M2 Index v9 and semantic recall

**Files (`Sources/FlamingoIndex/`)**
- Add `Sources/FlamingoIndex/ThoughtSearch.swift`.
- Change:
  - `Sources/FlamingoIndex/Schema.swift`
  - `Sources/FlamingoIndex/IndexStore.swift`
  - `Sources/FlamingoIndex/Search.swift`
  - `Sources/FlamingoIndex/Semantic.swift`
  - `Sources/FlamingoIndex/UnifiedSearch.swift`
  - `Sources/FlamingoIndex/Resurface.swift`
  - `Sources/FlamingoIndex/SemanticEval.swift`
  - `Sources/FlamingoIndex/GraphBuilder.swift`
  - `Sources/FlamingoIndexCLI/main.swift`

**Fixes:**
- Inbox, web and folder thoughts are dropped by inner joins to `files`. Change them to `LEFT JOIN files f`, with the predicate `(f.path IS NULL AND <no ext/date filter>) OR (<filePredicate>)`. Sites:
  - `Semantic.swift:336-339` and `:377-381`
  - `UnifiedSearch.swift:513` and `:544`
  - `Resurface.swift:27`
- `GraphBuilder`: comments on a folder count toward the `folder/` node. Links written by AI replies are counted as suggestions only, via `origin='ai'`. This is a behaviour change, flagged below.

**New API:**

```swift
public struct ThoughtRecord: Sendable, Equatable, Identifiable { file, comment, uid, parent, kind, kindBy, state, due, snoozeUntil, action, origin, fileModified: Date?, replies: Int, lastHumanReplyAt: Date? }
public struct ThoughtHit: Sendable, Equatable, Identifiable { record: ThoughtRecord; snippet: String; score: Double; relevance: Double?; parentLine: String? }
public func thoughts(_ q: ThoughtQuery) throws -> [ThoughtRecord]               // SQL over comments_triage
public func thread(rootUID: String, in ref: FileRef) throws -> [ThoughtRecord]
public func searchThoughts(_ query: String, inFolder: String? = nil, limit: Int = 20, includeSemantic: Bool = true) throws -> [ThoughtHit]
public func similarThoughts(to draft: String, excludingUID: String? = nil, limit: Int = 3, minRelevance: Double = 0.45, wait: TimeInterval = 0.3) -> [ThoughtHit]
public func resurfaceableThought(near files: [FileRef], olderThan: TimeInterval, now: Date, seen: Set<String>) throws -> (FileRef, Comment)?
public func thoughtDegree(of paths: [String]) throws -> [String: Int]
// UnifiedSearchResponse gains `public var thoughts: [ThoughtHit]` (additive)
```

**How it works:**
- `searchThoughts` is the hybrid search over thoughts: FTS `commentHits` plus `VectorIndex.nearest(…, allow: { $0.isComment })` (the hook exists at `VectorIndex.swift:262`), fused with the existing `hybrid` weights.
- **Richer embedding input** (`EmbeddingPass.comments`, :517):
  - `"<Question|To do|Intent|Thought> on <file display>, <anchor>"` + optional `" · re: <parent first line>"` + `" · links: <linked titles>"` + body (quote lines included).
  - The kind word comes from the rules only, and state and due are excluded. Vectors therefore change only when the text changes.
  - Expect one re-embed of all thoughts (about 30 per second).
- `SemanticEval.Case.relevant` accepts `thought:<path>|<yyyy-MM-dd HH:mm>` keys. The CLI gains `--eval cases.json --mode thoughts`.

**Tests:**
- `IndexV9MigrationTests.swift`:
  - A v8 database with comments and vectors migrates to v9.
  - Columns are filled after reload.
  - Re-embedding makes zero calls to the fake embedder.
  - A read-only store opened before migration fails cleanly.
  - A state-only change keeps the rowid and the vector.
- `ThoughtSearchTests.swift` (fake embedder from `SemanticIndexTests`):
  - An inbox thought is found by meaning, by keyword and in ⌘K.
  - Thread context is attached to hits.
  - Echo rows don't appear for unrelated drafts.
  - Resurface prefers related, unseen thoughts.
- `SemanticBenchmarkTests`, live (`FLAMINGO_LIVE=1`), with about 25 thought cases in `fixtures/thought-cases.json` (paraphrase, zh/cross-language, "what did I need to do before the board meeting"). Targets:
  - `searchThoughts` recall@5 ≥ 0.90 and MRR ≥ 0.80
  - ⌘K: a thought row in the top 3 for ≥ 0.85 of thought cases
  - Echo: the earlier thought in the top 2 for ≥ 8 of 10 related drafts, and nothing shown for ≥ 9 of 10 unrelated drafts
  - File-level numbers must not drop: fixture hybrid 0.939/0.824, palette 0.939/0.841, bilingual palette 0.990/0.955.

### M3 Rail and capture v2: threads, echo, thoughts on anything

**Files**
- Change:
  - `Sources/FlamingoCapture/CommentsRail.swift`
  - `Sources/FlamingoCapture/RailRichText.swift`
  - `Sources/FlamingoCapture/CaptureController.swift`
  - `Sources/FlamingoCapture/FrontmostContext.swift`
  - `Sources/FlamingoCapture/CapturePanel.swift`
  - `Sources/Flamingo/Inspector.swift`
  - `Sources/Flamingo/AppState.swift` (thin hooks only)
- Add:
  - `Sources/FlamingoCapture/ThoughtEcho.swift`
  - `Sources/FlamingoDesign/KindGlyph.swift`
  - `Sources/Flamingo/ThoughtWorkflow.swift`

**Rail threads**
- Roots appear in time order, each followed by its replies.
- A reply row is inset `Space.l`, with a `VHairline` at x = 8 running from the root to the last reply. Two visual levels at most; deeper replies flatten.

**Rail rows**
- Kind glyph, monochrome, at the head of the timestamp row:
  - ideas get no glyph
  - question: `questionmark.circle`
  - todo: `circle`, and `checkmark.circle` when done
  - intent: `arrow.triangle.turn.up.right.circle`
- Due shows as a mono `Chip` ("fri", or "Oct 23").
- Done text uses `textTertiary`, with no strikethrough.

**Rail keys and menu**
- New keys when the rail is focused: `r` reply, `e` done, `s` snooze until tomorrow 09:00.
- Context menu: Reply, Done, Snooze ▸, Kind ▸ (a user override sets `kindBy: user`), Ask AI, Work on This Now ▸ recipes, Copy Link to Thought.
- New modifiers: `.onReply`, `.onSetState`, `.onSetKind`, `.onWork`, `.pendingReplies([String: String])`.
- The edit field (:505-517) becomes `ThoughtField`, so `[[` completes there too.

**Composer**
- Reply mode shows the parent's first line, tertiary, with `arrow.turn.down.right`. It adds no new copy.
- **Echo ("you thought this before"):**
  - Debounced 400 ms; needs at least 4 words; calls `similarThoughts`.
  - At most 2 rows above the field: glyph, the earlier thought's first line, the file name and the date. All of it is your data.
  - Fades in over 150 ms. Click jumps to the thought; ⌥-click makes the draft a reply to it.
  - The ⌃⌥Space panel shows the same rows, through a new `CaptureController.similarThoughts` closure.

**Thoughts on anything**
- `FrontmostContext` reads `kAXSelectedTextAttribute` (up to 2,000 characters) into quote lines.
- A browser with no vault file in front captures to `_web/…` with url and title front matter.
- With a folder selected and no file, ⌘⇧C and the Thoughts tab target the folder note. The composer reads "Thought on decks", under the existing DESIGN exception.

**Saving**
- `AppState.saveComment` and Capture's direct-save path both call `comment.stamped()`.
- `saveEditedComment` sets `modified`.

**Tests**
- `FlamingoCaptureTests/RailThreadsTests.swift`: thread ordering and flattening.
- Capture target selection: URL goes to `_web`, a selection becomes a quote, a folder becomes a folder note.

### M4 Understanding pass and agentic thoughts

**Files**
- Add:
  - `Sources/FlamingoAsk/Completion.swift`
  - `Sources/FlamingoAsk/ThoughtReader.swift`
  - `Sources/FlamingoAsk/MultiFileSource.swift`
  - `Sources/FlamingoAsk/WorkRecipes.swift`
- Change:
  - `Sources/FlamingoAsk/AskEngine.swift`
  - `Sources/FlamingoAsk/Retrieval.swift`
  - `Sources/Flamingo/ThoughtWorkflow.swift`

```swift
public enum CompletionPurpose: Sendable { case interactive, understanding, nightShift }
public struct LocalCompletionRequest: Sendable { var system, user: String; var schema: String?; var maxTokens = 1200; var temperature = 0.2; var purpose: CompletionPurpose }   // no provider field: local only
public struct LocalCompletion: Sendable { var text: String; var json: Data?; var model: String; var inputTokens, outputTokens: Int? }
public func complete(_ r: CompletionRequest, onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Completion
public func understand(_ c: Comment, on file: FileRef, candidates: [FileRef]) async throws -> ThoughtUnderstandingResult
public func askStreamingLocally(_ q: String, history: [ConversationTurn], files: [FileRef], context: AskContext) -> AsyncThrowingStream<Delta, Error>   // local models only
extension Answer { public func wikified() -> String }      // [n] → [[path#anchor]]
public enum WorkRecipe: String, CaseIterable, Codable, Sendable { case reviewConflict = "review-conflict", compareVersions = "compare-versions", summarize, answer, findRelated = "find-related" }
public func work(_ r: WorkRequest, onStatus: @escaping @Sendable (String) -> Void) async throws -> WorkResult   // WorkResult: memo: WorkMemo, replyText, model, provider, tokens
```

**Who answers, by purpose**

| Purpose | Model |
|---|---|
| understanding | Always local: Ollama `FlamingoThoughtModel` (default `gemma3:4b`) with a JSON-schema `format`, as `Titler` does. The 27B only if it's already running. Otherwise rules only. |
| interactive (`@ai` / `@flamingo`) | Local 27B (LlamaServer), else Ollama. Never Ask's provider setting. |
| nightShift | Local 27B, loaded overnight, else Ollama with a smaller budget. With no local model the job waits. |

- For local structured output: llama-server gets `response_format` with a schema and `chat_template_kwargs.enable_thinking=false`, like `FileAnalysis`.

**Understanding flow**
- Runs about 2 s after a human thought is saved; it never blocks the save.
- Persists `kind` and `intent` through `update(uid:)` only when confidence ≥ 0.6 and the objects resolve.
- Never overwrites a `kindBy: user` decision.
- Backfill: open thoughts from the last 30 days, at most 50 a day, idle only. Skips AI thoughts.

**`@ai` / `@flamingo`**
- The question is the thought text minus the mention, scoped to the target file, its links and the thread's files (`MultiFileSource`, generalizing `SelectedFileSource`).
- Streaming text lives in a separate `ThoughtJobsModel: ObservableObject`, not in `AppState`. The rail shows a pending row in `textSecondary` with `ProgressHairline(value: nil)`; Esc stops it.
- The answer is saved with `appendReply`: `Answer.wikified()` as text, `.ai` provenance, a `parent` uid.
- This path doesn't record a Trail event.

**Actions**
- `remind` sets `due`.
- `connect` is offered in the briefing with ✓, and is never applied by itself.
- `open` happens only when you trigger it.
- `work` queues a night-shift job, or runs now from the context menu.

**Retrieval fix** (`Retrieval.swift:168, 222-225`)
- A `sectionRank` hit with `commentID` moves into the comment fusion as a thought, instead of `sectionText`.
- `PassageSource` gains `searchThoughts` (the protocol is internal).
- Thought passages begin with `re: <parent first line>`.

**Tests** (`FlamingoAskTests`)
- `LocalOnlyTests.swift`: every thought path (understanding, @ai, night shift, echo) only reaches loopback (URLProtocol fails any other host); Chat with a remote provider carries no thought text.
- `ThoughtReaderTests.swift`: canned JSON; low confidence is ignored; user override is respected.
- `RetrievalTests`: a semantic thought hit stays a `.comment` passage.
- `WorkRecipeTests.swift`, via `MockAPI` / a fake `ChatClient`:
  - review-conflict JSON produces a memo and a reply.
  - Invalid JSON is recorded as failed, with no reply.
  - A source changed mid-run (fingerprint check, like `FileAnalysis`) leaves no reply.

### M5 Daily briefing (it replaces the Capture Inbox sheet)

**Files**
- Add:
  - `Sources/FlamingoThoughts/BriefingClock.swift`
  - `Sources/FlamingoThoughts/AttentionRanker.swift`
  - `Sources/FlamingoThoughts/BriefingSnapshot.swift`
  - `Sources/FlamingoThoughts/BriefingHistory.swift` (`.flamingo/briefing.json`: shown counts per uid, seen memos, seen pairs)
  - `Sources/Flamingo/BriefingWorkflow.swift`
  - `Sources/Flamingo/BriefingView.swift`
  - `Sources/Flamingo/BriefingRows.swift`
  - `Sources/Flamingo/MemoCard.swift`
  - `Sources/Flamingo/MemoReader.swift`
- Change:
  - `Sources/Flamingo/RootView.swift` (overlay; the sheet at :80-92 becomes the briefing)
  - `Sources/Flamingo/AppDelegate.swift`
  - `Sources/Flamingo/Defaults.swift`
  - `Sources/Flamingo/MainMenu.swift`
  - `Sources/Flamingo/AppState.swift` (`commands`: "Inbox" ⌘0 replaces "Capture Inbox")
  - `Sources/Flamingo/Sidebar.swift` (the :115 tray opens the briefing)
  - `Sources/Flamingo/QAHook.swift`
  - `Sources/FlamingoTrail/Trail.swift` (add `attention(on:since:) -> [FileRef: TimeInterval]` and `lastOpened(_:)`)
  - `Sources/FlamingoCapture/CaptureDraft.swift` (add `pending(in:)`)

**When it opens**
- `BriefingClock.day(now) = startOfDay(now − 4h)`.
- Triggers:
  - launch, after `restoreLastVault()` at `AppDelegate.swift:76` and once the first comments have loaded (≤ 1.5 s)
  - `NSApplication.didBecomeActiveNotification`
  - `NSWorkspace.didWakeNotification`, then the next activation
- Skipped:
  - when a sheet or the capture panel is up
  - when activation came from the global palette
  - when activation came from an open-file request; the day then stays pending until the next activation
  - when there is nothing to show
  - under XCTest
  - when `briefingAutoOpen` is off
- Sets `Defaults.lastBriefingDay`, using the switchable suite from finding 7.

**Window zoom**
- Save `{frame, isFullScreen, mode, railVisible, railPinned, inspectorTab}`.
- If the window isn't in native full screen, `setFrame(screen.visibleFrame, display: true, animate: true)`. `MainWindow.animationResizeTime` returns `Motion.normalSeconds` while zooming.
- Esc, ⌘1 or ⌘0 fades out over 150 ms and restores the frame. ⌘2 and ⌘3 exit and switch mode.
- The frame is not restored if you moved or resized the window during the briefing.
- If the app quits mid-briefing, the saved frame is in Defaults.
- Opening the briefing later from the ribbon, palette or ⌘0 doesn't zoom.

**What's in it** (`BriefingSnapshot`, built off main; target ≤ 250 ms on the fixture and ≤ 600 ms on the whole-Mac index):
- Overnight memos: front matter of `.flamingo/work/*` newer than the last briefing and unseen.
- Thoughts to address first: top 12 by the formula below.
- Needs attention:
  - files with open thoughts edited after both the thought and your last open
  - open loose captures (`_inbox`), with attach preserved through `LinkMatcher` and `attachInboxThought`
  - unseen, undismissed `similarFiles` suggestions for your 5 most-thought-about files
  - recovered drafts
  - index problems (`incompleteFiles` count and errors)
- Resume: yesterday's last Trail session, `locationsToReopen`, up to 6.

**Ranking formula** (`AttentionRanker`, pure)

Candidates are open thoughts, plus snoozed ones whose `snoozeUntil` has passed.

```
D due:        overdue 1.0+min(0.5,0.1·|Δd|); today 0.9; tomorrow 0.55; 2–6 d 0.3−0.03·Δd; none 0
K kind:       todo 1.0 · question 0.85 · intent 0.8 (1.0 with memo ready) · AI question awaiting you 0.9 · idea 0.2
S strength:   spark 0 · solid 0.5 · woven 1.0   (ThoughtStrength)
F staleness:  min(1, age_d/1.5) · exp(−max(0, age_d − 7)/21)
A activity:   target or object edited after the thought 1.0 · new AI reply 0.8 · opened without reply 0.4
C centrality: log(1+deg)/log(1+maxDeg), deg = thought-linked files + connections.json
W awaiting:   unseen memo or AI reply 1.0
P skips:      0.35 · min(3, times shown without action in the last 7 days)
score = 3.0·D + 1.6·K + 0.7·S + 1.0·F + 1.2·A + 0.5·C + 1.5·W − P
```

- Eligible if any of these hold: age ≤ 45 days, a due date is set, W = 1, or woven and not an idea.
- Ideas show only when A > 0 or W > 0, so ideas don't nag.
- Overdue and due-today are pinned first, in due order.
- Ties go to the newer thought, then to path order.
- Each row's reason glyph comes from its strongest term: clock, `arrow.triangle.2.circlepath` or `sparkle`.

**Triage keys**

| Key | Action |
|---|---|
| j / k / ↑ / ↓ | Move |
| Return | Close the briefing and jump to the thought's place, selected in the rail by uid |
| e | Done (fade, `Chime.tick`) |
| s | Snooze until tomorrow 09:00 |
| r | Reply inline (`ThoughtField`) |
| ⌫ | Dismiss |
| a | Attach a loose capture |
| ✓ / × | Accept or dismiss a suggestion |
| ⌘Z | Undo through `ActionHistory` |

Key handling goes through an AppKit first-responder `BriefingKeyNSView`, so the sidebar's type-to-select doesn't take the letters.

**Tests**
- `FlamingoThoughtsTests/BriefingClockTests.swift`: 03:59 belongs to the previous day; DST and timezone changes; launch versus activation; pending after an open-file request.
- `AttentionRankerTests.swift`:
  - overdue beats undated
  - done and dismissed are excluded
  - snoozed comes back the next day
  - ideas stay down unless there's activity
  - the skip penalty applies
  - same input, same output
- `FlamingoAppTests/BriefingWindowTests.swift`: pure frame plan; full screen; the window was moved during the briefing.

### M6 Night shift

**Files**
- Add:
  - `Sources/FlamingoThoughts/NightShiftGate.swift`
  - `Sources/FlamingoThoughts/NightShiftPlanner.swift`
  - `Sources/FlamingoThoughts/WorkLedger.swift`
  - `Sources/FlamingoThoughts/NightShiftRunner.swift`
  - `Sources/FlamingoThoughts/NightShiftScheduler.swift`
  - `Sources/FlamingoThoughts/PowerSnapshot.swift`
  - `Sources/Flamingo/NightShiftWorkflow.swift`

**Planner: what counts as not acted on.** A thought becomes a job when all of these hold:
- it is open and is an intent, or a question or todo with a recipe;
- its age is ≥ 6 hours;
- it has no human reply after it;
- `TrailStore.attention(on: objects, since: ts)` is under 3 minutes on at least one object;
- there is no finished ledger job with the same fingerprint;
- if the sources changed since the last memo, at least 7 days have passed since that memo.

Edits to the sources don't count as acting. The memo is written against the latest text and says whether the conflict is still there.

**Recipes**

| Recipe | What it does |
|---|---|
| review-conflict | Anchored sections, plus each file's sections ranked against the thought text and the other file's terms (index text, so `FlamingoExtract` output). Returns {title, tldr, verdict, conflicts[{a, b, why}], consistent[], next}. |
| compare-versions | Pairs the file with a likely version (`FileFamilies`). |
| summarize | TL;DR of the named files. |
| answer | Same retrieval and citations as `@ai`. |
| find-related | Semantic search over thoughts and files. Only excerpts are sent to the model. |

All recipes use the "passages are quoted data" system prompt (as at `FileAnalysis.swift:104`). They read only the files the thought names, plus its target. Nothing in a model's output is ever executed.

**Gate** (pure, injected clock):

```
decide(now, calendar, power, idleSeconds, ledger, settings, budgetOverride) -> .run(Budget) | .wait(until:) | .skip(reason)
 window [22:00, 06:00) local · AC · !LowPower · thermal < .serious · idle ≥ 15 min · not finished this night
 · budgetOverride() != .none  (nil by default; once plan 13 merges the shell sets it from ComputeBudget, so no merge is needed now)
Budget(night): jobs 6 · wall 45 min · local tokens 150k · per-job 8 min
Catch-up (first open of the day, last night missed, candidates > 0, AC or battery ≥ 50% and !LowPower): jobs 3 · wall 12 min
```

**Scheduler**
- `NSBackgroundActivityScheduler("com.flamingo.nightshift")`: interval 30 min, tolerance 10 min, `.utility`, repeats.
- Each fire evaluates the gate. Honors `shouldDefer`.
- While working:
  - `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)`
  - `ProcessInfo.beginActivity(.background)`
- Idle time comes from `CGEventSource.secondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)`.
- After the batch, stop llama-server if the night shift started it and Ask hasn't used it since.

**Runner**
- Writes the ledger: `queued`, `started`, `finished`/`failed`, `replied`.
- Writes the memo with `AtomicFile`, then the reply with `appendReply(toUID:)`.
- On restart, `started` with no `finished` is requeued, at most 2 attempts.
- A memo with no reply gets only its reply appended.
- It never writes outside `.flamingo` and never records Trail events.

**Catch-up streams into the briefing.** Its card appears at once: source thumbnails, your thought's line, and a `ProgressHairline(nil)` pulse. The TL;DR fades in when it's ready.

**Switch:** palette "Pause Night Shift" / "Resume Night Shift", plus "Work on Open Thoughts Now". `Defaults.nightShiftEnabled` is on by default.

**Tests**
- `NightShiftGateTests.swift`: outside the window it waits until the next start; battery, heat and Low Power; already ran tonight; the budget override; catch-up conditions.
- `NightShiftPlannerTests.swift` (synthetic Trail events): untouched → job; both opened ≥ 3 min → none; human reply → none; done → none; same fingerprint → none; changed after 7 days → job.
- `WorkLedgerTests.swift`: torn last line; resume after a crash; idempotent replay.

### M7 Docs and design review

**Files**
- `DESIGN.md`: the tokens below.
- `CONTRACT.md`: on-disk formats for the metadata line, `_web`, folder notes and `.flamingo/work`. Needs your OK, since CONTRACT is reserved.
- `HANDOVER.md`
- `plans/DESIGN-REVIEW.md`
- `docs/screens/briefing-{dark,light}{,-1000x600}.png`
- Perf check: snapshot ≤ 600 ms and first frame ≤ 100 ms on the `~` index.

---

## 4. Visual design (within DESIGN.md)

**Grid**
- Content is centred, max 1080pt, on a 12-column grid with 24pt gutters.
- Top inset: title bar + `Space.xxl`. No headers anywhere; regions are told apart by position and hairlines.

**Date**
- One line: "Saturday" in `text` and "October 17" in `textTertiary`, both in the new `Font.display` (26pt semibold). It's the only display type in the product.

**Memo cards**
- 4 columns each, three across; they scroll sideways below about 900pt.
- `Squircle(radius: Radius.l)`, `bgRaised` fill, hairline stroke.
- Top: up to 3 Quick Look thumbnails of the sources, 44pt `Squircle(Radius.s)`, overlapping 12pt with a `bg`-coloured ring.
- Then the memo's H1 in `Font.title`, the TL;DR in `body` (4 lines), and your original thought in `small`/`textTertiary` (1 line).
- The verdict is a monochrome glyph. Click opens `MemoReader`: an in-briefing 640pt panel rendered with `MarkdownLite`, where source wikilinks open the files.

**Below the cards** (hairline above)
- Thoughts to address first, 7 columns:
  - 44pt two-line rows
  - line 1: `KindGlyph` and the thought's first line (`body`)
  - line 2: `FileGlyph`, file name (`small`, secondary), anchor `Chip`, date (`monoSmall`, tertiary), reason glyph
  - `VHairline` on the right
- Needs attention, 5 columns: 26pt `flamingoRow`s showing a glyph, the name, and a mono time or count. Below 900pt the columns stack.
- Resume: a strip pinned to the bottom with a hairline above. 96×64 thumbnails in `Squircle(Radius.m)`, names in `small` under them.

**Motion**
- The window frame animates over 220 ms ease-out.
- Content fades in over 220 ms; cards are staggered 40 ms and the first 7 rows 20 ms. Opacity only; nothing moves.
- Triage: the row fades over 150 ms and the gap closes over 150 ms ease-out. On `e`, the row's glyph flashes its `Color.thought(level)` tint for 150 ms with `Chime.tick`, then turns grey.

**Light and dark.** All tokens are already dynamic. Check at 1000×600 and full screen.

**Proposed DESIGN.md additions**
1. `Font.display` 26pt semibold (plus `Theme.NS.display`): the briefing date only.
2. `Motion.stagger` 40 ms (`staggerSeconds`): sequential fades, never movement.
3. `Size.thumbnail` 44 (memo sources) and `Size.tile` 96×64 (resume strip).
4. `Color.thought(level)` may also flash on a briefing row's glyph at the moment you triage it.
5. Components: `KindGlyph(kind:state:)`, `ThoughtEcho`, `MemoCard`, `Chime.tick(level:)`.
6. Layout note: the briefing is the only view that zooms the window. It has no headers.

---

## 5. Headless QA

Add three things:
- `scripts/qa-post.swift`: posts a distributed notification `<channel> <command>`, built like `window-id`.
- `scripts/qa-thoughts.sh`
- `FLAMINGO_FAKE_LLM=1`: `AskEngine.complete` returns canned JSON from `fixtures/fake-llm/<purpose>-<recipe>.json`. This gives deterministic screenshots without loading the 27B.

New QAHook commands:
- `open <path>`
- `reply <text>`
- `briefing`, `briefing nozoom`, `briefing reset`
- `clock <ISO>` (overrides the clock for the briefing and gate)
- `window <w>x<h>`
- `nightshift now`, `nightshift plan`

Each one logs a summary line through `Log.debug`, for example `qa: briefing memos=1 address=7 attention=3`.

```
V=$SCRATCH/vault; rm -rf $V; cp -R fixtures/vault $V; scripts/bundle.sh debug
FLAMINGO_DEBUG=1 FLAMINGO_QA_CHANNEL=qa.thoughts FLAMINGO_FAKE_LLM=1 FLAMINGO_DEFAULTS_SUITE=com.flamingo.qa \
  build/Flamingo.app/Contents/MacOS/Flamingo --vault $V -FlamingoAppearance dark 2> $SCRATCH/log &
qa() { build/qa-post qa.thoughts "$*"; sleep ${W:-1}; }
```

1. Thought v2:
   - `qa open decks/q3-board-review.pptx`
   - `qa thought review conflict between this and [[q3-model.xlsx]] before friday`
   - The sidecar shows `uid` and `origin`. Within 5 s it also shows `"kind":"intent"` and `"action":"review-conflict"`.
   - `grep -v '<!-- flamingo:'` on the sidecar gives the v1 shape.
2. Agentic:
   - `qa thought @ai what price does the model use?`
   - The log shows a stream, and the reply has `parent` plus `[[q3-model.xlsx#…]]`.
3. Night shift:
   - `qa clock 2026-10-17T02:00; qa nightshift now`
   - The log shows `finished`, `.flamingo/work/2026-10-17/*.md` exists, and the AI reply carries `work`.
4. Briefing:
   - `qa clock 2026-10-17T08:30; qa briefing reset; qa briefing`
   - `build/window-id --bounds` equals the screen's visible frame.
   - `screencapture -o -x -l $(build/window-id --pid $PID Flamingo) docs/screens/briefing-dark.png`
   - `qa key 53` (Esc): the bounds are back to the original frame.
5. Triage:
   - `qa briefing; qa key 38; qa key 14` (j, e): the sidecar shows `"state":"done"`.
   - `qa key 1` (s) snoozes. `⌘Z` restores.
6. Recall (live, with Ollama):
   - `.build/debug/flamingo-index $V --eval fixtures/thought-cases.json --mode thoughts` meets the M2 targets.
   - `FLAMINGO_LIVE=1 scripts/test.sh --filter SemanticBenchmarkTests` shows no file-level regression.
7. Repeat with `-FlamingoAppearance light`, and with `qa window 1000x600; qa briefing nozoom`.
8. The old-build proof is the frozen-parser unit test. Optionally, open `$V/.flamingo/notes` in Obsidian and confirm the bullets read cleanly.

---

## 6. Risks

- **Derived-id fragility.**
  - All cross-references (threads, ledger, briefing history, selection) use the uid.
  - Background writes go through `update(uid:)` under the note lock.
  - Legacy thoughts get a uid lazily; their briefing history keys on the derived id until then, and is lost if their text is edited first.
- **Older builds** strip unknown metadata keys when they rewrite a note. The `origin` rule means nothing leaks into text.
- **LLM latency.**
  - The 27B takes about 36 s to load and 1–2 minutes per memo, so it runs at night only.
  - Understanding uses the 4B (about 1 s).
  - Catch-up is capped at 3 jobs and its cards fill in while you triage.
- **Overnight power.**
  - `NSBackgroundActivityScheduler` can't wake a sleeping Mac. An assertion is held only while working.
  - The 22:00 evening idle window raises the odds of a run before the Mac sleeps. Catch-up at first open is the honest fallback.
- **Privacy.**
  - The night shift reads only files a thought names.
  - Memo front matter records the provider and model, so it can be audited.
- **Prompt injection from file text.** Output only goes into `.flamingo`, and no action runs without your keypress.
- **Graph semantics.** Treating AI-written links as suggestions is a behaviour change. Today `FileAnalysis` replies count as explicit links.
- **Scale.**
  - Everything runs through indexed SQL. No graph build in the briefing.
  - `Trail.events(since:)` reads the whole trail file, so run it off main.
  - Briefing and thought-job state stay out of `AppState`'s `@Published` properties.
- **Intrusion.** First-of-day detection, full screen, multiple displays and activation by an open-file request are all handled. A palette toggle "Morning Inbox: On/Off" stays available.
- **Name collisions.** A real `_web` or `_inbox` folder in the vault would mix with virtual notes. This already exists for `_inbox`.
- **Housekeeping.** `Package.swift` needs approval; CONTRACT needs updating; the ComputeBudget hook keeps plan 13 unmerged.

## 7. Decisions needed from you

1. Approve the commit of the current tree, the new `FlamingoThoughts` module (`Package.swift`), and the CONTRACT updates.
3. Night window: 22:00–06:00 with an evening idle start (recommended), or strictly 01:00–06:00?
4. Optional due-time notifications showing only the thought's own text: on or off?

### Critical files for implementation
- Sources/FlamingoCore/SidecarFormat.swift
- Sources/FlamingoCore/SidecarStore.swift
- Sources/FlamingoIndex/IndexStore.swift (with Schema.swift, Semantic.swift, UnifiedSearch.swift)
- Sources/FlamingoAsk/AskEngine.swift (with Retrieval.swift)
- Sources/Flamingo/RootView.swift (with AppDelegate.swift, AppState.swift, QAHook.swift)