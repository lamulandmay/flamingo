# Flamingo plan 18: agent projects, one rigid structure, files that remember why

## Context

People who code with agents run Claude Code, Codex and other harnesses in their folders. Each
harness keeps structure for itself (its memory, its sessions, its instruction file), keyed by
harness and by path. Nothing is keyed by the work. Files are the only thing every agent and the
person share, and files carry no structure.

Evidence from this Mac on 2026-10-18, for this repo:
- 37 Claude Code sessions and 38 Codex sessions have worked here.
- Claude keeps 26 memory files in `~/.claude/projects/-Users-allenwu-claude-flamingo/memory/`.
  Codex keeps one 2,007-line `~/.codex/memories/MEMORY.md` for every project. Neither reads the other's.
- "Thoughts never leave this Mac" is in Claude's memory and `CONTRACT.md`, not in Codex's memory.
- The repo has no `AGENTS.md` and no `CLAUDE.md`, so no harness is told anything at startup.
- `cgnsa`'s four Claude worktrees are four unrelated projects under `~/.claude/projects`.
- Why `ColumnSort.swift` exists is spread over 5 transcripts, in two formats.

What the user asked for:
1. When an agent (Claude first) is working in a folder, the folder gets a dot, an unresolved
   issue. Flamingo offers to turn the folder into a code repo with the structure. The user can say no.
2. The structure is rigid: the same every single time. What is written inside (`AGENTS.md` and
   the rest) differs; the structure never does.
3. Agreed earlier the same day:
   - Files remember why. The reasoning agents already wrote is attached to the files it changed.
   - Sessions from every harness become chains.
   - One project memory that every agent reads.
   - Everything is keyed by identity, not path.

Not in this plan:
- A panel showing agents thinking. Agents already show that where they run.
- An MCP server.
- Agents writing thoughts.

## Privacy rule (changed 2026-10-18 for repo mode only; overrides everything below)

The user decided: "agents can read the thoughts under repo mode."

- **Repo mode.** Agents working in a structured project can read the thoughts on that project's
  files. Flamingo keeps a read-only copy of them in `scratch/thoughts/<path>.md`. That folder is
  inside `scratch/`, so git ignores it.
- **Nothing outside the project.** Thoughts on files outside the project, `_inbox`, `_web` and
  folder thoughts outside it are never copied. A project's copy holds only sidecars whose target
  is inside that project's root.
- **Not committed.** Thoughts never go into a tracked file. That rules out `AGENTS.md`,
  `HANDOVER.md`, plans and docs; memory imports are agent memories, not thoughts. The fixed
  `.gitignore` block lists `scratch/` and `.flamingo/`.
- **Copies, never links.** The copy is not a symlink, so an agent can't edit or delete your
  real thoughts. Edits to the copy are overwritten on the next sync.
- **Unchanged everywhere else.** Flamingo's own AI work on thoughts stays on this Mac:
  `LocalEndpoint`, `@ai`, the night shift, briefing ranking. Chat with a remote provider still
  drops thoughts. There is no `@claude`.
- **Agent logs stay on this Mac.** They are read, indexed and shown locally, and are not added
  to Ask's retrieval in this plan.
- **No prompts in `NOW.md`.** It carries no user prompts, so one harness never hands another
  provider what you typed to the first.

## 1. The structure, version 1

```
<project>/
├── AGENTS.md        how to work here; every agent reads it
├── CLAUDE.md        exactly one line: @AGENTS.md
├── README.md        what this is, for people
├── HANDOVER.md      where the work stands; the last session to stop updates it
├── .gitignore       Flamingo's block between fixed markers; your lines around it
├── plans/           NN-slug.md, one per piece of work
│   └── .gitkeep
├── docs/            everything else written about the project
│   └── .gitkeep
├── scratch/         ignored by git: agents' throwaway output, and Flamingo's two generated items
│   ├── NOW.md       written by Flamingo: who is working here and what they are changing
│   └── thoughts/    written by Flamingo: a read-only copy of the thoughts on this project's files
└── …                code and toolchain files, wherever the toolchain wants them
```

### Fixed
- **The tree.** Every name, its letter case and its place. Every structured project has every
  item above, all created at once.
- **`CLAUDE.md`** is exactly `@AGENTS.md` plus a newline. Claude Code reads `AGENTS.md`
  through the import; Codex and the others read `AGENTS.md` directly.
- **The `.gitignore` block:**
  ```
  # flamingo structure 1: do not edit between these lines
  scratch/
  .flamingo/
  .DS_Store
  # flamingo end
  ```
- **The skeleton of `AGENTS.md`:** these headings in this order, and the text of `## Structure`.
  ```
  # <Name>
  <!-- flamingo: {"project":"<UUID>","structure":1} -->

  <one line: what this is>

  ## Rules
  ## Commands
  ## Memory
  ## Structure
  <fixed text, identical in every project>
  ```
  Draft of the fixed `## Structure` text:
  - Read `scratch/NOW.md` first if it exists. It lists the sessions working here now and the
    files they are changing.
  - `scratch/thoughts/<path>.md` holds the thoughts people left on that file, and where in it.
    Read them before you change the file. They are a read-only copy.
  - Plans go in `plans/NN-slug.md`. Everything else you write about the project goes in `docs/`.
    Throwaway output (screenshots, logs, experiments) goes in `scratch/`.
  - Create no other files at the root, except what the toolchain needs.
  - Put what the next agent must know under `## Memory` in this file, not only in your own memory.
  - Before you stop, update `HANDOVER.md`.
- **What else may sit at the root.** This is a fixed allow-list:
  - toolchain manifests and their lock files (`Package.swift`, `package.json`, `Cargo.toml`,
    `pyproject.toml`, `go.mod`, `Makefile`, …);
  - dotfiles and dot-folders (`.git`, `.github`, `.claude`, `.vscode`, …);
  - `LICENSE*`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`;
  - any folder.

  Any other Markdown at the root breaks the structure.
- **`plans/`** holds only `NN-slug.md` files (two or more digits, kebab-case) and `.gitkeep`.
  It has no subfolders.

### Free
- The writing: every `AGENTS.md` section except `## Structure`, plus `README.md`, `HANDOVER.md`,
  plans and docs.
- Code layout. The structure never moves code or toolchain files: a Swift package keeps
  `Sources/`, and a Node app keeps `src/`.

### One source of truth
- **`ProjectStructure.v1`** (FlamingoCore) holds every name, every fixed byte and the allow-lists.
  The scaffolder, the checker, the `## Structure` text and the CONTRACT entry all come from it.
- **Versions.** A version 2 ships with a migration from version 1, and every project migrates the
  same way. No project is ever left between versions.
- **Golden test.** Scaffolding two different empty folders gives identical trees. Every fixed file
  is byte-identical. `AGENTS.md` differs only in the name line, the UUID and the one-line description.

## 2. Detection: is an agent working here?

`AgentPresence` lives in a new `FlamingoAgents` module, with one adapter per harness:

| Harness | Live signal | Log | Checked on this Mac |
|---|---|---|---|
| Claude Code (CLI and desktop) | A process named `claude`; its working folder from `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | `~/.claude/projects/<slug>/<session>.jsonl`. Every line carries `cwd`, `sessionId` and `gitBranch`; `ai-title` lines name the session | Yes. This session's `claude` process reports the repo as its working folder |
| Codex (desktop and CLI) | None: the app-server runs from `/` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, opening with a `session_meta` line that has `cwd` | Yes. 38 sessions have this repo as `cwd`, and the app-server's working folder is `/` |

- **What "working" means.** Either a live `claude` process whose working folder is inside the
  folder, or a session log for that folder written in the last 15 minutes.
- **Paths come from logs, never from slugs.** A slug turns both `/` and `.` into `-`, so it can't
  be turned back into a path. Always use the `cwd` in the log.
- **How often.**
  - Processes are scanned every 5 s while Flamingo is active and every 30 s otherwise. M0 measures
    one scan; the target is under 5 ms.
  - Logs come in through an FSEvents stream on the two log folders, reading only new bytes (one
    offset per file).
- **Never offered:**
  - Flamingo's own `claude -p`. `ClaudeCodeClient` runs in `$TMPDIR/flamingo-ask`, so children
    of Flamingo's pid are skipped.
  - Home, `/`, Desktop, Documents, Downloads, the iCloud Drive root and the vault root.
  - Anything under `~/Library` or `/private/tmp`.
  - Codex chat folders (`~/Documents/Codex/<date>/<chat>`).
  - A workspace folder: one with two or more git repos among its direct children (for example
    `~/claude`).

### Which folder is the project
- **Find the repo.** Walk up from the working folder to the nearest `.git`.
  - A `.git` folder makes that folder the project.
  - A `.git` file means a worktree. Follow `gitdir` to the main repo; the project is the main
    repo, and the worktree belongs to it.
  - With no `.git` before the vault root, the project is the working folder itself.
- **Structured folders are skipped.** A folder whose `AGENTS.md` carries the marker is already
  structured and is never offered again.

## 3. The dot and the offer

- **The dot.** It's the 6 pt squircle the radial ring uses for unseen edits, in
  `Theme.Color.textSecondary`, at the trailing edge of the folder's sidebar row and column cell.
  When the folder is collapsed out of view, the nearest visible ancestor carries it.
- **The unresolved issue.** One object appears in two places: a briefing item
  `.project(ProjectIssue)` drawn with `BriefingAttentionRow`, and a card in the folder's inspector.
- **Make Project sheet.** Clicking the dot, the briefing row or the card opens it.
  - The folder's name at the top, nothing else.
  - The tree as it will be, with every change marked: `+` new, `→` moved, `≈` merged (for
    example an existing `CLAUDE.md`'s text going into `AGENTS.md`).
  - What agents already know about this folder, ready to go into `## Memory`:
    - Claude's memory files for this path;
    - Codex memory entries whose `cwd` is this folder.

    Every entry is unticked by default, because `AGENTS.md` is committed and may be pushed.
  - Bare mentions of moved files that won't be rewritten (see §4).
  - **Make Project**, the one accent action, and **No**.
- **No.** It is remembered in `<vault>/.flamingo/projects.json`, keyed by the folder's
  `com.flamingo.id` and falling back to the path. The dot and the briefing item disappear and
  never return for that folder.
  - **Make Project…** stays in the folder's context menu (`FileMenu`).
  - Settings ▸ General gets "Offer to structure folders agents work in", on by default.
- **⌘N.** The New File sheet gets a **Project** kind (keywords `project, repo, code, git`). It
  creates a folder with the structure and runs `git init`, with no offer needed.

## 4. Conversion

The steps run in this order. Every write goes through `AtomicFile`, and nothing is overwritten.
1. **Git.** `git init` runs if there is no `.git` (folder or file). Flamingo never commits.
2. **Fixed items.** Create any that are missing.
3. **Existing instruction files.**
   - An existing `CLAUDE.md` with content: its text goes into `AGENTS.md` under `## Rules`,
     with its headings one level down. Then `CLAUDE.md` becomes `@AGENTS.md`.
   - An existing `AGENTS.md` is kept. Missing headings are added, and its other sections go
     under `## Rules`, one level down.
4. **Markdown at the root that isn't allow-listed.**
   - Files that look like plans (`PLAN*.md`, `plan-*.md`, `*-plan.md`) go to `plans/NN-slug.md`,
     numbered after the highest existing plan.
   - Everything else goes to `docs/`.
   - Existing `doc/` and `documentation/` folders are merged into `docs/`.
   - Badly named files in `plans/` are renamed to `NN-slug.md`.
5. **Links.** Markdown links and `[[wikilinks]]` inside the project that point at a moved file
   are rewritten. Bare mentions (such as "read CONTRACT.md") are listed in the sheet and left alone.
6. **Name collisions** get Finder's " 2" suffix.
7. **Marker.** Write the `AGENTS.md` marker with a new project UUID, then write `scratch/NOW.md`.
8. **Undo.** One `ActionHistory` entry, "Make Project", covers the whole conversion. Undo:
   - removes created items that are still unchanged;
   - moves files back;
   - restores the original `CLAUDE.md` and `AGENTS.md`;
   - removes `.git` only if Flamingo created it and it still has no commits.

   A toast lists anything undo couldn't restore.

This is the first time Flamingo writes into a person's folder outside its text editor and the
New File sheet. CONTRACT ("Flamingo never writes into your files", and "On-disk formats") needs
an exception. See decision 1.

## 5. Keeping it rigid

`StructureKeeper` watches each structured project: `VaultWatcher` events filtered to project
roots, plus a full check at launch and whenever an agent is detected there.

| Change | What Flamingo does |
|---|---|
| A fixed item is missing: a folder, a `.gitkeep`, `CLAUDE.md`, `README.md`, `HANDOVER.md`, `AGENTS.md`, `NOW.md` | Recreate it, with a toast that has Undo |
| `CLAUDE.md` holds more than `@AGENTS.md` (Claude Code's `/init` does this) | Move the extra text into `AGENTS.md` `## Memory` and restore `CLAUDE.md`. Words are never thrown away |
| The `.gitignore` block is missing or changed | Restore the block; lines outside it are untouched |
| `AGENTS.md` lost a heading, or its `## Structure` text changed | Restore them; other sections' content is untouched |
| New Markdown at the root, a badly named plan, a subfolder in `plans/` | Dot and issue, fixed with one click ("→ docs/NOTES.md", "→ plans/19-slug.md"). Never automatic: the agent that wrote it may still be using it |
| The marker was removed | The dot asks whether to restore the structure or leave it |

- **Wait for quiet.** Checks run 2 s after the last event in the project, so an agent mid-write
  isn't interrupted.
- **Own writes.** Flamingo's own writes are tagged, so their FSEvents don't trigger a check.
- **Loop guard.** If one item is restored 3 times in 10 minutes, the keeper stops restoring it
  and raises an issue: something is fighting the structure.

## 6. Sessions become chains

Each harness gets an `AgentLogReader`. It turns a log into one `AgentSession` and a list of
`AgentTouch`es:
- `AgentSession`: harness, id, `cwd`, project id, title, start, end, branch.
- `AgentTouch`: path, operation (read, created, edited, deleted, moved), time, line range when
  known, excerpt id.

Harness formats:
- **Claude Code.**
  - `tool_use` blocks named `Edit`, `Write`, `MultiEdit` and `NotebookEdit` give `file_path`.
    `Read` counts as a read.
  - `ai-title` gives the session title. The user turn before each edit gives the prompt.
  - Bash commands are kept as text and not parsed into files. One session here had 115 Bash
    calls, 54 Edits, 16 Reads and 4 Writes.
- **Codex.**
  - `apply_patch` text inside tool calls: `*** Add File:`, `*** Update File:`,
    `*** Delete File:`, `*** Move to:`. It appears in 19 of the 38 sessions in this repo.
  - `session_meta.cwd` gives the folder.
  - Titles come from `session_index.jsonl`; M0 confirms that's where they are.

Storage:
- **Index schema v10** adds `agent_sessions`, `agent_touches`, `agent_excerpts` and `log_offsets`.
  - Everything can be rebuilt from the logs, and only new bytes are read.
  - Lines that don't matter are skipped (`api-request*` and the like). The largest Claude log
    here is 13 MB.
- **Excerpts are capped:** the prompt of the turn, plus up to 1,500 characters of the agent's
  visible text before the edit. They are not put in FTS in this plan (the 2,000-segment lesson).

Where chains appear:
- **Trail.** Agent sessions appear as chains beside yours, with the harness name in `monoSmall`
  under the title. Resume opens their files in order. A session that spans worktrees is one chain
  under the project.
- **Graph.** Agent chains add `together` evidence through the existing trail edge rules
  (`cliqueLimit`, `maxEdgesPerFile`), so a 60-file refactor doesn't flood the graph.

## 7. Files remember why

- **The rail.** For a file in a project, the inspector's Connections tab gains one group: the
  agent sessions that changed this file, newest first.
  - Each row shows the session title, harness, time, the prompt line and the excerpt.
  - Click opens the edited lines in the text editor; ⌥-click opens the session's chain in Trail.
- **Line ranges.** Claude's `new_string`, or the Codex hunk, is located in the current file. If
  that text is gone, the row shows no lines.
- **Not thoughts.** Nothing here becomes a thought, and no sidecar is written. It's derived data
  and can be rebuilt.

## 8. One project memory

- **`AGENTS.md` is the memory.** `## Memory` is where agents put what the next one needs, and
  the `## Structure` text tells them so.
- **`scratch/NOW.md`** is written by Flamingo when something changes (debounced 2 s). It is
  ignored by git, so worktrees never conflict over it:
  ```
  # Now
  Written by Flamingo at 14:05. Read only.

  ## Working here
  - Claude Code · Column sort menu · since 13:40 · main · changing Sources/Flamingo/ColumnSort.swift, Sources/Flamingo/FileMenu.swift
  - Codex · Briefing rows · since 13:52 · worktree thoughts-v2 · changing Sources/Flamingo/BriefingRows.swift

  ## Open plans
  - plans/18-agent-projects.md · 3 of 9 ticked

  ## Recent chains
  - Yesterday 21:10 · Claude Code · Fast back/forward · SwipeNavigation.swift → History.swift → AppState.swift
  ```
- **Why `NOW.md` and not `AGENTS.md`.** Earlier, live chains were going into `AGENTS.md`. A
  committed file that changes every minute would conflict on every worktree merge, so live state
  lives here instead.
- **What it contains.** Paths, session titles, branch names and plan headings. Nothing else.
- **`scratch/thoughts/`.** It mirrors `<vault>/.flamingo/notes/<project path>/**` for sidecars
  whose target is inside the project, using the same relative paths and the same file text.
  - It syncs on sidecar change (debounced 2 s) and at launch.
  - It removes copies whose sidecar is gone.
  - Copies are written read-only (`0444`).

## 9. Identity

- **The project id is in git.** It lives in the `AGENTS.md` marker, so every worktree, clone and
  moved copy carries it.
- **`projects.json`** maps each id to its current root, its worktree roots and any old roots.
  Logs from all of those paths attach to the one project, including a moved folder's old Claude
  slug and each worktree's slug.
- **Files across worktrees.** A file inside a project is keyed by project id plus its path from
  the project root. The main checkout's `Sources/X.swift` and a worktree's are one file in the
  rail and the graph.
- **Worktrees inside a project are folded in.** The ones under `.claude/worktrees/` are not
  indexed as separate files.

## Status

- **M1 done (2026-10-18).** `ProjectStructure.swift` in FlamingoCore, 16 tests, and
  `flamingo-index <folder> --structure check|plan|apply`.
- **M2 done (2026-10-18).** The `FlamingoAgents` module: `AgentProcesses.Scanner`,
  `AgentLogs`, `ProjectResolver`, `AgentPresence` and `ProjectsStore`, 12 tests, and
  `flamingo-index <vault> --agents`.
  - **Process scan.** The first scan takes about 41 ms; repeats take 0.6 ms, because the scanner
    remembers each pid's executable.
  - **Executable path, not name.** A Claude Code native process's kernel name is its version
    (`2.1.302`), so detection matches the executable path
    (`~/.local/share/claude/versions/…`).
  - **On this Mac.** `--agents` on `~` finds this session live in `~/claude/flamingo` (37 ms)
    and offers the repo.
- **Next: M3**, the dot, briefing item, sheet, No and ⌘N kind. It touches files with uncommitted
  changes on `main`, so it needs main's current state first.

## Milestones

M1–M5 deliver what was asked today: the dot, the structure and keeping it rigid. M6–M8 deliver
what was agreed earlier.

- **M0 Pre-flight (needs your approval).**
  - Decisions below.
  - Measure one process scan, and confirm where Codex keeps session titles.
  - The `FlamingoAgents` target in `Package.swift`, and the CONTRACT update.
  - A branch `agent-projects` in its own worktree under the scratchpad, because other sessions
    edit `main`.
- **M1 Structure.**
  - `ProjectStructure.v1`, `ProjectScaffolder` and `ProjectChecker`, all pure, in FlamingoCore.
  - Golden tests.
  - `flamingo-index <folder> --structure check|plan|apply` for headless checks.
- **M2 Detection.** `AgentPresence`, the Claude Code and Codex adapters, project-folder
  resolution, the exclusions, `projects.json`.
- **M3 Offer.** The dot in the sidebar and columns, the briefing item, the inspector card, the
  Make Project sheet, No, the Settings toggle, and the ⌘N Project kind.
- **M4 Conversion and undo.**
- **M5 Keeper.**
- **M6 Logs into chains.** Schema v10, the readers, Trail, the graph.
- **M7 The rail's "why" group.**
- **M8 Memory and identity.** `NOW.md`, the `scratch/thoughts/` copy, memory import in the
  sheet, worktrees and moved folders.
- **M9 Docs and QA.** A README section, CONTRACT, HANDOVER, and a design review against DESIGN.md.

## Headless QA

- **A real live signal.** Copy `/bin/sleep` to a temp folder as `claude` and start it from inside
  a test folder. The process is named `claude` and its working folder is the test folder.
- **Fixture logs.** `fixtures/agents/` holds a trimmed Claude log and a trimmed Codex log with
  placeholder text, pointing at a temp project.
- **Golden.** Scaffold two folders and `diff -r` them, ignoring the three free `AGENTS.md` lines.
- **Keeper.** Delete `CLAUDE.md`, append text to it, edit the `.gitignore` block, and drop
  `NOTES.md` at the root. Each must give the outcome in the §5 table.
- **Undo.** Make Project on a folder that has a `CLAUDE.md` with content and a root `PLAN.md`,
  then ⌘Z. `diff -r` against a copy taken before must be empty.
- **Privacy.** Use two sentinel thoughts.
  - `SENTINEL-IN-7f3a` sits on a file inside a project. It must appear in
    `scratch/thoughts/` and nowhere that `git ls-files` lists.
  - `SENTINEL-OUT-7f3a` sits on a file outside every project. It must appear in no project.
- **Never this repo.** QA never converts the real Flamingo repo, only copies of it.
- **Offscreen.** UI checks run offscreen, because app windows catch the user's trackpad.

## Risks

- **Writing into people's folders** is new for Flamingo. It happens only after Make Project,
  never overwrites, undoes in one step, and the keeper never deletes words.
- **Harnesses that fight the structure.** One that insists on its own root file (`GEMINI.md`)
  gets flagged, not deleted, and the loop guard stops restore wars.
- **Log formats are private and change.** Claude's logs here use about 90 different keys.
  Readers ignore lines they don't know and fail closed: a log they can't read gives presence only.
- **Shell-made changes** (`sed`, `mv`, generators) can't be attributed to files. The rail says
  "and N shell commands" for that session.
- **Moving root Markdown breaks bare mentions.** In this repo "Read CONTRACT.md" appears in
  HANDOVER, plans and agent memories. The sheet lists them before anything moves.
- **The private room inside a repo vault.** If a repo is ever opened as its own vault, its
  `.flamingo/` holds every thought in that vault. The `.gitignore` block stops them being
  committed. In repo mode, agents reading them is allowed (decision 3). This doesn't apply
  today: the vault is `~`.

## Decisions

1. **Writing into folders (approved 2026-10-18).** In repo mode, Flamingo may write basic
   Markdown files, run `git init`, write the `.gitignore` block and write the `.gitkeep` files.
   CONTRACT gets that exception. The `FlamingoAgents` target and index schema v10 are approved
   with it.
2. **Private room in a repo vault (dropped).** The vault is `~`, so thoughts live in
   `~/.flamingo`, outside every repo. The `.flamingo/` line in the `.gitignore` block stays as a
   guard in case a repo is ever opened as its own vault.
3. **Agents may read thoughts in repo mode (2026-10-18).** This is scoped to the project's own
   files, through `scratch/thoughts/`. See the privacy rule at the top.

### Critical files for implementation
- Sources/FlamingoCore/ProjectStructure.swift (new), with ActionHistory.swift and AtomicFile.swift
- Sources/FlamingoAgents/ (new): AgentPresence, ClaudeCodeLog, CodexLog, StructureKeeper, ProjectNow
- Sources/FlamingoIndex/IndexStore.swift (schemaVersion 9 → 10) and VaultWatcher.swift
- Sources/FlamingoTrail/Trail.swift (agent sessions beside `TrailSession`)
- Sources/Flamingo/SidebarRow.swift, ColumnBrowser.swift, BriefingWorkflow.swift, BriefingRows.swift,
  ConnectionsTab.swift, NewFileSheet.swift, FileMenu.swift, SettingsWindow.swift
- Sources/FlamingoCore/DocumentFactory.swift (the Project kind)
- CONTRACT.md, Package.swift
