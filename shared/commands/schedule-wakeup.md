---
description: Generic, provider-agnostic "resume this CLI later without the user typing continue" mechanism (MAT-T103) - any CLI's own model can request its own scheduled resumption by running mindattic-agent-standard/schedule-wakeup.ps1, which re-invokes a chosen CLI's non-interactive mode in a given directory with a given prompt via a one-shot Windows scheduled task.
argument-hint: "-Cli <claude|codex|kimi|agy> -WorkDir <dir> -Prompt \\"<text>\\" (-DelayMinutes <n> | -At \\"<time>\\")"
allowed-tools: PowerShell, Bash
---

This is the portable equivalent of Claude Code's own `ScheduleWakeup` tool, built on Windows Task
Scheduler instead of a Claude-SDK-only primitive (MAT-T103, following up on MAT-T93/98's finding
that `ScheduleWakeup` had been written off as permanently Claude-only). Its real job - "re-invoke
this CLI non-interactively with a prompt at a future time" - needs nothing Claude-specific: every
CLI this workspace runs ships a non-interactive mode, and `schtasks` can fire any of them.

**Any CLI's own model may call this directly, proactively, the same way Claude calls its native
`ScheduleWakeup` tool** - this is not limited to a user-typed slash command. Reach for it whenever
you need to resume your own work later without anyone typing "continue": a pacing wait
(`shared/abilities/pacing.md`, `listen.md` step 3), a deferred follow-up, "check back on this in an
hour," or anything else that is "come back to this later" rather than "do it right now."

Run it as:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "mindattic-agent-standard\schedule-wakeup.ps1" `
  -Cli <claude|codex|kimi|agy> -WorkDir "<absolute working directory>" `
  -Prompt "<the resume instruction>" -DelayMinutes <n>     # or: -At "<absolute time>"
```

What it does:

1. **Computes a fire time** from `-DelaySeconds`/`-DelayMinutes` or an absolute `-At` time.
2. **Writes a small, self-contained wrapper script** (prompt text Base64-encoded, so quotes/newlines
   in it are never a problem) that: `cd`s to `-WorkDir`, invokes the chosen CLI's own confirmed
   non-interactive flag with the prompt, redirects all output to a UTF-8 log file (default: a
   `wakeup-logs` folder created as a *sibling* of `-WorkDir`, never inside a git-tracked repo),
   deletes its own scheduled task, then deletes itself - nothing lingers but the log.
3. **Registers that wrapper as a ONE-SHOT task** (`schtasks /create /sc once`).

Per-CLI non-interactive invocation, confirmed from each CLI's own `--help`/`exec --help` output
(MAT-T103, not guessed):

- `claude -p "<prompt>"` - cwd is read directly; no separate `-C`/`--cwd` flag.
- `codex exec -C "<dir>" "<prompt>"` - has an explicit working-root flag, passed alongside the cwd.
- `kimi -p "<prompt>"` - no `-C`/`--cwd` flag; relies on the wrapper's `cd` instead.
- `agy -p "<prompt>"` - no `-C`/`--cwd` flag; relies on the wrapper's `cd` instead.

Useful extras: `-ExtraCliArgs` passes through additional flags verbatim (nothing is added by
default - in particular this never silently adds a permission-bypass flag; decide that per call).
`-EnvOverrides 'KEY=VALUE'` sets process env vars before the CLI runs (e.g. pointing an isolated
test rig's `CODEX_HOME` at a scratch directory instead of a live one - the same safe-testing
convention MAT-T94/95/100 used). `-Cancel <TaskName>` deletes a scheduled wakeup that's no longer
needed. Full parameter docs are in the script's own comment-based help (`Get-Help
schedule-wakeup.ps1 -Full`).

**Tested end-to-end (MAT-T103, 2026-11-06)**: scheduled against `codex exec` with an isolated
scratch `CODEX_HOME` (the real, live one was never touched), fired on time, replied with the exact
requested text, logged it, deleted its own scheduled task, and deleted its own wrapper script -
confirmed by re-querying `schtasks` immediately before and after and seeing only the pre-existing,
unrelated scheduled tasks on this machine both times.

**Limitation**: the machine must be on and the triggering user's Windows session logged in at fire
time (this is a `schtasks` limitation, not something this script can route around) - fine for same
session pacing waits, not for "wake my laptop from being fully off."
