---
description: A brochure of every pending quicksave handoff - code, alias, repo, and a short description of what it's about - so you can find the one to resume.
argument-hint: "[nothing - lists every pending handoff]"
allowed-tools: PowerShell, Bash
---

# Handoffs - browse pending quicksaves

Global MindAttic command (MAT-T109) - works in any repo under the workspace root, with no
per-project setup. Lists every **unconsumed** handoff in the machine-wide registry
(`%LOCALAPPDATA%\MindAttic\handoffs`, shared by every login) - a handoff already restored by
`/quickload` is consumed and won't appear. Give one nickname with `/alias` (see that command) if
a handoff doesn't have one and should.

## 1. Find the shared runner

Walk up from the current directory until you find a folder containing
`mindattic-agent-standard\prose-agent.ps1` as an immediate child (that folder is the MindAttic
workspace root). In an orchestrator worktree (outside the workspace), use
`D:\Projects\MindAttic\mindattic-agent-standard\prose-agent.ps1`. If you can't find it, tell the
user this repo isn't under a MindAttic workspace and stop.

## 2. Fetch the data

```powershell
& <workspace-root>\mindattic-agent-standard\prose-agent.ps1 handoffs -Json
```

This returns every unconsumed handoff, newest first, as JSON objects with at least `code`,
`repo.name`, `updatedAt`, `task`. Two fields matter most for this brochure when present:

- **`alias`** - a human nickname set by `/alias` (e.g. `SHADOW`, `REMOTE`). Most handoffs won't
  have one.
- **`description`** - a ready-made summary, 255 characters or fewer, of what the handoff is
  about. Use it verbatim when present - don't re-summarize it.

If a handoff has no `description` field (an older save, from before this field existed), write
one yourself from its `task`/`state`/`decisions` fields: plain English, 255 characters or fewer,
no mid-sentence truncation - end on a full clause.

## 3. Render it as a brochure, not a table

A straight table doesn't fit a 255-character description in a column. Instead, print one block
per handoff, newest first:

```
━━━ SHADOW · silky-frogs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Repo:      MindAttic
Updated:   2026-11-06 20:37
Researched hosting the Orchestrator with a real GPU so agents could run/
playtest Unity, Unreal and s&box games. Shadow PC rejected as too specialized/
costly; superseded by REMOTE, a RAM-only host with no GPU need.
```

- The heading line is the alias (if any) and the code, e.g. `SHADOW · silky-frogs`; a handoff
  with no alias just shows its code alone, e.g. `early-badgers`.
- `Updated` in local time, human-readable (`yyyy-MM-dd HH:mm` is fine).
- Wrap the description to a comfortable terminal width (about 78 columns); don't print it as one
  unbroken line.
- A blank line between blocks.
- If there are none: say plainly there are no pending handoffs right now.

## 4. Close with how to use one

One short line after the brochure: `/quickload <code or alias>` restores any of these from any
login's CLI (e.g. `/quickload SHADOW` or `/quickload silky-frogs`); `/alias handoff <code>
<name>` gives an unnamed one a nickname.
