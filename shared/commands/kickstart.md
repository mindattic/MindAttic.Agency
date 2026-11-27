---
description: Start (or wake) an Azure web app and its serverless SQL database so the next visit is fast. "/kickstart gadfly" starts one app (a unique partial name is enough), "/kickstart all" starts every app, "/kickstart" alone lists every app with its state and its database's status.
argument-hint: "[app name | all]"
allowed-tools: PowerShell, Bash
---

Global MindAttic command (MAT-T166, MAT-T218). MindAttic's Azure web apps are kept **Stopped** and brought
up on demand. A running app has Always On off, and an idle one stops itself (Gadfly stops after 20 idle
minutes once grading and emails are done, GAD-T775); its serverless database pauses after its auto-pause
delay (20 minutes for Gadfly) once nothing is connected. `/kickstart <app>` starts a Stopped app
(`az webapp start`), wakes its database and waits until the site answers, usually within 1-2 minutes.

Run, from any folder, with the arguments as given (`$ARGUMENTS`; empty lists):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Projects\MindAttic\mindattic-agent-standard\kickstart.ps1 $ARGUMENTS
```

It needs a signed-in `az` (if it says so, tell the user to run `! az login`). With no argument it is
read-only (the listing). With a name or `all`, the one change it makes is `az webapp start` on an app that
is Stopped; otherwise it only sends GET requests to the site and opens one `SELECT 1` connection to the
database, and never changes a setting or a secret.

Then report, briefly:

- with a name or `all`: whether the app was started, and whether its database and site are up, with how
  long each took (start, db, app), and **end your reply with each app's URL alone on its own line** (bare,
  e.g. `https://mindattic-gadfly.azurewebsites.net`, no bold, brackets or trailing punctuation) so the user
  can copy and paste it. Mention that an idle app stops itself again about 20 minutes after the last visit
  and its database pauses about 20 minutes after that, so an open browser tab keeps both up.
- with no argument: the listing as a short table (app, state, URL, database and its status).
- if `start:` reports a failure, relay it; the app stays Stopped.
- if a name matches several apps or none, relay the script's list of app names and ask which one.
