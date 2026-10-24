# MindAttic Agent Standard

This directory is the single implementation home for provider-neutral agent behavior shared by
every repository under `D:\Projects\MindAttic`. Project-local `AGENTS.md` files and `.agent`
command definitions are discovery pointers only. They must not contain another copy of the
workflow.

Install or refresh the thin pointers for all sibling repositories from the workspace root:

```powershell
powershell -File mindattic-agent-standard/install.ps1
```

The runner accepts `bootstrap`, `save`, `load`, `do`, `progress`, `show`, `queue`, and `handoffs`. Project-specific
commands remain in the project repository's catalog, while common lifecycle commands live here.

`/quicksave`, `/quickload`, `/do`, `/commit`, `/deploy`, `/progress` are also real global commands at
`~/.claude/commands/` — present for every repo on Day 1, with no per-project `.claude/commands`
copy and no `install.ps1` run required. `install.ps1` still projects provider-neutral pointers
(`.agent/commands/*.md`) for non-Claude clients, mirroring whatever it finds in that global
folder.

Each repo's `.agent/` folder also holds the runner's portable handoff (`agent-session.json`) and
bookmark queue (`agent-queue.json`), both git-ignored. The folder was `.prose/` until MAT-T39 (the
name read as the separate Prose product); the runner moves an old `.prose/` handoff and queue across
on first use, and `install.ps1` moves the command pointers and rewrites `.gitignore` entries.

Every `save` also picks a shareable handoff code, an adjective-animal pair from
`shared/handoff-words/` (e.g. `lively-oxen`), regenerated on collision with any unconsumed code, and
records the handoff (repo/worktree and branch, login, task, decisions, state, next, queue) in the
machine-wide registry `%LOCALAPPDATA%\MindAttic\handoffs\<code>.json` (override: `-RegistryRoot` or
`MINDATTIC_HANDOFF_REGISTRY`). Every login on the machine shares it, so `load <code>`
(`/quickload <code>`) restores that exact handoff from any login's CLI in any folder; loading
consumes the code (archived under `consumed\`, never deleted) and frees it for reuse. `handoffs`
lists the unconsumed codes. The global `/quicksave` and `/quickload` definitions live in
`shared/commands/`; `share-scripts.ps1` (run by `install.ps1`) installs them into
`~/.claude/commands/`.

## Docs site pipeline (HOUSE-LAW-14)

Every MindAttic repo publishes its docs to `https://mindattic.github.io/<Repo>/` through the one
pipeline here:

- `shared/docs-site/build-docs-site.ps1` stages README.md (as the home page) and `docs/**/*.md`,
  rewrites links, generates `toc.yml`/`docfx.json`, and runs DocFX (`-Build`, or `-Serve` to preview).
- `shared/docs-site/template/` is the MindAttic look (the old codex README.htm theme) on top of
  DocFX's `modern` template.
- `.github/workflows/docs-pages.yml` is the reusable workflow that builds and deploys to Pages.
- `shared/docs-site/adopt-docs-site.ps1 -Repo <name> [-Api]` opts a repo in: it writes the thin
  `.github/workflows/docs.yml` caller, retires `README.htm`/`tools/build-readme.*`, and turns
  Pages on.

## This repo is the one canonical copy (MAT-T50)

`D:\Projects\MindAttic\mindattic-agent-standard\` is a legacy mirror left over from before this
standard was pulled into its own repo (`MindAttic.Agency`). Left alone, the two drift in both
directions — MAT-T26's readiness sweep found fixes that had landed in only one side or the other
(MAT-T50). This repo is the source of truth: `sync-workspace-copy.ps1 -Check` (run from the
workspace's `MindAttic.Agency` checkout) reports any file that differs from or is missing under the
mirror, and the same script without `-Check` copies this repo's files onto it. `share-scripts.ps1`
runs the `-Check` pass (report-only) on every install.
