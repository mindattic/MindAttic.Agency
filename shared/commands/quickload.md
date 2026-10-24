---
description: Restore a /quicksave handoff and resume exactly where it left off - this repo's latest, an archive number, or a shareable code from any login.
argument-hint: "[handoff code, e.g. lively-oxen | archive number, e.g. 1 | omit or 0 for the live handoff]"
allowed-tools: Read, PowerShell, Bash
---

# Quickload - restore the handoff

Global MindAttic command - the counterpart to `/quicksave`, works in any repo under the workspace
root with no per-project setup. The live handoff is conceptually save `0`; archives are `.1`, `.2`,
... (most recent archive is `.1`, shifting up as older saves accumulate). `/quickload` with no
argument and `/quickload 0` are **the same command**. A word-word argument (e.g. `lively-oxen`) is
a shareable handoff code.

## 0. Find the shared runner

Walk up from the current directory until you find a folder containing
`mindattic-agent-standard\prose-agent.ps1` as an immediate child (that's the MindAttic workspace
root). In an orchestrator worktree (outside the workspace), use
`D:\Projects\MindAttic\mindattic-agent-standard\prose-agent.ps1`. If you can't find it, tell the
user this repo isn't under a MindAttic workspace and stop.

## A handoff code - `/quickload <code>` (e.g. `/quickload lively-oxen`)

Loads that exact handoff from the machine-wide registry, whichever login and folder saved it:

```powershell
& <workspace-root>\mindattic-agent-standard\prose-agent.ps1 load <code> -RepoRoot (Get-Location)
```

- If it reports no handoff with that code: tell the user, and stop. (`prose-agent.ps1 handoffs`
  lists the unconsumed codes, if they want to pick one.)
- Otherwise it prints Code / Repo (with worktree and branch) / Saved by / Task / Decisions /
  State / Next / Universe / Updated and any queued bookmarks, and consumes the code (archived to
  the registry's `consumed\` folder, never deleted; the code is free for reuse). A code that was
  already consumed is recalled read-only, with a note saying so.
  1. Briefly confirm what you're resuming (one line), including the code.
  2. If the **Repo** path is not the current folder, the work lives there: say so, and work in
     that repo/worktree (subject to the usual one-repo-per-window rules).
  3. Pick up the **Task**, honor every **Decision**, and continue from **Next** without
     re-asking anything already settled.

## No argument, or `0` - `/quickload` / `/quickload 0`

Run, from the current repo root:

```powershell
& <workspace-root>\mindattic-agent-standard\prose-agent.ps1 load -RepoRoot (Get-Location)
```

- If it reports no handoff exists: tell the user there's nothing to restore, and stop.
- Otherwise it prints the same fields, and - as a side effect - archives the live handoff to
  `.agent\agent-session.json.001` (older archives shift up) and consumes its shareable code.
  That's expected: it is consumed for resume purposes only, never lost.
  1. Briefly confirm to the user what you're resuming (one line).
  2. Pick up the **Task**, honor every **Decision**, and continue from **Next** without
     re-asking anything already settled.

## A positive number - `/quickload <N>` (e.g. `/quickload 1`, `/quickload 3`)

The runner has no subcommand for this - recall one specific archive directly and read-only,
**without consuming or rotating anything**:

1. Read `.agent\agent-session.json.NNN` in the current repo root, zero-padded to 3 digits
   (`.001`, `.002`, ...).
2. If that exact archive doesn't exist: tell the user, list the archive numbers that *do* exist
   (`.agent\agent-session.json.*` in the repo root), and stop. Don't guess which one they meant.
3. If it exists: treat its `task` / `decisions` / `state` / `next` fields as your authoritative
   working memory for this session, same as the no-argument case - but leave every file on disk
   exactly as it is. This is a read-only recall ("what was I doing two saves ago"), not a
   consume-and-resume.
   - Briefly confirm which archive you loaded (e.g. "Resuming from agent-session.json.003: ...").
   - Pick up its **Task**, honor its **Decisions**, and continue from its **Next** without
     re-asking anything already settled. If the live handoff or a more recent archive describes a
     *different* task, say so - the user asked for this specific one on purpose, but a stale plan
     is worth flagging.
