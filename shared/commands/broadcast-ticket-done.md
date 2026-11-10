---
description: After closing a ticket, tell every other live CLI (Claude, Codex, Kimi, agy - any product, any login) that it closed, so one whose own open ticket required it as a prerequisite finds out without having to poll (MAT-T105).
argument-hint: "-TicketId <ID> -Summary \\"<one line: what changed>\\""
allowed-tools: PowerShell, Bash
---

Run this right after `tickets ticket close <ID>`, for every ticket you close - not just
Unity.Rea.* ones. It rides entirely on infrastructure that already exists:

- MindAttic.Orchestrator's own `CliNudges` (`Sessions/CliNudges.cs`, M.ORCH-T864) already proved the
  pattern: drop a `nudge-<pid>-<kind>.txt` file in the shared session-context directory
  (`~/.claude/session-context` - a shared machine-wide location despite the name) and
  `shared/hooks/context-gate.py`'s `take_nudges()` folds it into that pid's next turn as hook
  context, never typed into its input box.
- `take_nudges()` keys purely on the CLI process's own pid (`MINDATTIC_CLI_PID` or the OS pid) - it
  has no per-product branch. Since `install-hooks.ps1` (MAT-T94) already points Claude's, Codex's,
  Kimi's and agy's hooks at this one shared `context-gate.py`, a nudge reaches whichever of those
  four products happens to own that pid, automatically - no new per-CLI code needed here.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "MindAttic.Agency\broadcast-ticket-done.ps1" `
  -TicketId <ID> -Summary "<one line: what's now true>" -ExcludePid <your own pid, if known>
```

What it does: scans every `*.state.json` under the shared session-context directory (one per CLI
turn that has ever run `context-gate.py`, any product, any login), keeps the ones whose pid still
answers (a live `Get-Process`), and leaves each a `nudge-<pid>-ticket-done.txt` reading
`Ticket <ID> closed: <Summary> Check your repo's queue (tickets ticket queue) - a prerequisite may
now be clear.`

**Named limits, not assumed away:**
- A nudge goes stale after 20 minutes if that CLI's hook never fires in that window
  (`context-gate.py`'s own `take_nudges()` constant, unmodified by this ability) - a CLI idle longer
  than that never sees it. This is a best-effort "find out sooner" layer, not the durable record:
  the ticket itself, polled with `tickets ticket show <ID> --json`, is what MAT-T103 already
  documented as the real, no-expiry, already-generic cross-CLI notification path
  (`docs/claude-only-abilities.md`, section 1c). Use both - broadcast for the CLI that happens to be
  mid-turn soon, rely on the ticket DB for the one that isn't.
- Only reaches a pid that has a `*.state.json` here already - a CLI that has never run a turn since
  being wired to the shared hooks won't show up until it does.
- This is same-machine only (the session-context directory lives under the local user profile); it
  does not reach a CLI running on a different machine.
