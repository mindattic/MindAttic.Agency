---
layer: release
status: living
---
# MindAttic.Agency — Release charter

> The one finish line this repo is working toward. Every open ticket in this repo sits under one of the epics
> below, and every epic is part of the milestone. Work that does not fit is out of scope until this milestone is
> reached (owner, 2026-11-27, MAT-T319).

## 1. What this is
The MindAttic Agent Standard: the provider-neutral rules (`AGENTS.md`), abilities, hooks, roles, runner and shared
scripts that every MindAttic repo and every CLI (Claude, Codex, Kimi, agy) uses, plus the home for org-wide tickets
of the workspace root.

## 2. The milestone: MindAttic.Agency 1.0 — a finished, coherent standard {#milestone}
- **Milestone:** MS-20, "Agent standard 1.0: one coherent source"
- **Published means:** an internal tool. This repo is the source; `sync-workspace-copy.ps1` copies it onto the
  workspace-root mirror `D:\Projects\MindAttic\mindattic-agent-standard\`, and `install.ps1`/`share-scripts.ps1`/
  `render-abilities.ps1`/`install-hooks.ps1` put it into every CLI's own extension points. The docs site is
  `https://mindattic.github.io/MindAttic.Agency/`.
- **The natural stopping point:** Agency and the mirror are byte-identical (no mirror-only edits left to port),
  the rules in `AGENTS.md` match what the Orchestrator, hooks and scripts actually do, the known commit and hook
  bugs are fixed, dead Azure tooling is gone, and the shared deploy (`deploy-lib.ps1`, the 3-option `run.ps1`
  menu, `R:\MindAttic\Apps`) is the one way apps deploy. After that the standard only changes when a real rule
  changes; it stops generating work of its own.

## 3. Done when (acceptance checks)
1. harness — `sync-workspace-copy.ps1 -Check` reports no drift between Agency and the workspace-root mirror.
2. exists — `docs/RELEASE.md` and `docs/BIBLE.md` describe the standard; `README.md` lists every script.
3. harness — `publish-app.ps1 -All -DryRun` targets `R:\MindAttic\Apps` for every app-kind repo.
4. signoff — the owner starts a CLI in any repo and the rules, commands and hooks it gets are the ones in
   `AGENTS.md`.

## 4. Epics, in priority order
| Priority | Epic (ticket) | What it delivers | Features |
|---|---|---|---|
| 900 | MAT-T332 One coherent source | Agency and mirror identical; docs match behaviour; Azure tooling and retired folders gone | MAT-T334 Mirror reconciliation (990), MAT-T335 Rules match behaviour (980), MAT-T336 Retire Azure tooling (970), MAT-T337 Workspace root cleanup (960) |
| 800 | MAT-T333 Commit and hook safety | Shared-checkout commits can't swap messages; gate, allocate and login hooks behave | MAT-T338 Commit integrity (890), MAT-T339 Hook and command fixes (880) |
| 700 | MAT-T256 Unify app deploys on R: | Every app-kind repo deploys through `deploy-lib.ps1` and the shared run menu to `R:\MindAttic\Apps` | MAT-T260 Per-repo deploy rollout (790), MAT-T261 C: deploy cleanup (780) |

## 5. Out of scope (not before this milestone)
- Hosting moves (Hetzner, Azure): Azure is decommissioned (2026-11-26, MAT-T297) and apps use local SQL; no
  server move is planned.
- New repos and new apps filed here (Unreal.Space, Mods.Mech5Mercs.CoopPartner, a systems-of-record dashboard,
  MindAttic.Relay): each belongs to its own repo and charter if it ever starts.
- Claude Team SSO and login-rebalance policy: Orchestrator concerns, not the standard.
- Open-ended sweeps (exhaustive bughunts, RAM hunts, test runs nobody asked for) and one-off operational chores
  (reopen crashed CLIs, trigger docs rebuilds, desktop shortcuts).
- New commands that fight a standing rule (`/commit all` breaks one ticket per commit).

## 6. Current verified state
- Abilities are written once in `shared/abilities/` and rendered to Claude, Codex, Kimi and agy
  (`render-abilities.ps1`, MAT-T93..T98); 33 abilities including `/poll` (3877158), `/flush` and `/allocate`.
- Hooks: test gate (MAT-T121), commit gate (M.ORCH-T1530), pace and context gates, wired by `install-hooks.ps1`.
- Shared deploy: `shared/deploy-lib.ps1` with Publish-DotNet/Unity/Unreal/Script and the `Invoke-AppRun` menu
  (cd2ae0a, b590b0f, 5003055, 280f3ed, e15f055); `publish-app.ps1` is its thin caller (5d6a413).
- HOUSE-LAW-12 artifacts rule (26ff586), the epic-tree golden rule (1817ea4) and the run.ps1 launcher section of
  AGENTS.md (6c0714c) are in place.
- Drift: on 2026-11-27 `sync-workspace-copy.ps1 -Check` listed 23 files that differ between Agency and the mirror.

## 7. Decision record
- 2026-11-27 — charter drafted from README/AGENTS.md/docs/git log/tickets; Legion vote: Approve, 9 of 9 voters (plurality quorum reached, consensus 1.0); no dissent.
- Triage: 84 open (excluding the portfolio-reset tree MAT-T319..T330) → done 7, duplicate 1, wont-do 50, kept 23 (plus 3 new tasks MAT-T340..T342). MAT-T221, MAT-T246 and MAT-T247 (Azure to Hetzner) stay open only because they still hold Azure-move child tickets in other repos (FOR-T36, GAD-T784, IP-T649, OC-T47, PRS-T1126, TRC-T66, TT-T67, M.SCHD-T57, PRS-T1129); close them once those repos wont-do their children. The MAT-T256 deploy epic likewise carries per-repo child tasks that each repo schedules under its own charter.
