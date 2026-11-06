---
description: Reattach this CLI's hosted session (or another's, by id) into the dashboard right now, instead of waiting for the next automatic check. /dock [SESSION].
argument-hint: "[SESSION]"
---

Run `orchestrator dock $ARGUMENTS` (no arguments: this CLI's own session, from its `MINDATTIC_TERM_ID`). It re-announces the hosted session as just started over the same bus a TermHost already uses when it registers, so any running MindAttic.Orchestrator dashboard reattaches its tab under the right login immediately - the same path a dashboard crash or restart already reattaches through (M.ORCH-T1448). It never kills or restarts the CLI.

Report the command's own result line to the user, verbatim or near enough. If it says this CLI isn't running under a TermHost, tell the user plainly that it needs to have been started through the Launcher (hosted) to be dockable at all - relaunching it that way is the fix, not retrying /dock.
