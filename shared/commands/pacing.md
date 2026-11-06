---
description: /pacing off runs this CLI without pace holds until it closes or /pacing on (the default for every new CLI); a bare /pacing says which this CLI is on. The 99% and weekly stops still apply.
argument-hint: "[on|off]"
disable-model-invocation: true
---

/pacing $ARGUMENTS was typed in this CLI, and MindAttic.Orchestrator's context gate has recorded it
for this CLI process only. With off: no pace holds (subagents included) until the CLI closes or
/pacing on is typed; its usage still counts toward the 5-hour pace, so other CLIs absorb it, and the
stop at the window's target and the weekly stop still apply. With on: this CLI is held to the pace
again. Reply with one short line confirming which, then carry on with whatever was asked.
