---
description: Bring up this login's one Launcher tab in the MindAttic.Orchestrator dashboard, or open it when it has none. /launcher [EMAIL].
argument-hint: "[EMAIL]"
---

Run `orchestrator launcher` (with an argument: `orchestrator launcher --login $ARGUMENTS`). With no argument it means this CLI's own login (its `CLAUDE_CONFIG_DIR` account, else the global login). It asks any running MindAttic.Orchestrator dashboard, over the same bus /dock and /undock use, to bring up that login's one Launcher tab; when the login has no Launcher tab, it opens one - the same as the person tab's right-click "Run Launcher". Only ever one Launcher tab per login (M.ORCH-T1890), so there's nothing to cycle through any more. It never closes or restarts anything.

Report the command's own result line to the user, verbatim or near enough. If it says it couldn't reach the dashboard's bus, tell the user plainly that MindAttic.Orchestrator needs to be running - retrying won't help until it is.
