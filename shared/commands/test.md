---
description: Run the current repo's entire test suite, name every failure, and file a fix ticket for each. The one explicit way to ask for tests (agents never run them on their own, and /commit doesn't).
argument-hint: "[optional repo name, when not standing in one]"
allowed-tools: PowerShell, Bash, Read, Grep, Glob
---

# /test — run a repo's whole test suite

Global MindAttic command (`/run tests` and `/run test` are aliases for it). This is the user explicitly asking for tests, so the "tests only when the
user says so" rule is satisfied for this one run. It runs the **whole** suite once, never a filtered
slice, and nothing re-runs it automatically afterwards.

## 1. Pick the repo and the revision

- The repo is `$ARGUMENTS` if given (a folder under the workspace root), else the repo the current
  directory is in. In the workspace root with no argument, ask which repo.
- Test what's on `origin/main`, not someone's half-done working tree: fetch, then use (or create) a
  clean detached worktree at `D:\Projects\MindAttic.worktrees\<Repo>\verify-main` checked out at
  `origin/main`. Never test in, reset or touch the main checkout.

## 2. Detect the suite

In the worktree, the first that applies:
- a `*.slnx` / `*.sln` at the root (or test projects under `tests/`): `dotnet test <solution> -nologo --logger "trx;LogFileName=tests.trx" --results-directory <out>`
- `package.json` with a `test` script: `npm test`
- `pyproject.toml` / `pytest.ini` / a `tests/` folder of `test_*.py`: `python -m pytest`
- `*.Tests.ps1` files: `Invoke-Pester -Output Detailed`
- `go.mod`: `go test ./...`
If none applies, say the repo has no test suite and stop.

## 3. Run it detached

A full suite can take 15+ minutes and the CLI may reap a background shell under memory pressure,
so start the run as its own process, with output to files in the scratchpad (`<out>`):

```powershell
$p = Start-Process <exe> -ArgumentList <args> -WorkingDirectory <worktree> -RedirectStandardOutput "<out>\stdout.txt" -RedirectStandardError "<out>\stderr.txt" -WindowStyle Hidden -PassThru
```

Then wait for that PID in a background shell command (`while (Get-Process -Id <pid> -EA SilentlyContinue) { Start-Sleep 20 }`)
and tell the user in one line that it's running, at which commit, and roughly how long it takes.
Don't poll; you're notified when the wait ends.

## 4. Report

- The totals line (passed / failed / skipped, duration) and the commit tested.
- Every failing test by name with its one-line error (from `stdout.txt` / the trx).
- All green: say so in one line and stop.

## 5. Failures become fix tickets

Group failures by likely cause and file one `--type fix` ticket per group in that repo
(`tickets ticket new --repo <Repo> --type fix --summary "<test(s)>: <symptom> (found by /tests)"`).
Fixes need no approval, so work them through subagents, one per ticket, all in the repo's own checkout on
`main` (the GOLDEN RULE: no separate branch or worktree, ever; subagents touch disjoint files):
find the root cause (product regression → fix the code; stale or non-hermetic test → fix the test, and
say why), verify with a **filtered** run of only its failing tests, commit with the ticket ID, land on
main and close the ticket. Never re-run the full suite on your own afterwards: when they've landed,
tell the user `/test` again will confirm it.
