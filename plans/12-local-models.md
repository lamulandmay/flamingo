# Plan 12 — Local models

**You own:** `Sources/FlamingoAsk/`, `Sources/FlamingoIndex/`, `Tests/FlamingoAskTests/`,
`Tests/FlamingoIndexTests/`. Plan 11 is in Core and the shell; don't touch those. If you need a
shell hook, append to `plans/REQUESTS.md`.
**Read first:** `CONTRACT.md`, `ISSUES.md` (Ask has no focused field; fix that first, it's yours).

## What's on this Mac
- M5 Pro, 64 GB.
- Qwen3.8-27B, Unsloth Q5_K_XL GGUF + vision mmproj, at
  `~/codex/cgnsa/data/models/qwen3.8-27b/`. Runs with `llama-server` (`/opt/homebrew/bin`).
  Loads in ~36 s, ~26 GB resident. Thinking is on by default; turn it off per request.
- Ollama (`Ollama.app`, server not always running) with `gemma3:4b`, `llama3.2:1b`, `qwen2.5:1.5b`.
- No embedding model yet: `ollama pull nomic-embed-text`.

## Mission
Flamingo works fully offline. Search gets semantic. Indexing gets titles and tags from a small
model. Ask uses the 27B locally, Claude when a key and network exist. Nothing heavy runs in
the indexing hot path.

## Milestones
### M1 — Ask works at all
- Fix focus: the field takes first responder on ⌘4 and whenever the window becomes key in Ask
  mode. Verify by typing immediately after ⌘4.
- `LLMClient`: one OpenAI-compatible chat client (streaming SSE) with a `baseURL` and model
  name. Providers: `anthropic` (existing), `llama` (`http://127.0.0.1:8080/v1`), `ollama`
  (`http://127.0.0.1:11434/v1`). Palette command "Ask: Use Local Model" / "Use Claude", stored in
  UserDefaults. Auto: Claude if key + network, else local.
- `LlamaServerManager`: starts `llama-server -m <gguf> --mmproj <mmproj> -c 16384 --port 8080
  --jinja` on first local Ask, keeps it running, stops on quit. Health-check `/health`. While
  loading, Ask shows one tertiary line: `loading qwen3.8-27b`. Request body sets thinking off
  (`chat_template_kwargs: {enable_thinking: false}` or `reasoning_effort: "low"`; check the
  model card in that folder for the exact key).

### M2 — Embeddings and hybrid search
- `IndexStore`: `embeddings(path, anchor_kind, anchor_value, vector BLOB)` table. Embed each
  section's text (truncate ~512 tokens) with `nomic-embed-text` via Ollama's `/api/embed`,
  batched 32 at a time, at `.background` QoS after FTS indexing completes. Skip if Ollama isn't
  running; retry on next reindex.
- `search` becomes hybrid: FTS5 bm25 hits merged with top-50 cosine hits (brute force over
  Float32 vectors with Accelerate `vDSP`; fine up to a few hundred thousand). Reciprocal rank
  fusion. Same `SearchHit` API; nothing in the shell changes.
- Ask retrieval uses the same hybrid search.

### M3 — Titles and tags from a small model
- At idle after indexing, for files with no good title (binary formats, images, code), ask
  `gemma3:4b` for `{title, tags[3]}` from the first ~1500 chars. Store in `files.title` and a
  new `tags` column; both indexed by FTS. Rate: one at a time, `.background`, pause when on
  battery below 30%. Never block search or the UI.

### M4 — Vision, lazily
- `describe(image:)` via the 27B with mmproj (llama-server accepts `image_url` data URIs). Called
  only on demand: a palette command "Describe Image" on an image or a rendered slide. Result
  appended to that file's sidecar as a comment anchored `(region full)` with text prefixed
  nothing; it's just a thought the model left. Not in the index pipeline.

## Done means
Pull the network cable. ⌘4, type a question, see a cited answer from the 27B. Search for a
concept with no keyword overlap and find it. New files get titles and tags within minutes.
