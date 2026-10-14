# Flamingo

Flamingo is Obsidian for every file on your Mac. Open a folder and preview anything in it:
decks, documents, spreadsheets, PDFs, 3D models, images, video, code, and markdown. Press a
key to leave a thought on the slide, page, cell or moment you're looking at, and link
thoughts with `[[wikilinks]]`. The graph then shows how your real work connects. Flamingo
also records a trail of what you opened, said and searched, so the chain of thought behind a
decision builds itself without you typing the links. It never writes into your files.

![Flamingo on the demo vault](docs/screens/graph-dark.png)

## Keys

| Keys | Action |
|---|---|
| ⌘O | Open a folder as a vault |
| ⌘K | Command palette: open any file, run any command |
| ⌘F | Search the vault |
| ⌘⇧C | Leave a thought on the current file |
| ⌃⌥Space | Leave a thought from any app (opt in; needs Accessibility). If ⌃⌥Space switches your input source, it's ⌃⌥⌘Space |
| ⌘1 ⌘2 ⌘3 ⌘4 | Files, Graph, Trail, Ask |
| ⌘⌥I | Show or hide comments |
| ⌘[ ⌘] | Back, forward |
| ⌘↑ ⌘↓ | Previous or next page or slide |
| Esc | Dismiss |

## Build and run

Requires macOS 14 or later and Xcode, not just the Command Line Tools. `scripts/env.sh` finds
Xcode-beta or Xcode in `/Applications`; set `DEVELOPER_DIR` to use another. There are no
dependencies to install.

```
make demo      # build, copy the demo vault to a temp folder, open it
make run       # build and launch on your last vault
make test
make release   # build/Flamingo.zip
```

The demo vault in `fixtures/vault/` belongs to a small studio launching a desk lamp. It
holds real decks, documents, sheets, PDFs, images, a video, an interview recording, a 3D
model, notes, comments, and two days of trail. `make demo` always opens a fresh copy.

## Where state lives

Everything Flamingo knows lives in `<vault>/.flamingo/`, as files you can read with `cat`:

```
.flamingo/
  notes/decks/q3-board-review.pptx.md   thoughts on that file, one per line
  trail.jsonl                           what you opened, said and searched
  trail-names.json                      names you gave your thought chains
  index.sqlite                          full-text index (rebuildable)
  graph.json                            links and trail edges (rebuildable)
  graph-layout.json                     where you left the graph's nodes
```

A thought looks like this:

```
- [2026-10-13 14:11] (slide 7) Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229.
```

Flamingo never changes a file's contents. Its one mark on a file is an extended attribute,
`com.flamingo.id`, holding an id. That id lets thoughts follow a file when you rename or move
it, even while Flamingo is open. Delete `.flamingo/` and everything else Flamingo knew is gone.

## Obsidian

Sidecars are ordinary markdown. Open a vault's `.flamingo/notes/` folder in Obsidian and
every file's thoughts are a note there. A link that names a file with its extension, such as
`[[q3-model.xlsx]]`, opens the notes on that file. Inside Flamingo, links resolve the way
Obsidian's do: by path, then by file name, then by file name without its extension.
