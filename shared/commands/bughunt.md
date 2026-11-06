---
description: Hunt for real bugs and fix every one found. "/bughunt X" searches for X minutes then fixes everything found (the time budget bounds the search, not the fixing). "/bughunt" with no argument searches exhaustively once, then fixes everything found.
argument-hint: "[minutes]"
allowed-tools: Read, Grep, Glob, Edit, Write, Bash, PowerShell, Agent
---

Two phases, always in this order: **search**, then **fix**. The time budget in `$ARGUMENTS`
(if any) bounds only the search phase. Once search ends, fix every bug found - no matter how
long the fix phase itself takes. The budget is never a time limit on fixing.

## 1. Parse the budget

- If `$ARGUMENTS` is a plain number, that's **X minutes** for the search phase.
- If `$ARGUMENTS` is empty, there is no time budget - do one exhaustive search pass across the
  whole project instead of clock-bounding it.
- If `$ARGUMENTS` is present but not a number, ask the user to clarify rather than guessing.

## 2. Scope

Default scope is the whole current project's tracked source. Use `git ls-files` (or equivalent)
to stay inside tracked source and skip build output, dependencies, `node_modules`, `bin/`,
`obj/`, `dist/`, vendored code, lockfiles, and generated code. This is a sweep of the whole
codebase, not a review of the current diff.

## 3. Search phase - find bugs, do not fix yet

Keep a running list in your own scratch notes (not a project file) of **confirmed or
highly-plausible bugs only** - each with file:line, a one-line description, and the concrete
input/state that makes it wrong. Exclude style preferences, hypothetical hardening, and anything
that's a matter of taste rather than a real defect.

What counts as a bug: crashes, incorrect logic, null/reference errors, off-by-one errors, race
conditions and other concurrency bugs, resource/connection leaks, swallowed or mishandled
exceptions, broken error handling, security vulnerabilities (injection, auth bypass, secrets
committed in code, etc.), data loss/corruption risks, API misuse, and dead code paths that
silently produce wrong results.

Technique, in rough order:

1. Run the project's build and test suite (detect it from the repo: `dotnet build`/`dotnet test`,
   `npm test`, `pytest`, `go test ./...`, etc.). Compiler warnings and failing/flaky tests are
   free, high-confidence signal - start there.
2. Read through the source systematically, one module/service/package per pass. For independent
   areas, if your environment can run separate parallel helper agents or sub-processes (for
   example Claude Code's Agent tool, forking read-only Explore/general-purpose searches), use that
   to cover more ground within the same wall-clock budget - each fork reports findings with
   file:line back to you and fixes nothing itself. Otherwise, work through the areas sequentially.
3. Grep for bug-prone patterns relevant to the language/stack in play: unchecked nulls, `==`
   where identity/value equality is wrong, unawaited async calls, unclosed `IDisposable`/file
   handles/connections, catch blocks that swallow exceptions, string-built SQL, hardcoded
   secrets.
4. If the repo documents invariants (house rules, architecture docs, a CLAUDE.md/AGENTS.md
   "Laws" section), check code against them - a violation of a documented invariant is a bug.

If a time budget was given: keep taking search passes (broadening or deepening coverage),
checking the real wall-clock elapsed time between passes (e.g. `date` or `Get-Date`) rather than
estimating. Stop the moment X minutes have elapsed, even mid-pass - whatever's been found so far
moves on to the fix phase.

If no budget was given: keep going until the whole scoped codebase has been covered once at
reasonable depth, then stop searching regardless of how long that took.

## 4. Fix phase - no time limit

Go through every recorded bug and fix it:

- Minimal, targeted fix for the actual defect - no unrelated refactors, no drive-by style
  changes, no new abstractions beyond what the fix requires.
- After each fix (or in a batch at the end, whichever is safer for the change), re-run the
  build/test suite to confirm the fix works and nothing else regressed.
- If something recorded as a "bug" turns out, on closer inspection, not to be a real defect,
  drop it and say why rather than making a no-op change.
- If something is a real bug but unsafe to auto-fix (the correct behavior is a product decision,
  or the fix is destructive/high-risk), do NOT fix it - list it separately as "needs human input"
  with the reasoning.

## 5. Report

End with a short summary: how long the search ran (or that it was unbounded), how many bugs were
found, a table of bug -> fix -> verification status, and a separate list of anything flagged but
intentionally left unfixed. Do not commit or push automatically - leave fixes in the working tree
for the user to review.
