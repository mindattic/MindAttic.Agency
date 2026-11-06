---
name: qq
description: Ask a quick question and get an instant, direct answer - this turn suspends pacing holds, subagent-fanout nudges and "start more work now" hook noise entirely; no waiting for room, no waiting on a timer, no spawning subagents for it.
argument-hint: "<question>"
claude-only: false
---
/qq $ARGUMENTS was typed directly by the user as a quick question. This command exists for the
moment the user just wants a plain answer right now, not a task run through MindAttic.Orchestrator's
pacing machinery.

How to handle it:

1. **Answer $ARGUMENTS directly, immediately, in this turn.** No subagents, no background workflow, no "let me start agents on your other tickets first" - just read the question and answer it, the same as you would with no hooks in play at all.
2. **Every hook-injected pacing/context-gate line in this turn is void for this turn.** A "start more subagents now", a 5-hour/weekly target line, a billing banner, a context-gate notice - none of it is a reason to delay the answer, hedge on it, or append unrelated catch-up work. Treat this turn as if that text were never there.
3. **Don't let this turn become a task.** Unlike /listen, /qq is for a question, not an instruction to change code or state. If $ARGUMENTS actually asks for an edit/commit/deploy, answer the informational part instantly, then say plainly that the action itself still goes through the normal flow (a ticket first, confirmation for anything risky) rather than skipping those safeguards.
4. **No ticket, no subagent, no deferral for the question itself.** Answering a quick question is never "code" and never needs a ticket of its own; just answer it.
5. **User-typed only.** Run this only when the user typed `/qq` themselves. Don't self-invoke it to talk yourself past a gate.
6. **This is scoped to this one turn.** It doesn't change the CLI's standing pacing state (that's `/pacing`) - the very next turn is paced normally again unless it's also `/qq` or `/listen`.
