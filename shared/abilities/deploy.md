---
name: deploy
description: Deploy the current project using whatever deploy mechanism it actually has.
argument-hint: "[optional flags to pass through to the project's own deploy script]"
claude-only: false
claude-allowed-tools: Read, Bash, PowerShell
---
Global MindAttic command. There is no single deploy mechanism across the workspace - this command
is a router, not a shared implementation: it figures out which mechanism *this* repo actually uses
and defers to it. Never invent deploy steps that aren't backed by one of the cases below.

## 1. A project-owned `run.ps1`

If the current repo root (or its `tools/` folder) has a `run.ps1`, that is authoritative (it was
named `deploy.ps1` before 2026-10-27; treat an old `deploy.ps1` the same way). Run it
non-interactively with PowerShell (passing `$ARGUMENTS` through as its own flags) and report its
output. Never run the generated `run.bat` launcher: it opens a Deploy & Run / Run menu and waits for
a keypress. Do not second-guess what the script does.

## 2. Routed through MindAttic.Deploy

Else, look for `..\MindAttic.Deploy\projects.json` (walk up to the workspace root first, same as
`/quicksave`, if `..` isn't it directly). If this repo's name appears in its `projects[]`, `sites[]`
or `apps[]` arrays, deploy through MindAttic.Deploy's own CLI/npm entry point for that entry - read
MindAttic.Deploy's README for the current invocation (e.g. `npm run deploy -- --only <slug>`)
rather than guessing the flag shape, and report its output.

## 3. Neither applies

Tell the user plainly that this repo has no automated deploy configured - name what you checked
(no `run.ps1`, not listed in MindAttic.Deploy's `projects.json`) - and stop. Do not fabricate a
deploy path. If the repo's own `AGENTS.md`/`README.md` documents a manual publish step (e.g. "edit
README.md and push to main" for a README-as-product repo), relay that instead of just saying no.

## Always

- Never force-push, skip hooks, or bypass a failing build to "just get it deployed."
- Surface whatever the underlying script/CLI prints - don't summarize away a failure.
- If credentials are missing (FTP, Azure, NuGet feed), say which ones rather than retrying blindly.
