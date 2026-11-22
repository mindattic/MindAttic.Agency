# Roles

One file per subagent role, `<role>.md`, rendered by `render-abilities.ps1` into each CLI's own
agent folder (today Claude's `~/.claude/agents/<role>.md`, which every login shares). Edit here and
re-run the script; never hand-edit the rendered copies. This README is not a role.

```
---
name: reviewer
description: Reviews a diff for correctness bugs; use after a change, before it lands.
tools: [Read, Grep, Glob]
model: sonnet
effort: medium
---
You are the reviewer. ...
```

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Lowercase-hyphenated, equal to the file name. |
| `description` | yes | What the role does and when to pick it (quote it if it holds `:` or `#`). |
| `tools` | no | `[A, B]` or `A, B`. Omitted means every tool. Read-only roles (every reviewer) are read-only by this list alone. |
| `model` | no | `inherit`, `sonnet`, `opus`, `haiku` or `fable`. Default `inherit`. |
| `effort` | no | `low`, `medium`, `high`, `xhigh` or `max`. Default: the CLI's own. |

The body after the frontmatter is the role's system prompt. A file that breaks these rules is
skipped with a warning naming the problem; the rest still render.

## Catalog (M.ORCH-T1931)

| Role | Tools | Model / effort | For |
| --- | --- | --- | --- |
| `planner` | Read, Grep, Glob, Bash | opus / high | Splitting work into an epic > feature > story > task tree of ~80k-token tasks |
| `architect` | read-only + web | opus / high | A design before a non-trivial task |
| `implementer` | all | inherit | One dispatched task, landed on main |
| `reviewer` | Read, Grep, Glob (read-only) | sonnet / medium | Reviewing a change before it lands |
| `build-fixer` | all | sonnet / medium | A failing build or test |
| `doc-writer` | read, edit, Bash | sonnet / medium | Docs that match the code |
| `researcher` | read-only + web | sonnet / high | A sourced answer to a question |
| `release` | all | sonnet / medium | Version, changelog, publish or deploy |
| `analyst` | read, Bash, web | sonnet / high | Business side: numbers, trends, acceptance criteria |
| `copywriter` | read, edit | sonnet / medium | Business side: user-facing words |
| `designer` | read, edit, WebFetch | sonnet / high | Business side: screens and layout |

The business-side roles are data like the rest: adding one is a new file here, no code.
