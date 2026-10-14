# Plan 02 — Core

**You own:** `Sources/FlamingoCore/`, `Tests/FlamingoCoreTests/`.
**Read first:** `CONTRACT.md`. Your public API is the most-depended-on in the project; it
is frozen. Add, never rename.

## Mission

The model layer everyone trusts. Sidecar notes that round-trip byte-for-byte, wikilinks that
resolve the way Obsidian users expect, and file identity that survives rename. Pure, fast,
tested. No UI, no AppKit beyond `FileManager`.

## Milestones, in order

### M1 — Sidecar format, bulletproof
- `SidecarFormat.parse` and `.render` are exact inverses. Multi-line comments (continuation
  lines indented two spaces). Anchors `(kind value)` where value may contain spaces and `!`.
  Unknown anchor kinds are preserved as text, not dropped. Frontmatter may have extra keys;
  preserve them on round-trip.
- `SidecarStore`: `comments(for:)`, `append`, `update`, `delete`, `all()`. Atomic writes
  (write temp, rename). Creates `notesDir` subfolders as needed. `all()` walks `notesDir`
  and also returns sidecars whose target file no longer exists (so plan 05 can show orphans).
- Tests with real fixtures in `Tests/FlamingoCoreTests/Fixtures/`. Property-style test:
  render(parse(x)) == x for a dozen hand-written sidecars including edge cases.

### M2 — Wikilinks
- `Wikilink.parse`: aliases, `#anchor` suffixes, nested brackets ignored, code spans ignored.
- `Wikilink.resolve`: relative path → basename → basename without extension → case-insensitive.
  When multiple candidates match, prefer the one in the same folder as the source file (add
  `resolve(_:from:in:candidates:)` overload).
- `Wikilink.anchor(in: "q3.pptx#slide 3") -> FileAnchor?` parsing the suffix.

### M3 — File identity
- `FileIdentity.id(for:)`: read xattr `com.flamingo.id`; if absent write a new UUID. Use
  `getxattr`/`setxattr`. Packages (`.key`, `.numbers`) get the xattr on the package folder.
- `FileIdentity.locate(id:in:)`: walk the vault looking for the id. Cache a map in memory.
- `SidecarStore.reconcile()`: for every sidecar whose `target` path no longer exists but whose
  `id` is found elsewhere, move the sidecar to the new path and rewrite `target`. This is how
  renames heal. Test it.

### M4 — Scanner
- `VaultScanner.files(in:)`: treat packages as files, skip `.flamingo`, `.git`, `node_modules`,
  Library-style folders. Return sorted with `localizedStandardCompare`. Add
  `VaultScanner.tree(in:) -> [TreeNode]` for the shell's folder tree (folder nodes with children).
- Respect `.flamingoignore` (gitignore-style globs, keep it simple: `*`, `**`, leading `/`).

## Done means
`scripts/test.sh --filter FlamingoCoreTests` passes with meaningful coverage. The sidecar
round-trip test is exhaustive. Rename a file in a test vault and the sidecar follows it.

## Don't
- Don't depend on anything outside Foundation.
- Don't change the sidecar format. Obsidian compatibility is the point.
