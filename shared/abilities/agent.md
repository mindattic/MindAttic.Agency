---
name: agent
description: Make or manage a named agent: /agent <role> [--owner EMAIL] creates an idle agent playing that role and prints its agt- id; /agent list, pause, resume and retire <id> manage the agents already made.
argument-hint: "<role> [--owner EMAIL] | list | pause <id> | resume <id> | retire <id>"
claude-only: false
claude-allowed-tools: Bash, PowerShell
---
Run `orchestrator agents` for what `$ARGUMENTS` asks (M.ORCH-T2065, over the CLI M.ORCH-T1744 landed). An agent is a row in the orchestrator's `agents` table with a stable `agt-` id, a role, an owner login, and a state (idle, paused or terminated); making one doesn't start any work.

Pick the branch from the first word of `$ARGUMENTS`:

| First word | Run |
|---|---|
| `list` | `orchestrator agents list` with the rest passed through (`--all` adds retired agents, `--role <role>`, `--owner <email>`, `--json`) |
| `pause`, `resume`, `retire` | `orchestrator agents <word> <id>` (the id as typed, e.g. `agt-3f9a`) |
| anything else, taken as a role | `orchestrator agents new <role>` with the rest passed through (`--owner <email>`, `--runtime`, `--unit`, `--id`, `--json`) |
| nothing | `orchestrator agents list`, then name the roles below in one line |

The roles are the files in `mindattic-agent-standard\shared\roles` (analyst, architect, build-fixer, copywriter, designer, doc-writer, implementer, planner, release, researcher, reviewer); the command checks the name against them and refuses an unknown one, listing the valid ones. Never add `--force` unless the user asked for a role outside the catalog. Without `--owner`, the agent goes on this CLI's own login; on the global login the command asks for `--owner`, so pass it only when the user gave an email.

Report the command's own result line, and for `/agent <role>` make sure the new `agt-` id is in what you say, so the user can pause, resume or retire it later. If the command fails, say its message and stop; don't retry with other flags or make the row some other way.
