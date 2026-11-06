---
name: member-contact
description: Template ability backing the per-org-member commands (/amy, /erin, /honey, /jordan, /ohleo199, /pdftransferjr, /ryan, /ryandebraal, /shampoo1232, /waffle, and any alias generated for an active org member) - "/<member> research <what>" hands them a research task (see the research ability); anything else is a message to that member's running CLI, or opens one on their login with it.
argument-hint: "research <what> | <message>"
claude-only: true
claude-only-reason: Depends on ListAgents (to discover this session's own name/other running sessions) and SendMessage (to deliver a reply to a named peer session) - both Claude-only mechanisms. No confirmed equivalent "list/message other running CLI sessions" primitive exists on Codex/Kimi/agy yet.
template: true
template-vars: [NAME, EMAIL, SLUG]
rendered-by: shared/member-commands.ps1 (reads 'orchestrator org members --json', fills shared/commands/member/member.md.template and ambiguous.md.template per active member/alias, MAT-T89). render-abilities.ps1 does not duplicate that logic for Claude; it just makes sure the step still runs.
claude-allowed-tools: PowerShell, Bash, Read, ListAgents, SendMessage
---
This is not a single command: it is the template that produces one global command per active org
member alias (their name, their initials when the name has two-plus words, and the part of their
email before the @). An alias several members share instead gets an "ambiguous" variant that asks
"Did you mean X or Y?" before doing anything. The generator (shared/member-commands.ps1) already
does this from the live member list; keep using it rather than hand-writing one ability per person.

`$ARGUMENTS` starts with a verb or it doesn't:

- **`research <what>`**: follow the research ability exactly, with `<who>` = this member's email and
  `<what>` = everything after the word `research`.
- **Anything else is a message to this member**, verbatim:
  1. Call ListAgents. Its first line names this session ("This session is <name> [<ref>]"): that is
     the reply address.
  2. If a running peer session is plainly this member's (its row names their login or email, or a
     session they started for this), SendMessage it: "From <your login's email> (reply to <name>):
     <message>". If two match, send to the one in this repo.
  3. Otherwise start one on their login in this repo: write the text "Message from <your login's
     email>, sent from the session <name> [<ref>]: <message>. Answer it, and send your reply back
     with SendMessage to <name>." to a scratchpad file, then run
     `$p = (Get-Content -Raw <file>).Replace('"', "'"); orchestrator org start <Repo> <email> --prompt $p`
     (the repo is the one the current directory is in; MindAttic.Agency in the workspace root).
  4. Tell the user in one line where it went. Their reply arrives here as a notification. Don't wait
     or poll for it.

For Codex/Kimi/agy: this whole mechanism (listing other running sessions, messaging one directly,
or starting a CLI on another login) is unconfirmed outside Claude Code today. Until a portable
equivalent exists, these per-member aliases render for Claude only.
