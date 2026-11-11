---
name: launcher
description: Bring up this login's next Launcher tab in the MindAttic.Orchestrator dashboard (next, next, ... cycling through them), or open one when it has none. /launcher [EMAIL].
argument-hint: "[EMAIL]"
claude-only: false
---
Run `orchestrator launcher` (with an argument: `orchestrator launcher --login $ARGUMENTS`). With no argument it means this CLI's own login (its `CLAUDE_CONFIG_DIR` account, else the global login). It asks any running MindAttic.Orchestrator dashboard, over the same bus /dock and /undock use, to bring up the next of that login's Launcher tabs after the one shown, wrapping round to the first; when the login has no Launcher tab, it opens a new one - the same as the person tab's right-click "New Launcher" (M.ORCH-T1487). It never closes or restarts anything.

Report the command's own result line to the user, verbatim or near enough. If it says it couldn't reach the dashboard's bus, tell the user plainly that MindAttic.Orchestrator needs to be running - retrying won't help until it is.
