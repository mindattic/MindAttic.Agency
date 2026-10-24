---
description: Save the current discussion as a handoff so it survives /clear; restore with a bare 'do', /quickload, or /quickload <code> from any login's CLI.
argument-hint: "[optional note to emphasize what matters most]"
allowed-tools: PowerShell, Bash, Read
---

# Quicksave

Global MindAttic command - works in any repo under the workspace root, with no per-project setup.
It's a thin alias for the shared runner's `save`: the runner owns the handoff file and its
archiving (never overwritten, never deleted - an unconsumed prior save is shifted to
`.agent\agent-session.json.001`, older ones shifting up). This alias only fills in what to save.

Every save also gets a short shareable code (adjective-animal, e.g. `lively-oxen`) and is recorded
in the machine-wide handoff registry (`%LOCALAPPDATA%\MindAttic\handoffs`, shared by every login),
with the repo/worktree it was made in. `/quickload <code>` loads that exact handoff from any
login's CLI, in any folder.

## 1. Find the shared runner

Walk up from the current directory until you find a folder containing
`mindattic-agent-standard\prose-agent.ps1` as an immediate child (that folder is the MindAttic
workspace root; the current repo is one of its direct subfolders). In an orchestrator worktree
(outside the workspace), use `D:\Projects\MindAttic\mindattic-agent-standard\prose-agent.ps1`.
If you can't find it, tell the user this repo isn't under a MindAttic workspace and stop - don't
guess a path.

## 2. Compose the handoff

Write four fields about the *current* discussion - what a fresh session needs to resume without
re-asking anything. Be concrete: file paths, names, ids, exact commands. If `$ARGUMENTS` is
non-empty, lead **Task** with it.

- **Task** - the one thing we are mid-work on, as a resumable instruction.
- **Decisions** - what is settled and must not be re-litigated.
- **State** - what's done, what's in flight, the last action and its result.
- **Next** - the next concrete steps, numbered, the very next action first.

## 3. Save it

Run it from the current repo root with the PowerShell tool (single-quote the strings, doubling
any `'` inside them):

```powershell
& <workspace-root>\mindattic-agent-standard\prose-agent.ps1 save -RepoRoot (Get-Location) `
  -Task '<task>' -Decisions '<decisions>' -State '<state>' -Next '<next>'
```

It prints the handoff code it picked.

## 4. Confirm

Tell the user in one line that it's saved and give the code: run `/clear`, then type `do` (or
`/quickload`) here, or `/quickload <code>` from any login's CLI. Do nothing else.
