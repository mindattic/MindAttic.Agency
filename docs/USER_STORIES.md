---
codex: 1
project: MindAttic.Agency
code: MAT
layer: stories
status: living
updated: 2026-10-18
---
<!-- GENERATED from MindAttic.Tickets/data/Tickets.db by `tickets db render`. Do not edit: this file is rewritten from the database; change stories and tickets with the tickets CLI. -->

# MindAttic.Agency — User Stories
> ✅ done (shipped & tested) · 🟡 partial · ⬜ planned. Every ✅ cites the test.

## Priority backlog
_Nothing recorded yet._

## Tickets
> Permanent log of every change and fix — this repo's ticket system. Rows are append-only: never
> delete or reword one; only move its Status (open → closed / wont-do) and fill in Ref. Status is
> a word, not a glyph, so tickets don't count toward the story index. Keep this section last.

| ID | Date | Type | Status | Summary | Ref |
|---|---|---|---|---|---|
| MAT-T1 | 2026-10-18 | docs | closed | Start the permanent ticket log in the workflow database | — |
| MAT-T2 | 2026-10-18 | chore | closed | Shared global commands get their portable pointers here (from install.ps1), so any LLM client finds them | — |
| MAT-T3 | 2026-10-18 | chore | closed | Regenerate mindattic-agent-standard/command-catalog.json to reflect current repo/command state | — |
| MAT-T4 | 2026-10-18 | docs | closed | Rewrite HOUSE-LAW-11 in MindAttic.HouseRules.md: MindAttic.WatchDog is the only thing that registers Windows Scheduled Tasks; apps never call Register-ScheduledTask/schtasks themselves but declare a job in WatchDog's jobs.json, or, for tasks made at runtime (Psst reminders), call WatchDog's job API (M.WD-T12); every task lives under \MindAttic\WatchDog\, and an app's old self-registered task is removed when its job moves (M.WD-T4..T11) | MindAttic.HouseRules.md (f4246d2) |
| MAT-T5 | 2026-10-19 | docs | open | HOUSE-LAW-12: every published Claude artifact also gets a same-content file in its repo's artifacts/ (or workspace-root artifacts/ when no project owns it), named after the artifact's title; backfill the one orphaned artifact at workspace root | — |
| MAT-T6 | 2026-10-19 | chore | open | Convert tracked source files to LF line endings via .gitattributes, per HOUSE-LAW-13 (low priority) | — |
| MAT-T7 | 2026-10-20 | chore | closed | Bootstrap UnityCursory and MindAttic.Unity.Multiplayer: create both public GitHub repos, clone via clone-repo.ps1 (wip tag), roll out workflow codes, install commit hooks, add AGENTS.md/CLAUDE.md forwarders, and file the chained build tickets (plan toasty-beaming-locket) | — |
| MAT-T8 | 2026-10-20 | feature | closed | Shared DocFX -> GitHub Pages docs pipeline: reusable workflow (.github/workflows/docs-pages.yml), DocFX template porting the codex README.htm dark theme/sidebar TOC/copy buttons, docfx.json template (README.md as home page, docs/*.md articles minus USER_STORIES/AMENDMENTS/BIBLE.digest, optional API reference), shared/docs-site/adopt-docs-site.ps1 rollout script, and HOUSE-LAW-14 (every repo publishes its docs via GitHub Pages) | MindAttic.Toolkit@2f38831,c67cd2f; root@41b9560,24436dc |
| MAT-T9 | 2026-10-20 | docs | open | Publish MindAttic.Toolkit docs to GitHub Pages via the shared Toolkit DocFX pipeline: run adopt-docs-site.ps1 (README.md as home page, docs/*.md as articles, API reference only where the code builds in CI), enable Pages with build_type=workflow, set the repo homepage URL, retire tools/build-readme.ps1 and README.htm, confirm the docs Actions run is green and https://mindattic.github.io/MindAttic.Toolkit/ returns 200. Depends on MAT-T8. (This is Toolkit's own docs site, separate from building the shared pipeline.) | — |
| MAT-T10 | 2026-10-20 | chore | wont-do | Archive the private codex-standard repo (build-readme.ps1 README.htm engine) once no repo calls it any more, after the DocFX/GitHub Pages rollout (MAT-T8 and the per-repo docs tickets) lands everywhere. | superseded: codex-standard is the workspace-root repo, not just the engine |
| MAT-T11 | 2026-10-20 | chore | open | Delete the retired codex-standard/ README.htm engine folder (build-readme.ps1, build-readme.wrapper.ps1) from the workspace-root repo once no repo's tools/ calls it any more, after the per-repo HOUSE-LAW-14 docs tickets land (depends on MAT-T8). | — |
| MAT-T12 | 2026-10-20 | feature | closed | Docs sites carry the MindAttic brand from mindattic.com: the Attic M logo and favicon (white in dark mode, black in light), the repo name set in Attic, Outfit body text, mindattic.com's dark palette, and #FF0033 red in place of the blue accents | MindAttic.Toolkit@78c70a7,ea0f94e |
| MAT-T13 | 2026-10-20 | feature | closed | Global /progress shows what every running subagent is doing and an estimated percent done: mindattic-agent-standard/agent-progress.ps1 reads Claude Code subagent transcripts (~/.claude/projects/*/*/subagents/agent-*.jsonl) and reports per agent its ticket, worktree, current action, elapsed time, tool calls, worktree diff/commits and a milestone-based percent (explore -> edit -> test -> commit -> push -> ticket closed); ~/.claude/commands/progress.md invokes it; prose-agent.ps1 progress routes to it outside Prose (Prose keeps its strand dashboard) | e1ad5ab |
| MAT-T14 | 2026-10-20 | fix | closed | Docs sites show a second scrollbar on the In this article outline (DocFX makes it a sticky, height-capped box); it should print its full length down the side and scroll only with the browser | MindAttic.Toolkit@579f636 |
| MAT-T15 | 2026-10-20 | fix | closed | /progress showed a finished subagent as stalled when Claude Code saved its final reply without stop_reason end_turn (seen on M.COMP-T33); a closing text reply with nothing after it for a minute now counts as finished | 9cfbf2d |
| MAT-T16 | 2026-10-20 | fix | open | /progress (mindattic-agent-standard/agent-progress.ps1) still shows a finished ticket agent as 'stalled?' at 99%: on 2026-10-20 M.COMP-T33 had landed (25ab445), published 17.0.0 and run 'workflow ticket close' 1h40m earlier, yet the report showed 'phase: closing, now: Verify tickets for the repo [stalled?]' because its last tool call was a 'workflow ticket verify' after the close (MAT-T15 only covered a final reply without stop_reason end_turn). An agent whose transcript shows its ticket closed, or that ended with a final report, is done at 100% whatever read-only command came after; only an agent still mid-milestone counts as stalled. Add a test transcript for close-then-verify | — |
| MAT-T17 | 2026-10-20 | feature | closed | Docs sites get a Back to Top button in the lower right, shown once the page scrolls past the end of the In this article outline (one screen down where the outline is hidden), styled like mindattic.com's buttons | MindAttic.Toolkit@f45ccff |
| MAT-T18 | 2026-10-20 | feature | closed | Docs site headings (h1-h6, table headers, the In this article label) are set at normal weight, never bold | MindAttic.Toolkit@f969929 |
| MAT-T19 | 2026-10-20 | feature | closed | Outfit is the base font of the docs sites: Bootstrap's font variables are set to Outfit so nav, search, buttons and every other element inherit it (code stays monospace, the wordmark stays Attic) | MindAttic.Toolkit@8f59728 |
| MAT-T20 | 2026-10-20 | feature | closed | The docs sites' Back to Top button is a rounded square with a centered equilateral triangle instead of the words Back to Top (aria-label and tooltip keep the name) | MindAttic.Toolkit@7453331 |
| MAT-T21 | 2026-10-20 | chore | closed | Rename MindAttic.Toolkit to MindAttic.Agency (GitHub repo, local folder, cross-repo references) | — |
| MAT-T22 | 2026-10-20 | chore | closed | Regenerate docs/workspace-repos.json and mindattic-agent-standard/command-catalog.json after the Unity Fleet Rename (5 repo folder renames) | orchestrator workspace export; export-catalog.ps1 |
| MAT-T23 | 2026-10-20 | chore | closed | Add HOUSE-LAW-15: don't wait on a full test suite to land a change, per M.ORCH-T561's background daemon | MindAttic.HouseRules.md HOUSE-LAW-15 |
| MAT-T24 | 2026-10-20 | chore | closed | Regenerate docs/workspace-repos.json and mindattic-agent-standard/command-catalog.json after the MindAttic.Unity.Shared -> Unity.Shared rename landed on disk (MAU-T6) | orchestrator workspace export; export-catalog.ps1 |
| MAT-T25 | 2026-10-20 | chore | open | Bug hunt: run an exhaustive /bughunt over the whole repo and fix every real bug found (each fix under its own fix ticket), then hunt again; close this only when a full pass finds nothing | user request 2026-10-20: approved repo sweep gap-fill |
| MAT-T26 | 2026-10-20 | chore | open | Nightly readiness sweep (user-requested 2026-10-20): for every repo in docs/workspace-repos.json verify it builds, its tests run, its deploy path (deploy.ps1 / MindAttic.Deploy) works, it is tagged wip and launches from MindAttic.Launcher, and that recent renames (Workflow->Tickets, Toolkit->Agency, WatchDog->Scheduler, Unity.* fleet) left no stale references; file a fix ticket per failure | — |
| MAT-T27 | 2026-10-21 | docs | closed | Update USER_STORIES.md | — |
