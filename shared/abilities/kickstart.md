---
name: kickstart
description: Wake a sleeping Azure web app and its serverless SQL database so the next visit is fast. "/kickstart gadfly" wakes one app (a unique partial name is enough), "/kickstart all" wakes every app, "/kickstart" alone lists every app with its state and its database's status.
argument-hint: "[app name | all]"
claude-only: false
claude-allowed-tools: PowerShell, Bash
---
Global MindAttic command (MAT-T166). MindAttic's Azure web apps run with Always On off: an app unloads
after about 20 idle minutes, and its serverless database pauses after its auto-pause delay (60 minutes by
default) once nothing is connected. A visit wakes both, but the first one can take a minute or two;
`/kickstart` wakes them ahead of time and waits until both answer.

Run, from any folder, with the arguments as given (`$ARGUMENTS`; empty lists):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Projects\MindAttic\mindattic-agent-standard\kickstart.ps1 $ARGUMENTS
```

It needs a signed-in `az` (if it says so, tell the user to run `! az login`). It is read-only: it only
sends GET requests to the site and opens one `SELECT 1` connection to the database, and never changes a
setting, a secret or a resource.

Then report, briefly:

- with a name or `all`: whether the app and its database are up, with how long each took, and **end your
  reply with each app's URL alone on its own line** (bare, e.g. `https://mindattic-gadfly.azurewebsites.net`,
  no bold, brackets or trailing punctuation) so the user can copy and paste it. Mention that the app sleeps again about 20 minutes after the last visit, and that the database
  pauses about an hour after that, so an open browser tab keeps both awake.
- with no argument: the listing as a short table (app, state, URL, database and its status).
- an app reported as **Stopped** is stopped in Azure, not asleep. Don't start it yourself; give the user
  the `az webapp start` line the script printed and let them decide.
- if a name matches several apps or none, relay the script's list of app names and ask which one.
