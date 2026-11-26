---
description: Deploy the current project using whatever deploy mechanism it actually has.
argument-hint: "[debug|release|dry run, or flags to pass through to the project's own run.ps1]"
allowed-tools: Read, Bash, PowerShell
---

Global MindAttic command. There is no single deploy mechanism across the workspace - this command
is a router, not a shared implementation: it figures out which mechanism *this* repo actually uses
and defers to it. Never invent deploy steps that aren't backed by one of the cases below.

## 1. A project-owned `run.ps1`

If the current repo root (or its `tools/` folder) has a `run.ps1`, that is authoritative (it was
named `deploy.ps1` before 2026-10-27; treat an old `deploy.ps1` the same way). Never run the
generated `run.bat` launcher, and never run `run.ps1` with no switch on a repo that uses the shared
menu: both open a numbered menu and wait for a keypress. Do not second-guess what the script does.

**a. It uses the shared run menu** (its `param()` declares `-Redeploy`, or it dot-sources
`MindAttic.Agency\shared\deploy-lib.ps1` and calls `Invoke-AppRun`; MAT-T278). Call it with a switch:

- `/deploy` alone: `powershell -NoProfile -ExecutionPolicy Bypass -File run.ps1 -Redeploy`. It builds
  and deploys both Debug and Release to `R:\MindAttic\Apps\<repo>\{Debug,Release}`.
- When the user asks to run it too, add `-RunDebug` (the dev/test copy) and/or `-RunRelease` (the
  standalone copy a player double-clicks). They combine with `-Redeploy`, which always goes first;
  asked only to run (no deploy), pass just `-RunDebug` or `-RunRelease`. Anything after the switches
  passes through to the app.
- When the user asks what it would do, add `-DryRun` if the `run.ps1` declares it: it prints each
  build and launch and does neither. If it doesn't, say so rather than deploying.
- `$ARGUMENTS` that are already switches (`-Redeploy`, `-RunDebug`, `-RunRelease`, `-DryRun`) pass
  through as given; words map to them (`debug` -> `-RunDebug`, `release` -> `-RunRelease`,
  `dry run` -> `-DryRun`).

**b. Not migrated yet** (an older, project-specific `run.ps1`/`deploy.ps1` with no `-Redeploy`).
Run it non-interactively with PowerShell (passing `$ARGUMENTS` through as its own flags) and report
its output.

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
