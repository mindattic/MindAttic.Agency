---
description: Have MindAttic.Psst announce something to the owner by text and email - now, at a time, on a repeating schedule, or when an event happens (every open CLI done, an app redeployed, a ticket closed, a file, a process, a URL, any command). Plain words in, the right psst command out.
argument-hint: "<what to announce, and when - in plain words>"
allowed-tools: Bash, PowerShell
---

`/psst $ARGUMENTS` was typed by the user, so this is the explicit ask HOUSE-LAW-9 requires: Psst plays a
sound at their desk and sends a real text and email. Never run it for any other reason, and never
send more than was asked.

Work out from the plain words **what to say** and **when**, then run one `psst` command. Don't ask
which form they meant when the words settle it; ask only when the time or the event can't be told.

## 1. Find `psst`

`psst` on PATH, else `R:\MindAttic\Apps\MindAttic.Psst\Release\psst.exe`.
Neither there: say Psst isn't built here (`dotnet build MindAttic.Psst.slnx -c Release` in its repo) and stop.

## 2. Pick the form

| The words say | Run |
|---|---|
| now ("tell me X", no time or event) | `psst test "<message>"` |
| one moment ("at 3pm", "tomorrow 9am", "in 2 hours", a date) | `psst remind --at <when> "<message>"` |
| a repeating time ("every weekday at 9", "every 2 hours", "Mondays at 8") | `psst when "Weekdays(9am)" "<message>"`, `"Every(2h)"`, `"Daily(7:30am)"`, `"Weekly(mon, 8am)"` |
| an event ("when all the CLIs are done", "when Orchestrator is redeployed") | `psst when <Trigger> "<message>"` |
| when a command you are about to run finishes | `psst -- <command>` |

`--at` takes `10:30am`, `22:30`, `2027-03-01`, `2027-03-01T14:30`, `+45m`, `+2h`, `+30d`.

## 3. Events: `psst when`

Run `psst triggers` for the full, current list (it is the source of truth; `psst triggers --json`
for a machine-readable one). The common ones:

- `NoActiveClisDetected`: no open Claude CLI is running work. CLIs on a `/goal` are left out
  (they keep themselves going); `NoActiveClisDetected(includeGoal)` counts them too.
- `CliIdle(<repo>)`, `TicketClosed(<id>)`
- `OrchestratorRedeployed`, `AppRedeployed(<app>)`, `ProcessStarted(<name>)`, `ProcessExited(<name or pid>)`
- `FileExists(<path>)`, `FileMissing(<path>)`, `FileChanged(<path>)`, `RepoCommitted(<repo>)`, `DiskFreeBelow(<drive>, <GB>)`
- `HttpUp(<url>)`, `HttpDown(<url>)`, `HttpChanged(<url>)`, `PortOpen(<host>, <port>)`, `InternetUp`, `InternetDown`
- `CommandSucceeds`, `CommandFails`, `CommandOutputChanged`: any event with no trigger of its own.
  Write a command line whose exit code (or output) answers the question and pass it with `--arg`:
  `psst when CommandSucceeds --arg "gh run watch 123 --exit-status" "CI is green"`.

Rules that matter:

- **Once or every time.** A watch announces once and removes itself. "Every time", "whenever",
  "each time" means `--recurring`; add `--cooldown 30m` when it could fire in bursts. Clock triggers
  always repeat.
- **Arguments** go in brackets, `"FileExists(D:\out\done.txt)"` (quote the whole thing in the shell),
  or one `--arg <value>` each when a value holds a comma, a bracket or a quote.
- **Check before you register** when unsure a trigger reads the way you think:
  `psst triggers check "<Trigger(args)>"` looks once and announces nothing. `psst when` itself
  refuses a trigger it can't read, and says why.
- **Naming.** `--name <id>` (letters, digits, `.`, `_`, `-`) makes a watch replaceable and easy to
  cancel; use one when the user is likely to change or cancel it.
- **Limits to say out loud.** A watch is looked at once a minute at most (`--poll 5m` for less
  often), by a MindAttic.Scheduler job on this PC, so nothing fires while the PC is off or asleep.
  `--expires +1d` makes a watch give up on its own.
- **No message given**: leave it out; the trigger supplies its own sentence.

## 4. Report

Two lines at most: what will be announced and when (or that it was sent, with psst's own ✓/✗ lines
if any failed), and how to cancel it (`psst scheduled cancel <id>`). `psst scheduled` lists
everything pending; "cancel my psst ..." means `psst scheduled cancel <id>` after finding it there.

If `psst` prints `no SMS transport configured` or an SMTP error, show that line as it is; don't retry
with other settings. Email copies go to the `emailTo` mailbox shown by `psst ping`.
