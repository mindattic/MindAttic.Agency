---
description: Attach, replace, or clear a human nickname on a pending quicksave handoff, at any time - not just at save time. /alias <type> <real-name> <alias>.
argument-hint: "<type> <real-name> <alias>  e.g. handoff silky-frogs SHADOW"
allowed-tools: PowerShell, Bash
---

# Alias - nickname a handoff

Global MindAttic command (MAT-T110) - works in any repo under the workspace root, with no
per-project setup. A thin wrapper for the shared runner's `alias`, which owns the registry file
and its uniqueness rules. `type` is the kind of thing being aliased; only `handoff` exists today
(covering both `/quicksave` and `/quickload`).

## 1. Find the shared runner

Walk up from the current directory until you find a folder containing
`mindattic-agent-standard\prose-agent.ps1` as an immediate child (that folder is the MindAttic
workspace root). In an orchestrator worktree (outside the workspace), use
`D:\Projects\MindAttic\mindattic-agent-standard\prose-agent.ps1`. If you can't find it, tell the
user this repo isn't under a MindAttic workspace and stop.

## 2. Parse `$ARGUMENTS`

Split on whitespace into exactly three parts: `<type> <real-name> <alias>`. If there aren't three
parts, show the usage (`/alias handoff <code> <nickname>`, e.g. `/alias handoff silky-frogs
SHADOW`) and stop without guessing. `<alias>` may itself contain spaces if the user quoted it -
pass it through as one argument either way; don't split further.

## 3. Run it

```powershell
& <workspace-root>\mindattic-agent-standard\prose-agent.ps1 alias -Type '<type>' -Code '<real-name>' -Alias '<alias>' -RepoRoot (Get-Location)
```

- **Unsupported type**: it reports only `handoff` exists today - relay that and stop.
- **No such handoff**: it reports no unconsumed handoff has that code - relay that (maybe they
  meant a different code, or it's already been consumed by a `/quickload`) and stop.
- **Alias already taken**: it names which code already holds that nickname - relay that, and
  suggest either a different nickname or aliasing the other one away first (an empty `-Alias`
  clears it: `/alias handoff <that other code> ""`).
- **Success**: it prints the confirmation, e.g. `Aliased silky-frogs as 'SHADOW'. /quickload
  SHADOW now resolves to it.` - relay that one line and stop. Do nothing else.

## Clearing a nickname

`/alias handoff <real-name> ""` (an empty third argument) removes the alias from that handoff
without touching anything else about it.
