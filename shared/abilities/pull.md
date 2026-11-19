---
name: pull
description: Pull the latest commits from the current repo's upstream (or a named repo, or "all" repos in the workspace) - fast-forward when possible, rebase only a clean tree, never discard local work.
argument-hint: "[repo name or path | all]"
claude-only: false
claude-allowed-tools: Bash, PowerShell
---
Pull the latest commits from the remote into a local checkout, safely. Global MindAttic command:
works in any repo, with no per-project setup.

## 1. Pick the target

- **No argument:** the repo the current directory is in (`git rev-parse --show-toplevel`). Not in a
  repo: say so and stop.
- **A repo name or path:** that repo. A bare name is looked up as a direct subfolder of the
  workspace root (the folder holding `mindattic-agent-standard\`, e.g. `D:\Projects\MindAttic`),
  then of `D:\Projects\GunGreenEyes`. Not found, or not a git repo: say so and stop.
- **`all`:** every direct subfolder of the workspace root that is a git repo (plus the root itself
  when it is one). Run step 2 for each, one after another, and keep going past a failure.

## 2. Pull one repo

Run each command with `git -C <repo>`:

1. `git fetch --prune` (all remotes it tracks). A fetch failure (offline, auth): report it, skip
   this repo.
2. No upstream on the current branch (`git rev-parse --abbrev-ref @{u}` fails), or a detached HEAD:
   report "fetched, nothing to pull into" and stop for this repo. Don't guess a branch.
3. Count `git rev-list --left-right --count HEAD...@{u}` → `ahead behind`.
   - **behind = 0:** already up to date.
   - **ahead = 0, behind > 0:** `git merge --ff-only @{u}`. Uncommitted changes are fine: git
     refuses on its own if a pulled file would overwrite one. If it refuses, report the files it
     names and stop for this repo.
   - **both > 0 (diverged):** if the tree is clean (`git status --porcelain` empty), run
     `git rebase @{u}`. On a conflict, `git rebase --abort` and report the conflicting files. If the
     tree is dirty, don't rebase: report that local commits and uncommitted changes need the user.

Never `git reset --hard`, `git checkout -- .`, `git clean`, `git stash drop`, a force-push, or
`--autostash`. Other agents may have uncommitted work in the same checkout, and pulling must
never throw anyone's work away. Never push. Pulling doesn't push.

## 3. Report

One line per repo: the branch, then `up to date`, `pulled N commits (old..new)`, `rebased M
local commits onto N new`, or why it stopped. After a pull that brought commits, list their
subjects (`git log --oneline old..new`, at most 10, then "+K more"). Say nothing else.
