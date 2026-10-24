# MindAttic Agent Standard

This directory is the single implementation home for provider-neutral agent behavior shared by
every repository under `D:\Projects\MindAttic`. Project-local `AGENTS.md` files and `.prose`
command definitions are discovery pointers only. They must not contain another copy of the
workflow.

Install or refresh the thin pointers for all sibling repositories from the workspace root:

```powershell
powershell -File mindattic-agent-standard/install.ps1
```

The runner accepts `bootstrap`, `save`, `load`, `do`, `progress`, `show`, and `queue`. Project-specific
commands remain in the project repository's catalog, while common lifecycle commands live here.

`/quicksave`, `/quickload`, `/do`, `/commit`, `/deploy`, `/progress` are also real global commands at
`~/.claude/commands/` — present for every repo on Day 1, with no per-project `.claude/commands`
copy and no `install.ps1` run required. `install.ps1` still projects provider-neutral pointers
(`.prose/commands/*.md`) for non-Claude clients, mirroring whatever it finds in that global
folder.

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
