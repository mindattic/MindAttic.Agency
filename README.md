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

`/quicksave`, `/quickload`, `/do`, `/commit`, `/deploy` are also real global commands at
`~/.claude/commands/` — present for every repo on Day 1, with no per-project `.claude/commands`
copy and no `install.ps1` run required. `install.ps1` still projects provider-neutral pointers
(`.prose/commands/*.md`) for non-Claude clients, mirroring whatever it finds in that global
folder.
