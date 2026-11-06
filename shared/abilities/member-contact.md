---
name: member-contact
description: Template ability backing the per-org-member commands (/amy, /erin, /honey, /jordan, /ohleo199, /pdftransferjr, /ryan, /ryandebraal, /shampoo1232, /waffle, and any alias generated for an active org member) - "/<member> research <what>" hands them a research task (see the research ability); "/<member> pair [repo]" splits a repo's open tickets between you both and starts each working their share; anything else is a message to that member's running CLI, or opens one on their login with it.
argument-hint: "research <what> | pair [repo] | <message>"
claude-only: true
claude-only-reason: Same two-part finding as the research ability's (read that one, and docs/claude-only-abilities.md, for the full reasoning) - MAT-T103 traced this past SendMessage/ListAgents to a more fundamental reason. The "research <what>" branch starts work via `orchestrator org start <repo> <who>`, which is hardcoded to a Claude session regardless of the target member's own configured CLI (MindAttic.Orchestrator's --account login path explicitly refuses any provider but Claude, confirmed from source) - so there is no cross-CLI "start this under their own login" path yet. The plain-message branch still depends on ListAgents (to discover this session's own name/other running sessions) and SendMessage (to deliver a reply to a named peer session) - both Claude-only mechanisms with no confirmed equivalent for reaching a specific, already-running peer conversation live. A generic async substitute exists for "research": the filed ticket closes with a note when the work lands, pollable by any CLI via `tickets ticket show <ID> --json` - no live push needed to eventually learn the answer.
codex-equivalent-note: Same finding as the research ability's (read that one for the full reasoning) - Codex's real, stable, non-experimental `codex agents`/session_index.jsonl/`codex queue --thread --message` trio is architecturally the right shape for "list and message other sessions," but it is scoped to one CODEX_HOME/one login's shared local app-server daemon, and this ability's whole point is reaching a DIFFERENT org member's own separate login. Not a bridge for this gap; genuinely unbridgeable on Codex today, confirmed rather than assumed. MAT-T103 additionally confirmed `orchestrator org start` itself never reaches a non-Claude session on any provider, so the gap predates messaging entirely.
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
- **`pair [repo]`** (MAT-T104): the two of you work one repo side by side. Split its open tickets with
  `tickets ticket divvy --repo <Repo> --member <your login's email> --member <their email>` (each ticket
  assigned to one of you, so the Orchestrator dispatches it only on that login), start their CLI in the
  repo (or message their running one) with a brief telling it to run /allocate -repo=<Repo> on its share,
  run /allocate -repo=<Repo> here on yours, and coordinate through `tickets ticket note`, `tickets ticket
  block` and SendMessage; whoever runs dry runs `divvy --rebalance`. The generated command template
  (shared/commands/member/member.md.template) holds the exact steps and brief.
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
or starting a CLI on another login) is confirmed Claude-only today (MAT-T98/MAT-T103 checked the
real alternatives on each CLI from source, not just an absence of testing - see
docs/claude-only-abilities.md). The one piece with a working generic substitute is the research
branch's eventual answer, discoverable by any CLI via `tickets ticket show <ID> --json` once the
ticket closes - just not as a live push. Until a portable start-a-session-on-their-own-login and
message-it-live mechanism exists, these per-member aliases render for Claude only.
