---
name: undock
description: Drop this CLI's own tab from the dashboard (or another's, by id) without ending the CLI — it keeps running headless; /dock (or the dashboard's own "Dock now") brings it back. /undock [SESSION].
argument-hint: "[SESSION]"
claude-only: false
---
Run `orchestrator undock $ARGUMENTS` (no arguments: this CLI's own session, from its `MINDATTIC_TERM_ID`). It asks any running MindAttic.Orchestrator dashboard to drop this session's tab - the opposite of /dock (M.ORCH-T1448). The CLI itself is untouched and keeps running; nothing about it changes except that the dashboard stops showing it until /dock (or the dashboard's own "Dock now") brings the tab back.

Report the command's own result line to the user, verbatim or near enough.
