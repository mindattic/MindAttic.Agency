---
name: poll
description: "/poll ram or /poll ssd|hdd|drive checks the resource now; if it already clears a safe threshold it says so and stops, otherwise it reports the numbers and reschedules itself (via schedule-wakeup.ps1) to recheck in 15 minutes - and keeps doing that, unattended - until it clears, then resumes whatever work --resume names. Use it yourself, proactively, the moment low RAM or disk saturation blocks something, instead of giving up or polling by hand."
argument-hint: "<ram|ssd|hdd|drive> [--resume \"<what to do once clear>\"] [--threshold-gb <n>] [--interval-min <n>] [--max-hops <n>]"
claude-only: false
claude-allowed-tools: PowerShell, Bash
---
`/poll` is the fix for "I'm stuck because of low RAM/disk, I'll just wait" (MAT-T194). Don't wait by
sitting in the conversation burning turns, and don't ask the user to ping you back - call this
yourself, proactively, the moment low memory or disk pressure blocks a build, a subagent spawn, or
anything else. It checks once; if the resource is already fine, it says so and does nothing further.
If not, it reports the numbers and uses [[schedule-wakeup]] to re-invoke this same CLI in 15 minutes
with the same `/poll` call, so it keeps checking unattended - genuinely hands-off, not a loop you sit
and burn turns on - until the resource clears, then it runs whatever `--resume` says.

## 1. Parse `$ARGUMENTS`

First word, case-insensitive:

- `ram` -> RAM check, section 2.
- `drive`, `ssd`, `hdd` or `hd` -> disk check, section 3 (all four mean the same thing: every fixed
  drive, same as `/flush`'s convention).
- anything else -> say which targets exist (`ram`, `drive`/`ssd`/`hdd`/`hd`) and stop.

Remaining flags, any order:

- `--resume "<text>"` - what to do once the resource clears. If omitted, default to "tell the user
  the resource has recovered and ask what to resume" rather than guessing at unstated work.
- `--threshold-gb <n>` - the free-GB floor that counts as "clear". Default **4** for `ram` (matches
  MindAttic.Orchestrator's own memory-guard reporting convention - see its "Memory guard" status
  lines), default **10** for a disk target (loose; builds and NuGet restores want headroom, not just
  non-zero free space).
- `--interval-min <n>` - recheck interval. Default **15** (the owner's own ask).
- `--max-hops <n>` - safety cap on how many times this reschedules itself before giving up and
  reporting back instead of silently polling forever. Default **24** (6 hours at the default
  interval). Decrement it on every hop; if it would go to 0 and the resource still hasn't cleared,
  stop, report the numbers, and let the user decide rather than polling forever unattended.

## 2. RAM check

Read free/total physical memory (`Get-CimInstance Win32_OperatingSystem`, `FreePhysicalMemory`/
`TotalVisibleMemorySize`, in KB - divide by 1MB for GB). Clear once free GB >= `--threshold-gb`.

## 3. Disk check

For every fixed, ready drive (`[System.IO.DriveInfo]::GetDrives() | where DriveType -eq Fixed`),
read free GB. Clear once **every** fixed drive's free GB >= `--threshold-gb` (a single starved drive
still blocks a build that writes there). If one drive is the actual bottleneck (e.g. the one a build
writes to), the caller can narrow this by naming it in `--resume`, but the check itself stays
machine-wide, same as `/flush drive`'s own "every fixed drive" convention - don't narrow the measure
itself, only the resume action.

Disk *saturation* (queue length / active-time percent, the thing that actually stalled builds on
2026-11-24 - R: at 650-1100% disk time) is a different symptom from free *space* and this ability
does not measure it; if that is the real blocker, say so in your report and suggest the user free the
machine up or wait, rather than silently treating low free space as the only possible cause.

## 4. Decide

- **Already clear:** say so in one line with the numbers, do nothing else (no scheduled task, no
  rescheduling) - don't manufacture a wait that was never needed.
- **Not clear:** report the numbers (what's blocking, by how much), then call
  [[schedule-wakeup]] (`mindattic-agent-standard\schedule-wakeup.ps1` or its Agency-repo original) to
  reinvoke **this same CLI provider, in this same working directory**, `--DelayMinutes
  <interval-min>`, with a prompt of exactly:

  ```
  /poll <same target> --resume "<same --resume text, verbatim>" --threshold-gb <n> --interval-min <n> --max-hops <hops - 1>
  ```

  i.e. the full `/poll` invocation again, hops decremented by one, so each hop is a fresh,
  self-contained, non-interactive re-run that needs no memory of this conversation. Tell the user,
  in this turn, that you're hanging back and will recheck in `<interval-min>` minutes, and what
  you'll resume once it clears - then stop working this turn; don't block the conversation waiting.
  **Never loop indefinitely inside one turn or one running process** - the whole point is that a
  *fresh, scheduled, non-interactive invocation* does the waiting, not a spin-loop in the live
  session.

- **Max hops reached, still not clear:** report the numbers and that automatic polling gave up after
  `<max-hops>` attempts (`<max-hops> * <interval-min>` minutes); ask the user how to proceed (keep
  polling with a fresh `/poll`, free resources manually, or proceed anyway) rather than rescheduling
  again on your own.

## 5. Resuming

When a hop's own check finds the resource clear: say so with the numbers, then actually run
`--resume`'s text as the next action (it is a literal instruction, e.g. "rebuild the Socrates model
and report" or "resume the MediaViewer build on M.MVIEW-T6") - don't just announce that you *could*
resume now and stop.

**Tested (MAT-T194):** `/poll ram` with the machine already above its threshold reported the free-GB
number and did nothing further (no scheduled task created); `/poll ram --threshold-gb <a floor
clearly above current free memory>` correctly detected the block and registered a one-shot
`schedule-wakeup` task before returning control - confirmed via `schtasks /query` immediately after.
