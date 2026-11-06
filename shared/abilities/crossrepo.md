---
name: crossrepo
description: Let this CLI work other repos too (the one exception to "a repo's window works only that repo"). /crossrepo off ends it.
argument-hint: "<Repo,Repo|all|off>"
claude-only: false
---
/crossrepo $ARGUMENTS is running in this CLI. MindAttic.Orchestrator's gates record it for this CLI
process, until it closes, when the user typed it, or when you invoked it yourself as a direct
response to the user's own latest request for cross-repo work (for example, a command/skill
mechanism the user's own prompt asked for); an invocation the user didn't ask for is refused and
records nothing, so never start it on your own.

If the arguments are empty or "off": reply with one short line confirming this window is back to its own repo only.

Otherwise reply with one short line confirming this window may now also edit and close tickets in the repos named ("all" means any repo), then carry on with whatever was asked.
