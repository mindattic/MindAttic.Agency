---
name: research
description: Hand a research question to another org member's login - /research <who> <what> starts a CLI on their login in this repo that answers it, saves the answer to docs/research/, commits it and messages you back.
argument-hint: "<who> <what to research - a question, a list, or pasted text>"
claude-only: true
claude-only-reason: Depends on ListAgents, SendMessage and AskUserQuestion (resolving an ambiguous member and messaging the result back to a named peer session) - Claude-only mechanisms with no confirmed Codex/Kimi/agy equivalent yet.
claude-allowed-tools: PowerShell, Bash, Read, ListAgents, SendMessage, AskUserQuestion
codex-equivalent-note: MAT-T98 checked this specifically (it is not the same gap as /allocate's). The member this ability reaches runs on a DIFFERENT org member's own login - a different top-level CLI process, started separately via `orchestrator org start <repo> <who>`, not a child of this session. Codex's multi_agent_v2 spawn_agent family (the real equivalent found for /allocate) is explicitly the wrong mechanism here - MAT-T100 confirmed it only spawns a nested mid-turn child of the SAME session, architecturally distinct from Codex's separate top-level-session concept. That separate concept does exist and is real, non-experimental, no feature flag: `codex agents` (browse every session on the local app-server daemon), `$CODEX_HOME/session_index.jsonl` (the same list as a plain file), and `codex queue --thread <uuid|name> --message <text>` (push a message into an existing session from outside it) are all stable top-level `codex` subcommands today. But "the shared local app-server daemon" is scoped to one CODEX_HOME/one login - it does not reach a session running under a different org member's own login/account the way this ability needs. So it is a confirmed real primitive for same-login, cross-window messaging (a different, narrower feature nobody has asked for yet), not a bridge for this ability's actual cross-login need. Remains genuinely unbridgeable on Codex today for that reason, not just unverified.
---
# /research - research on another member's login

Global MindAttic command (MAT-T89). `/<member> research ...` (e.g. `/ryan research "..."`) is the same
command with `<who>` filled in. The user typed this, so it is their explicit ask to start a CLI on that
member's login; nothing else is needed to approve it.

## 1. Read the arguments

`$ARGUMENTS` is `<who> <what>`:
- `<who>` is the first word: an org member by name, first name, initials, full email or the part
  before the @. Resolve it yourself against `orchestrator org members --json` (case-insensitive):
  no match, say so with the member names and stop; more than one, ask the user which one they meant
  before anything else ("Did you mean Marilyn Monroe (mm1@...) or Marilyn Manson (mm2@...)?",
  AskUserQuestion, one option per member). Use the chosen member's email from here on.
- `<what>` is everything after it, verbatim. It may be a plain question or a pasted block of an
  earlier reply. Don't summarise it yet.
- The repo is the one the current directory is in. In the workspace root with no repo, the research
  belongs to MindAttic.Agency (the org-wide home).

## 2. Ticket first

File the research ticket in that repo yourself, before starting anything, so the ask survives a crash:
`tickets ticket new --repo <Repo> --type chore --summary "Research (<who>): <one-line gist of what>"`.
If `<what>` is about tickets already open (it names IDs, or plainly belongs to one), put them in `--ref`.

## 3. Start the CLI

Call ListAgents once: its first line names this session ("This session is <name> [<ref>]"). That
name is the reply address. Write the prompt below to a file in your scratchpad, filling in the `<...>` parts, then run
`$p = (Get-Content -Raw <file>).Replace('"', "'"); orchestrator org start <Repo> <who> --prompt $p` in
PowerShell. Windows PowerShell splits a native argument at embedded double quotes, so they are swapped
for single quotes first; anything quoted in pasted text still reads the same.

```
Research task <TicketID> in <Repo>, sent by <your login's email> from the session <name> [<ref>].
The ticket is already filed; don't file another.

What was asked (verbatim, may be pasted text from another session):
<what>

1. Work out the open questions in it: what the text says it couldn't confirm, asks the user to check,
   or leaves undecided. Answer each one from primary sources (the official page, docs, licence,
   changelog). If a site blocks plain fetches, use a real browser. Never guess: mark anything still
   unconfirmed as unconfirmed, and say why.
2. Write docs/research/<Topic>.md in this repo: the questions, each answer with its source URL and the
   date checked, and a short bottom line. Create docs/research/ if it doesn't exist.
3. Commit only that file: git commit -m "Research: <Topic> (<TicketID>)" -- docs/research/<Topic>.md,
   then push to origin main (fetch and rebase onto it first if you are behind).
4. Close <TicketID> with --ref <commit hash>, and add a one-paragraph note with the answers to every
   ticket listed in its Ref.
5. Message the sender back: SendMessage to "<name>" (add " [<ref>]" if the bare name is ambiguous)
   with the answers in a few lines, the file path, the commit hash and the closed ticket. If that
   session has ended, the ticket notes carry the answer.
Don't work on anything else in this session.
```

## 4. Tell the user

One short block: the ticket ID, whose login it went to, what it will answer, and that the result
lands in `docs/research/` and comes back here as a message. Then end the turn. Don't wait or poll
for it; the message arrives as a notification.
