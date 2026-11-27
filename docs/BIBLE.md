---
layer: bible
status: living
---
# MindAttic.Agency — Project Bible

> Single source of truth for what MindAttic.Agency IS, is NOT, and the rules that keep it coherent.
> README says how to install it; this says how to think about it. The finish line lives in
> `docs/RELEASE.md`.

## 1. The one sentence {#MAT-§1}
MindAttic.Agency is the one canonical copy of the MindAttic Agent Standard: the provider-neutral rules, abilities,
hooks, roles and scripts every MindAttic repo and every agent CLI follows.

## 2. The product promise {#MAT-§2}
- Any CLI (Claude Code, OpenAI Codex, Kimi Code, Google Antigravity/agy, a local model) that opens any MindAttic repo
  finds the same rules and the same commands, with no per-repo copy and no setup per repo.
- A rule or command is written once, here, and rendered out to each CLI's own extension point.
- Where a mechanism has no equivalent on another CLI, the standard says so plainly instead of faking parity
  (`docs/claude-only-abilities.md`, `docs/hook-contract-matrix.md`).

## 3. What it is NOT {#MAT-§3}
- Not an app. It ships no UI; the Orchestrator, Tickets and Launcher are their own repos.
- Not the home of per-repo workflow. Project `AGENTS.md` files are thin pointers and may add only project context.
- Not the mirror. `D:\Projects\MindAttic\mindattic-agent-standard\` is a legacy copy kept in sync from here
  (MAT-T50); edits made only in the mirror are drift.
- Not a hosting or infrastructure project (Azure is decommissioned, MAT-T297).

## 4. Architecture canon {#MAT-§4}
```
 shared/abilities/*.md  --render-abilities.ps1-->  shared/commands/*.md -> ~/.claude/commands
   (source of truth)                          \->  Codex skills, Kimi skills, agy skills,
                                                   shared/codex-command-catalog.md
 shared/hooks/*  --install-hooks.ps1-->  Claude settings.json, Codex hooks.json, Kimi config.toml, agy hooks.json
 shared/hooks/commit-msg --install-commit-hooks.ps1--> every repo's .git/hooks
 AGENTS.md + shared/** --sync-workspace-copy.ps1--> D:\Projects\MindAttic\mindattic-agent-standard\ (mirror)
 install.ps1 --> thin AGENTS.md / .agent/commands pointers in every sibling repo
```
### 4.1 Modules
- `AGENTS.md` — the shared rules every agent reads after the workspace `MINDATTIC_AGENT.md`.
- `shared/abilities/` — one Markdown file per command (`/allocate`, `/commit`, `/deploy`, `/flush`, `/poll`,
  `/publish`, `/quicksave`, `/test` and the rest; 33 today). `shared/commands/` is a render target, never edited.
- `shared/hooks/` — `test-gate.py`, `commit-gate.py`, `commit-msg`, `pace-gate.py`, `context-gate.py`,
  `rl-check.py`, `log-user-input.ps1`, `quickload-on-do.ps1`.
- `shared/roles/` — subagent role definitions (analyst, architect, implementer, planner, reviewer, ...).
- `shared/deploy-lib.ps1`, `shared/publish-app.ps1`, `shared/templates/run.ps1` — the one deploy mechanism:
  Debug and Release to `R:\MindAttic\Apps\<repo>\`, the 3-option run menu, `run.bat` from `Write-RunBat`.
- `shared/docs-site/` and `.github/workflows/docs-pages.yml` — the GitHub Pages docs pipeline (HOUSE-LAW-14).
- `prose-agent.ps1` — the portable runner (`save`, `load`, `do`, `progress`, `show`, `queue`, `quicksaves`, `alias`).
- `clone-repo.ps1`, `install*.ps1`, `share-scripts.ps1`, `render-abilities.ps1`, `export-catalog.ps1`,
  `sync-workspace-copy.ps1`, `schedule-wakeup.ps1`, `agent-progress.ps1`, `broadcast-ticket-done.ps1`.
- `tests/` — Pester tests for the runner, progress, commit-msg and test gate (run only on the owner's `/test`).

### 4.2 Domain model
Ability, command (rendered ability), hook, role, handoff (quicksave code), ticket, run menu, mirror.

### 4.3 Key services
Render abilities; install hooks; install pointers; sync the mirror; save and load handoffs; publish an app.

## 5. The Laws {#MAT-§5}
Inherits `MindAttic.HouseRules.md` by reference.
1. {#MAT-LAW-1} This repo is the source; the mirror is a copy. Change it here, then sync.
2. {#MAT-LAW-2} Abilities are written once in `shared/abilities/`; never hand-edit a rendered command or copy a
   command body into a provider-specific or per-project folder.
3. {#MAT-LAW-3} Verification is build-only; tests run once, when the owner asks (`/test`).
4. {#MAT-LAW-4} One ticket per commit, committed by path, on `main`, no branches or worktrees.
5. {#MAT-LAW-5} A claim about another CLI's behaviour is confirmed empirically before it is written down.
6. {#MAT-LAW-6} Hooks fail open: an error in a gate allows the call.

## 6. Verified state {#MAT-§6}
- Cross-CLI rendering to Claude, Codex, Kimi and agy (MAT-T93..T98).
- Test gate (MAT-T121) and commit gate (M.ORCH-T1530) installed by `install-hooks.ps1`.
- Shared deploy library and run menu (cd2ae0a, b590b0f, 5d6a413, 5003055, 280f3ed, e15f055).
- Known gap: on 2026-11-27 `sync-workspace-copy.ps1 -Check` listed 23 drifted files (epic "One coherent source").

## 7. Active frontier {#MAT-§7}
See `docs/RELEASE.md`: milestone MS-20 and its epics.

## 8. Quality bar {#MAT-§8}
A change is done when the ability is re-rendered (`render-abilities.ps1`), the catalog re-exported
(`export-catalog.ps1`) if commands changed, the mirror synced, `AGENTS.md` says what the code does, and the
commit names one ticket.

## 9. Glossary {#MAT-§9}
- **Mirror** — `D:\Projects\MindAttic\mindattic-agent-standard\`, the workspace-root copy of this repo.
- **Ability** — the source Markdown for a command, rendered per CLI.
- **Handoff** — a `/quicksave` record with a shareable adjective-animal code.
- **Run menu** — the 3-option `run.ps1` (Redeploy, Run Debug, Run Release) every app gets from the template.
