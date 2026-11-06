---
description: "The organization: /org usage prints every member's usage table; /org login <who> signs a member in; /org members lists them (add, set and remove change them); /org start <repo> <who> starts a CLI on a member's login; /org allow <who> [--until <reset|time>] lets that member's login take work past its weekly target until its weekly reset, /org disallow <who> takes it back, and /org limit [<who> --weekly <pct> --5h <pct> | --reset] lists or sets each member's usage cutoffs (90% of the week and 96% of the 5-hour window by default). <who> is a member's email, the part before the @, name, first name, login alias or initials. Each works on the org chosen in the dashboard's switcher; --org <id|name> picks another. /org help lists them."
argument-hint: "[usage [--detail] [--since <date>] [--csv|--json] [--md|--html <file>] | login <who> | members [add|set|remove ...] | start <repo> <who> | allow <who> [--until <reset|time>] | disallow <who> | limit [<who> --weekly <pct> --5h <pct> | --reset] | help] [--org <id|name>]"
---

/org $ARGUMENTS (or /organization $ARGUMENTS) was asked for. All it does is run
MindAttic.Orchestrator's CLI: do nothing else, and don't work out any answer yourself.

If the arguments start with "login": that opens a browser sign-in, which has to run in the user's own terminal, so don't run it. Reply with only this line, for the user to type at the prompt:
`! orchestrator org $ARGUMENTS`

If the arguments start with "allow" or "disallow", or are "limit" with a member and a percent or --reset: letting a login past its weekly target or changing its cutoffs is the user's decision alone, so run it only when the user's own latest prompt asked for it, never on your own, for another agent, or to get a ticket worked.

Otherwise (allow, disallow and limit changes included, once the user asked) run `orchestrator org $ARGUMENTS` (from any folder) and show what it prints exactly as printed, in one code block so the table's columns line up: no summary, nothing reformatted, left out or added. Then end your turn.
