---
name: progress
description: Show what every running subagent is doing and roughly what percent done each one is.
argument-hint: "[-Running] [-Since <min>] [-DoneWithin <min>] [-Session <id>]"
claude-only: false
claude-allowed-tools: Bash, PowerShell
---
Show subagent progress. The shared runner does the work; this ability only invokes it.

1. Run, passing through any arguments the user gave (`$ARGUMENTS`):

   ```powershell
   powershell -NoProfile -File D:\Projects\MindAttic\mindattic-agent-standard\agent-progress.ps1 $ARGUMENTS
   ```

2. Show its report to the user as-is, in a code block so the bars line up. It covers every
   session and project, so subagents of other CLIs appear too (their session id and project are
   on each entry).
3. Under it, add at most three short lines of your own:
   - anything marked `stalled?` (no activity for 10+ minutes while not finished): name it and
     say what it was last doing;
   - for this CLI's own subagents, anything you know that the transcript can't show (for
     example, which one the next ticket is waiting on).

   Don't restate the table.

The percent is an estimate. A ticket agent is placed by the milestones it has reached:
explore -> edit -> test -> commit -> push -> ticket closed. Any other agent is estimated from its
tool calls only and shown with a `~`. Say "about" when you quote a percent.

Inside the Prose repo, Prose's own project `/progress` (its strand dashboard) takes precedence; this
command is everywhere else.
