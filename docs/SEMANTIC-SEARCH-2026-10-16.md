# Semantic search: what changed (2026-10-16)

Short version: semantic search is now on by default and handles Chinese and cross-language
queries. On the bilingual benchmark the palette's MRR went from 0.31 to 0.96, and on the
fixture vault from 0.46 to 0.84. Vectors live in memory as Int8, so a query over 500k passages
takes 5 ms. Background embedding gives way to the user, skips text it has already embedded
(by hash), and starts with the newest files. There is a new file-similarity API
(`similarFiles`, `similarPairs`) for connections. Every number below was measured on this
M5 Pro.

## 1. Benchmark

I built two relevance sets. Each query lists the files that answer it (for MRR, the first
relevant hit counts). Most queries are paraphrases with little or no word overlap with the
target file.

| Set | Files | Queries | Kinds |
|---|---|---|---|
| `fixtures/vault` (fresh copy) | 19 files, 96 sections, 23 thoughts | 33 | 25 English paraphrases ("the doc about lamp pricing", "what did Maya say about flicker", "how many months until we run out of money"), 5 Chinese/mixed ("灯的定价备忘录", "Arc 的发布日期"), 3 exact keyword controls |
| Synthetic bilingual vault (`SemanticBenchmarkCorpus.swift`) | 51 target documents (English, Chinese, mixed; two with thoughts), plus 1,200 generated distractors (status reports, invoices, logs, reading notes, Chinese weekly reports) = 1,251 files, 2,500 sections | 100 | 35 en, 15 zh, 40 cross-language (English query → Chinese document and back), 4 with several answers (English/Chinese twins), 6 exact keyword controls |

How to run it:
- `FLAMINGO_LIVE=1 scripts/test.sh --filter SemanticBenchmarkTests` prints both tables.
  Optional environment variables:
  - `FLAMINGO_EMBED_MODEL=<ollama tag|apple|none>` picks the model.
  - `FLAMINGO_BENCH_DIR=<dir>` keeps the vaults and vectors between runs and writes
    `<dir>/bilingual-1200.cases.json`.
  - `FLAMINGO_BENCH_CALIBRATE=1` prints cosine distributions.
  - `FLAMINGO_BENCH_MISSES=1` prints the misses.
- `flamingo-index <vault> --no-reindex --eval cases.json` runs any vault against any cases
  file and prints the same table.
- The default test run always runs `testHarnessScoresKeywordSearchOnTheCorpus`, a smoke test
  that needs no model.

The modes are the real callers:
- `lexical` is `search(includeSemantic: false)`.
- `semantic-only` is the semantic ranking alone.
- `hybrid search()` is the file-level search used by the CLI and the API.
- `sections (Ask)` is `searchSections`, which is what `FlamingoAsk` retrieval uses.
- `palette lexical` is `unifiedSearch` without semantic: the first pass shown in ⌘K.
- `palette semantic` is `unifiedSearch(includeSemantic: true)`: the second pass in ⌘K.

### Quality, before and after (recall@5 / MRR@10)

"Before" means the original code with `nomic-embed-text`. "After" means the new code with
`qwen3-embedding:0.6b`, which is picked automatically now.

Bilingual vault, 100 queries:

| Mode | Before | After |
|---|---|---|
| lexical | 0.265 / 0.233 | 0.255 / 0.229 |
| semantic-only | 0.360 / 0.355 | **0.980 / 0.953** |
| hybrid `search()` | 0.395 / 0.370 | **1.000 / 0.980** |
| sections (Ask) | 0.335 / 0.319 | **1.000 / 0.980** |
| palette lexical | 0.235 / 0.226 | 0.265 / 0.233 |
| **palette semantic (⌘K)** | 0.325 / 0.308 | **0.990 / 0.955** |
| cross-language subset (40) | 0.000 / 0.000 | 0.975 / 0.950 |
| zh subset (15) | 0.533 / 0.478 | 1.000 / 1.000 |
| exact-keyword subset (6) | 1.000 / 1.000 | 1.000 / 1.000 |

Fixture vault, 33 queries:

| Mode | Before | After |
|---|---|---|
| lexical | 0.636 / 0.460 | 0.667 / 0.483 |
| semantic-only | 0.621 / 0.514 | **0.939 / 0.790** |
| hybrid `search()` | 0.727 / 0.566 | **0.939 / 0.824** |
| sections (Ask) | 0.758 / 0.583 | **0.939 / 0.832** |
| palette lexical | 0.460 / 0.408 | 0.551 / 0.435 |
| **palette semantic (⌘K)** | 0.520 / 0.463 | **0.939 / 0.841** |

Exact keyword queries still win: "q3 model", "Lumen Optics", "MU588", "PR #482" and "令牌桶"
all stay at their old ranks. In the palette, an exact name scores 110 and a full keyword match
up to 78, while a file found only by meaning tops out at 72.

### Models compared (new code only; recall@5 / MRR)

| Model | Bilingual palette | Bilingual hybrid | Fixture palette | Fixture hybrid | Embed speed* | Query (warm) |
|---|---|---|---|---|---|---|
| **qwen3-embedding:0.6b** (default) | 0.990 / 0.955 | 1.000 / 0.980 | 0.939 / 0.841 | 0.939 / 0.824 | ~25–35 passages/s | ~40 ms |
| embeddinggemma (300M) | 0.970 / 0.945 | 0.980 / 0.970 | 0.778 / 0.736 | 0.879 / 0.838 | ~50/s | ~50 ms |
| nomic-embed-text | 0.455 / 0.433 | 0.465 / 0.447 | 0.818 / 0.698 | 0.818 / 0.721 | ~120/s | ~10 ms |
| Apple NLContextualEmbedding | 0.305 / 0.249 | 0.305 / 0.281 | 0.566 / 0.462 | 0.626 / 0.494 | ~50/s (CPU/ANE) | ~6 ms |

\* Measured on the benchmark corpus with yielding and pauses switched on. Ollama runs inputs
one at a time, so throughput on long passages is lower: qwen3 managed about 15 passages/s
on 1,000-character chunks.

- nomic does better under the new code than under the old (fixture palette 0.46 → 0.70).
  It is English-only, though, so the bilingual numbers stay low.
- I measured Apple's on-device models directly: `NLEmbedding.sentenceEmbedding` and
  `NLContextualEmbedding`, mean-pooled, with and without mean-centering. Their cosines all sit
  between 0.80 and 0.90 and barely separate relevant from irrelevant passages. As a fallback
  they are roughly as good as keyword search and do no harm, but they are not a real
  substitute. The fallback chain keeps them as the "no server" tier, as the brief asked.
- In-memory dimensions were tested at 256, 512 and 1,024 for qwen3. 512 scored best (1,024
  scored lower under the same calibration; 256 cost 2–3 MRR points on the bilingual set).

### Latency (release build, M5 Pro, `flamingo-index <dir> --vector-bench N`)

The benchmark uses 512 dimensions, 10 passages per file and clustered topics.

| Passages | Load (once per process) | Memory | Top-200 query p50 / p95 | `similarFiles` first call / then | `similarPairs` (perFile 3) |
|---|---|---|---|---|---|
| 10k | 8 ms | ~5 MB | 0.3 / 0.3 ms | 5 ms / 0.17 ms | <10 ms (1k files) |
| 100k | 132 ms | ~55 MB | 1.2 / 1.4 ms | 44 ms / 0.77 ms | 40 ms (10k files) |
| 500k | 754 ms | ~277 MB | 5.4 / 5.7 ms | 237 ms / 3.5 ms | 0.96 s (50k files) |

End to end:
- Query embedding: qwen3 takes about 40 ms when the model is loaded and 0.8–1 s when Ollama
  has to load it. A cached query costs 0 ms.
- On the bilingual vault, the palette's semantic pass takes 1.4–3 ms once the query vector is
  cached. The lexical pass prefetches that vector, so in practice it is cached.
- Ask's `searchSections` went from 144 ms p50 to 1 ms p50. The slow part was lexical: FTS
  computed a snippet for every match of an any-term query. It now ranks first and builds
  snippets only for the hits it keeps.
- Before, every semantic query read all vector blobs out of SQLite: 16 ms for 2.5k sections,
  and about 1.5 GB per query at 500k.

## 2. What changed, and why

**Embeddings: a model chain with no setup** (`Embeddings.swift`)
- `Embedder.resolve()` asks Ollama what it has installed (`/api/tags`, cached for 30 s) and
  picks the best embedding model it knows: qwen3-embedding → embeddinggemma → bge-m3 →
  snowflake-arctic-embed2 → mxbai-embed-large → nomic-embed-text → granite / multilingual /
  minilm. Any other model with "embed" in its name is used with plain wording.
- With no Ollama model at all, it falls back to Apple's on-device `NLContextualEmbedding`:
  Latin and CJK models, mean-pooled, laid side by side as `[Latin 512 | CJK 512]`.
- With neither, nothing is embedded and search stays keyword-only. No errors.
- To force a choice, set `FLAMINGO_EMBED_MODEL` or the `FlamingoEmbedModel` user default to
  an Ollama tag, `apple` or `none`.
- The model is sticky. Once a vault is embedded with an Ollama model, a sleeping Ollama makes
  embedding wait; it does not drop to a weaker model. A better model installed later is
  picked up, and the vault is re-embedded in place. While that runs, search covers both models
  and compares calibrated relevance.
- Each model has an `EmbeddingProfile` with:
  - its query and document wording (nomic `search_query:`/`search_document:`, gemma
    `task: search result | query:` / `title: … | text:`, qwen3's instruction),
  - a calibrated floor and "strong" cosine, so relevance runs 0 at the floor and 1 at a
    strong match and is comparable across models,
  - a floor for file-to-file similarity,
  - a Matryoshka truncation (qwen3 and gemma: 512),
  - a context window (`num_ctx` 2048 for qwen3: 1.1 GB loaded instead of 5.7 GB).
- Vectors are stored as Int8 with a scale (`VectorCodec`): a quarter the size of Float32,
  cosine error about 0.002. Matryoshka models are stored at 512 dimensions.

**Passages** (`Chunking.swift`)
- Sections are split into passages of about 240 tokens (≈950 Latin characters or ≈240 Han
  characters). Cuts fall on a paragraph, line or sentence end, with about 30 tokens of overlap.
- Each passage carries a header naming its file and section, e.g. `Arc Pricing
  (pricing-memo.docx) › Recommendation`. This header alone took nomic's MRR on the fixture
  probe from 0.56 to 0.68.
- A file whose text lives in its sections gets one extra card passage: title, file name,
  folder, tags, a contents line of section titles, and the opening lines. This is what answers
  "the doc about …".
- In spreadsheets, every passage after the first repeats the column header row.
- Thoughts (comments) are embedded too, as "Thought on <file>, <anchor>: …". "What did Maya
  say about flicker" now finds her comment at 0:39.
- Offsets count Unicode scalars, so a passage can be read back with SQLite's `substr` without
  loading the whole section. There is a test with emoji and combining marks.
- Very long files keep their first 160 passages. The rest stays keyword-searchable.

**Background embedding** (`EmbeddingPass` in `Semantic.swift`)
- Order: thoughts first, then sections. The first pass after launch, and every hour after
  that, sweeps all files newest first, keyed on `files(mtime, rowid)`. In between, a pass only
  looks at section rowids above a watermark, with a 10k margin because SQLite can reuse rowids
  at the top.
- Each page is written in one transaction. Before writing, the pass checks that the section's
  text and title haven't changed since it read them. It is resumable at any point.
- Unchanged text is never sent to a model twice. When `embedding_spans` or `comment_vectors`
  rows are deleted (a file re-extracted, renamed or retitled, or a full re-extraction after an
  extractor update), a trigger copies their vectors into `semantic_cache`, keyed by
  `fnv1a(model + exact input)`. The test proves a forced re-extraction of every file makes zero
  model calls.
- Batches are sized to about 0.35 s per request and adapt to the model's speed.
- It gives way to the user:
  - Before each request it waits for 1.5 s of quiet after the last interactive search
    (process-wide), so the model's queue is free for the user's query.
  - It pauses roughly 15% between Ollama batches, slows down when the Mac reports serious
    thermal state, and stops below 30% battery.
  - The queue runs at `.background` QoS and never holds the write lock while a model runs.
- A new thought reaches the index right away. The writer's `invalidateCaches` (which sets
  `EmbeddingState.matrix = nil`) now queues a coalesced embedding pass. Before, a comment-only
  change was never embedded.
- After each finished pass, cache entries older than 14 days are pruned, or sooner once the
  cache outgrows the live index.

**Query path** (`VectorIndex.swift`)
- Each model's vectors sit in memory as contiguous Int8 rows plus scales. One `VectorIndex`
  is shared by every `IndexStore` open on the same file, so the app's writer and its three
  search readers hold a single copy. When the last store goes away, it is freed.
- A query runs Int8→Float conversion (`vDSP_vflt8`), then a matrix–vector product
  (`vDSP_mmul`) over 1,024-row blocks spread across cores, keeping a running top-k. Blocks
  whose maximum is below the threshold are skipped. There is no SQL over vectors at query time.
- Refreshing is incremental and cheap: two index seeks pick up new rows. Deletions are found
  three ways: by verifying candidates in SQL, by a throttled audit of the model index when the
  store has written, and by guards against rowid reuse. It uses its own read-only connection,
  so loading never holds a store's reader, and the keystroke searches queued behind it are not
  delayed.
- Query vectors are cached process-wide (512 entries), and identical requests in flight are
  merged. Interactive callers wait at most 0.8 s; a slower answer, such as Ollama loading the
  model, still lands in the cache for the next keystroke.
- `unifiedSearch(includeSemantic: false)` starts loading vectors and fetching the query's
  embedding in the background (`IndexStore.prefetchSemantic`, off under XCTest). The palette's
  semantic pass 550 ms later then finds both ready. It never waits on this work.

**Fusion and ranking** (`Search.swift`, `UnifiedSearch.swift`)
- The any-term keyword fallback drops words like "what", "did", "about" and "the" when
  something else is left. Words like "who", "when", "where", "why" and "how" stay, because
  headings use them ("Who it is for").
- `search()` and `searchSections()` use weighted reciprocal rank fusion:
  - Keyword hits count fully when every word matched. When only some matched they count 0.35,
    scaled by the share of the query's words their snippet contains.
  - Meaning hits count 0.8 × (0.35 + 0.65 × relevance).
  - Sections are fused by section identity, not by the refined line, so a section found both
    ways merges.
  - When the keyword hit only matched the file name, the merged result takes the meaning hit's
    location.
- Palette (`unifiedSearch`) scores:

  | Evidence | Score |
  |---|---|
  | Exact file name | 110 |
  | File name contains the query | 85 |
  | Content matching every word | 70–78 |
  | Thought matching every word | 74–82 |
  | Partial keyword match (any-term fallback) | 52–60 |
  | Found only by meaning | 48 + 24 × relevance (48–72) |

  - Meaning that agrees with a full keyword match adds up to 8.
  - With a partial match, the file takes whichever score is higher, plus up to 3.
  - Recency stays a light tiebreak (+2 at most).
- Results explain themselves. Each file's best passage is attached as a hit. Its snippet is
  the passage's best sentence for the query, with shared words marked «…». A line-anchored
  passage (Markdown, text, code) opens at that sentence's exact line. A file card gives way to
  the file's best real passage when the two are close.

**File similarity** (`Similarity.swift`)
- A file's vector is the normalized mean of its passage vectors. Thoughts count half, or a
  quarter when the file has four or more passages.
- File vectors are built from the in-memory index, cached on it, and rebuilt at most every
  5 s while embedding runs. `similarFiles` results are memoized per file, limit and
  generation.
- Pairs are computed with blocked `vDSP_mmul` against a transpose built once. Each row's top
  `perFile` above `minScore` is found with `vDSP_maxvi`.
- On the fixture vault: pricing-memo ↔ pricing-decisions 0.91, whiteboard-pricing ↔ memo 0.81,
  arc-lamp.usdz ↔ product brief 0.73 (passage: "Shade diameter 140 mm…"). On the bilingual
  vault the English/Chinese twins pair up: api-rate-limiting ↔ 接口限流方案 0.78, moving ↔
  搬家清单 0.74.

## 3. New public API (FlamingoIndex)

Requested by the UI owner, with exact signatures, in `Similarity.swift`:

```swift
public func similarFiles(to ref: FileRef, limit: Int) throws -> [(file: FileRef, score: Double, passage: String?)]
public func similarPairs(minScore: Double, perFile: Int) throws -> [(a: String, b: String, score: Double)]
public static let similarPairsFileCap = 50_000
public func similarityFloor() -> Double
```

`similarFiles(to:limit:)`
- Returns nearest neighbours by meaning, excluding `ref`.
- `score` is the cosine of the two files' mean vectors, clamped to 0…1. Only neighbours at
  or above `similarityFloor()` are returned.
- `passage` is the other file's passage closest to `ref`: a one-line excerpt of up to 160
  characters, preferring real text over file cards.
- Returns `[]` and never throws when nothing is embedded yet, when `ref` has no vectors, or
  when no model is available.
- Cost: about 0.2 ms at 10k passages and 3.5 ms at 500k. Memoized after that until the
  vectors change.

`similarPairs(minScore:perFile:)`
- Returns relative paths with `a < b`, each pair once, best first. Each file contributes at
  most `perFile` neighbours at or above `minScore`.
- Cost is quadratic: 40 ms for 10k files and 0.96 s for 50k.
- Above `similarPairsFileCap` (50,000) files, only the 50,000 most recently modified take
  part. Call it off the main thread.
- Returns `[]` when nothing is embedded.

`similarityFloor()`
- Returns the current model's recommended `minScore`: 0.62 for qwen3-embedding, 0.60 for
  embeddinggemma, 0.78 for nomic, 0.92 for Apple.
- Raw cosines are not comparable across models, so pass this rather than a constant. Only
  qwen3's value is calibrated on data (the twins score 0.74–0.91; nothing unrelated scores
  above 0.62). The others are estimates.

Also new:

```swift
// Passages and thoughts by meaning, each with what explains it.
public struct SemanticSearchHit: Sendable, Equatable {
    public var hit: SearchHit        // file, anchor (exact line when line-anchored), snippet (best sentence, «marks»), commentID
    public var passage: String       // the whole matched passage
    public var relevance: Double     // 0 at the model's floor, 1 at a strong match (can exceed 1)
    public var score: Double         // raw cosine
    public var model: String
}
public func semanticSearch(_ query: String, inFolder folder: String? = nil, limit: Int = 20) throws -> [SemanticSearchHit]

public struct SemanticStatus: Sendable, Equatable { model: String?; embedded, total, embeddedComments, comments: Int }
public func semanticStatus() -> SemanticStatus

public func warmSemanticSearch(query: String? = nil)       // load vectors + embed the query in the background; returns at once
public nonisolated(unsafe) static var prefetchSemantic: Bool // lexical unifiedSearch prefetches; off under XCTest

public struct EmbeddingProfile { backend, id }               // one model's wording, floors, dimensions
public var Embedder.preferred: String?                       // Ollama tag, "apple" or "none"; nil = best installed
public static var Embedder.defaultPreference: String?        // FLAMINGO_EMBED_MODEL / FlamingoEmbedModel

public enum SemanticEval { Case, Score, Miss, Report, run(_:mode:k:rank:), table(_:) }   // the benchmark harness
public enum SemanticBench { static func vectorSearch(passages:in:) throws -> [String] } // synthetic latency bench
```

Unchanged:
- `search`, `searchSections`, `searchComments` and `unifiedSearch` keep their signatures.
  `unifiedSearch(includeSemantic: true)` now returns passage hits and the new scores.
- `embedPending`, `embeddingProgress`, `scheduleEmbedding`, `cancelBackgroundWork`,
  `autoEmbed`, `Embedder.model`/`url`/`init()` are all kept.
- Nothing public was renamed or removed.

CLI additions (`flamingo-index`):
- `--semantic "q"`, `--hybrid "q"`, `--similar <path>`, `--pairs [min]`
- `--embed`: foreground embedding with progress
- `--eval cases.json`
- `--vector-bench N`
- The CLI now turns off background auto-embedding unless `--watch` is given. A background
  pass would die with the process, and before this change it made `--embed` a no-op.

## 4. Schema

All of it is additive and idempotent. The DDL lives in `Schema.semanticColumns` and
`Schema.semantic`:
- `embedding_spans` (v5) gains `hash INTEGER` and `length INTEGER`, plus an index on
  `(model, section)`. It stays the passage table: one row per passage, `offset`/`length` in
  Unicode scalars, `vector` = Float32 scale + Int8 components. A row with offset -1 and an
  empty vector marks a section with nothing to embed.
- New tables:
  - `comment_vectors(comment PK, model, hash, vector)`
  - `semantic_cache(model, hash, vector, ts)`, `WITHOUT ROWID`, with an index on `ts`
- New triggers:
  - deleting or updating a comment drops its vector,
  - deleting a span or comment vector copies it into the cache.
- Old Float32 nomic rows (`hash IS NULL`) and the legacy `embeddings` table are cleared once.
  They used a different format and different passages. The existing v3 and v5 triggers on
  `sections` still drop spans when a section changes.

**Version:** `IndexStore.schemaVersion` and the migration ladder are in `IndexStore.swift`,
which I don't own. Bumping `user_version` without them would make every read-only store fail
to open and make `configure` recreate the index. So I did **not** bump it. Instead,
`IndexStore.ensureSemanticSchema()` applies the DDL lazily on the writer, inside a
transaction, recording `meta.semantic_schema = 1` so it runs once. Read-only stores only check
that the tables exist and stay keyword-only until they do; this is re-checked each time and
never cached as false.

Recommended follow-up for the IndexStore owner: make it a numbered step. Add
`static let v8 = <semanticColumns guarded by table_info> + Schema.semantic + "PRAGMA user_version = 8;"`,
set `schemaVersion = 8`, and add `if v < 8 { … }`. The lazy path then becomes a no-op.

## 5. How embeddings are produced, and what happens without a model

1. The writer's background pass resolves a model: the preference, else the best installed
   Ollama embedding model, else Apple on-device (if its assets are present; it requests a
   download otherwise), else none.
2. With a model, passages and thoughts are embedded newest first, cache hits skip the model,
   and vectors are written per page. `meta.semantic_model` records the model. Read-only stores
   read whatever models are present.
3. Ollama installed but not running: embedding waits (no fallback to a weaker model). Query
   embedding marks Ollama down for 30 s after a refused connection, so keystrokes don't wait on
   it. Search is keyword-only until it's back.
4. No model at all: `embedPending()` returns 0, `semanticSearch`, `similarFiles` and
   `similarPairs` return `[]`, and `search`/`unifiedSearch` return exactly the keyword results.
   Nothing throws.

## 6. Things other owners should know

- **UI owner:** my `similarFiles` will clash with your `SimilarityStub.swift` until you delete
  it, as you planned. I did not touch `Graph.Edge.Kind` or add `similarEdges`.
- **IndexStore / SQLite owner:** I depend on these internals:
  - `IndexStore.writer`, `writeLock`, `embedding`, `read(snapshot:)`, `databaseURL`,
    `invalidateCaches()` setting `embedding.matrix = nil` (now also my "something was
    written" hook), `refreshReadOnlyCaches()`
  - the static helpers `json`, `anchor(_:_:)`, `clean`, `folderPredicate`
  - Titles.swift's `onLowBattery()`, `autoTitle` and `titlePending()`
  - SQLite.swift's `Database(path:readOnly:)` and `Row.handle`, for zero-copy blob reads
  - the existing triggers `sections_spans_ad`/`sections_spans_au`

  If `write()` ever updates sections in place instead of delete-and-insert, everything still
  works: the update trigger drops the spans and the cache returns their vectors.
- **Ask:** `searchSections` hits can now carry a refined line anchor inside a section, and can
  be thoughts (`commentID` set). `Retrieval.sectionText(for:)` already resolves line anchors to
  their section.

## 7. Tests

- `scripts/test.sh` is fully green: **1,049 tests, 12 skipped, 0 failures**. Before my change:
  1,028 tests, 10 skipped, 0 failures.
- New tests: `SemanticIndexTests` (18) and `SemanticBenchmarkTests` (3, of which the 2 live
  ones are skipped by default).
- `FLAMINGO_LIVE=1` runs pass: `SemanticLiveTests` (the existing test, including "zebra
  migration patterns" scoring below the floor) and `SemanticBenchmarkTests`.
- The existing `SemanticTests` and `UnifiedSearchTests` pass unmodified.

## 8. Changes to this Mac

- I pulled `qwen3-embedding:0.6b` (639 MB) with Ollama. It is now Flamingo's default model.
  `ollama rm qwen3-embedding:0.6b` reverts to nomic-embed-text automatically.
- I pulled `embeddinggemma` for the comparison and removed it afterwards.
- Port 8080 and the user's app were not touched.

## 9. Files changed or created

Changed:
- `Sources/FlamingoIndex/Semantic.swift` (rewritten)
- `Sources/FlamingoIndex/Embeddings.swift` (rewritten)
- `Sources/FlamingoIndex/Search.swift`
- `Sources/FlamingoIndex/UnifiedSearch.swift`
- `Sources/FlamingoIndex/Schema.swift` (additive DDL only)
- `Sources/FlamingoIndexCLI/main.swift`

Created:
- `Sources/FlamingoIndex/Chunking.swift`
- `Sources/FlamingoIndex/VectorIndex.swift`
- `Sources/FlamingoIndex/Similarity.swift`
- `Sources/FlamingoIndex/SemanticEval.swift`
- `Sources/FlamingoIndex/SemanticBench.swift`
- `Tests/FlamingoIndexTests/SemanticIndexTests.swift`
- `Tests/FlamingoIndexTests/SemanticBenchmarkTests.swift`
- `Tests/FlamingoIndexTests/SemanticBenchmarkCorpus.swift`

No other files were touched. Nothing changed in `Package.swift`, `IndexStore.swift`,
`SQLite.swift`, the existing tests, or other modules.
