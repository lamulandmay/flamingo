# Plan 09 — Ask

**You own:** `Sources/FlamingoAsk/`.
**Read first:** `CONTRACT.md`, `DESIGN.md`. `AskEngine`, `Answer`, `Citation`, `AskView` are
frozen. Load the `claude-api` skill before writing any API code so model ids and request
shapes are current; don't work from memory.

## Mission

Ask the vault a question in plain words and get an answer that cites the slide, the sheet,
and your own comment that connected them. Retrieval from the index, one Claude call,
citations that open the file at the anchor. Nothing happens without a key; the view is
simply absent until one is set.

## Milestones, in order

### M1 — Retrieval
- `AskEngine.retrieve(question) -> [Passage]`: `IndexStore.search` for the question and for
  2–3 reformulations (split on "and", drop stopwords). Take the top ~20 sections and all
  matching comments. Dedupe by file+anchor. Pack within a token budget (~12k tokens),
  comments first because they're the user's own thinking, then sections by score.
- `Passage` carries `FileRef`, `FileAnchor?`, text, and a short id like `[3]`.

### M2 — The call
- Messages API via `URLSession`, streaming (SSE). Key from `ANTHROPIC_API_KEY` in the
  environment, else Keychain item `com.flamingo.anthropic`. Add `AskEngine.setKey(_:)` which
  stores to Keychain.
- Default model: the latest Sonnet-class model per the skill. Add `AskEngine.model` so the
  shell can switch.
- System prompt: answer only from passages, cite with `[n]` after each claim, say when the
  vault doesn't contain the answer, be brief, no preamble. Parse `[n]` in the response into
  `Citation`s. Return `Answer`. Also expose `askStreaming(_:) -> AsyncThrowingStream<Delta>`.
- Record `.searched` in the trail? No. Leave trails to the shell.

### M3 — The view
- `AskView`: a single text field at the top (no placeholder, no button), the answer below as
  rendered markdown-lite (paragraphs, bullets, bold, inline code), citations as inline accent
  `[3]` that on hover show the file name + anchor in a small chip and on click call `onOpen`.
  Under the answer, a row of the cited files as chips. Previous questions stack above, faded;
  ⌘↑ recalls them.
- While streaming: text appears as it arrives, no spinner. Errors: one tertiary line.
- If no key: the view shows a single mono text field for the key, nothing else. Paste, Enter,
  it's stored, the field becomes the question field.

### M4 — Agentic follow-ups (if time)
- Let the model call a `search(query)` tool up to 3 times before answering, so questions
  that need two hops ("what did I say about the slide that mentions churn") work. Use the
  tool-use loop from the skill.

## Done means
Ask "what did I decide about pricing" on a vault with a deck, a sheet, and a comment linking
them, and get a three-sentence answer with three citations that each open the right place.

## Don't
- Don't send file contents beyond the retrieved passages. Don't log the key. Don't add a
  chat UI with avatars and bubbles; this is a question and an answer.
