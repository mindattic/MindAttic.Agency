# Hook contract matrix

Per-CLI confirmed/unverified behavior for the shared lifecycle hooks
(`shared/hooks/pace-gate.py`, `shared/hooks/context-gate.py`, `shared/hooks/rl-check.py`), one
section per CLI. Claude, Codex and Kimi rows below were filled in by MAT-T94; the agy section was
started by MAT-T96 and extended by MAT-T99 (deny enforcement, SessionStart/PreInvocation/
PostInvocation, project-local discovery); the Codex section's `SubagentStart`/`SubagentStop`/
`Notification` rows were filled in by MAT-T100. MAT-T98 separately settled whether a rendered
skill's `$ARGUMENTS` placeholder is substituted by agy (live-tested: it is not), by Kimi
(source-confirmed: it genuinely is), and by Codex (live-tested: it is not, same as agy - see each
CLI's own section below, which also upgrades Kimi's whole hook-event row from UNVERIFIED using the
same source-reading technique) - that's a skill-authoring question, not one of the lifecycle hooks
this table tracks, so it isn't its own table row, but it's called out in the summary table below too
since the CLIs turned out to behave differently. MAT-T98 also did a second, harder pass on Codex's
own plugin system and on which `claude-only` abilities have a real (if experimental or partial)
Codex equivalent - see "Plugin system and skill-directory correction" and "`claude-only` abilities:
real vs. unbridgeable Codex equivalents" under the Codex section below.

## Summary table

One row per hook event, one column per CLI. `CONFIRMED-WORKING` means the event was observed
firing with the real payload shape (and, for `PreToolUse`, that a `deny` response actually blocked
the tool call); `UNVERIFIED` means no empirical test exercised it either way; `CONFIRMED-NOT-SUPPORTED`
means a real location/shape was ruled out. See each CLI's own section below for how every cell was
confirmed and its caveats - this table is a locator, not the full story.

| Hook event | Claude | Codex | Kimi | agy |
|---|---|---|---|---|
| PreToolUse (deny actually blocks) | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | CONFIRMED-WORKING |
| PostToolUse | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | UNVERIFIED |
| Stop | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | CONFIRMED-WORKING |
| SessionStart | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | CONFIRMED-WORKING |
| PreInvocation / PostInvocation (agy-only events) | n/a | n/a | n/a | CONFIRMED-WORKING |
| Project-local discovery (`.agents/` for agy) | n/a | n/a | n/a | CONFIRMED-WORKING |
| UserPromptSubmit | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | UNVERIFIED |
| SubagentStart | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | UNVERIFIED |
| SubagentStop | CONFIRMED-WORKING | CONFIRMED-WORKING | CONFIRMED-WORKING (source)¹ | UNVERIFIED |
| Notification | CONFIRMED-WORKING | CONFIRMED-NOT-SUPPORTED | CONFIRMED-WORKING (source)¹ | UNVERIFIED |
| `$ARGUMENTS` skill-body substitution | CONFIRMED-WORKING (native slash commands) | CONFIRMED-NOT-SUPPORTED (live-tested, MAT-T98 - see Codex section) | CONFIRMED-WORKING (source)¹ | CONFIRMED-NOT-SUPPORTED (live-tested, MAT-T98) |

¹ Kimi's row is **source-confirmed** (MAT-T98, 2026-11-06), not live-tested against a running tool
call - see the Kimi section below for exactly what "source-confirmed" means here and why it is
still honestly distinguished from Claude/Codex/agy's live-observed rows above.

## Claude Code

This is the native/reference hook contract everything else is compared against
(`hookSpecificOutput.permissionDecision` for `PreToolUse` deny, `hook_event_name`/`session_id`/
`tool_name`/`tool_input` JSON on stdin). `~/.claude/settings.json` already wired all eight events
above before MAT-T94 (`UserPromptSubmit`, `PreToolUse` x2 matchers, `PostToolUse`, `Stop`,
`SubagentStart`, `SubagentStop`, `SessionStart`, `Notification`), all pointed at the loose,
untracked files this ticket moved under version control.

**CONFIRMED-WORKING** (observed directly, 2026-11-06):

- `shared/hooks/{context-gate.py,pace-gate.py,rl-check.py,log-user-input.ps1}` are byte-identical
  copies of the live loose files (verified with `cmp` before any wiring changed) and all parse
  cleanly (`python -m py_compile` for the three `.py` files; a PowerShell AST parse for the `.ps1`).
- None of the three Python scripts resolve any path relative to their own file location
  (`Path(__file__)` does not appear in any of them) - every stateful path is `Path.home() /
  ".claude" / ...`, so moving the script file itself to `shared/hooks/` changes nothing about its
  runtime behavior.
- `install-hooks.ps1` repointed all 11 hook command strings in the live `~/.claude/settings.json`
  (8 `context-gate.py` + 1 `pace-gate.py` + 1 `rl-check.py` + 1 `log-user-input.ps1`) from the old
  loose-file path to `D:/Projects/MindAttic/mindattic-agent-standard/shared/hooks/...` - a pure
  substring swap, confirmed by diffing before/after: every other key (`matcher`, `timeout`, the
  `codex` argv on the Codex-side Stop hook, etc.) is untouched.
- The rewritten `settings.json` is valid JSON (`json.load` succeeded) and the session's own live
  hooks kept working immediately afterward: a plain `ls` via the Bash tool, run right after
  `install-hooks.ps1` repointed the live settings, succeeded normally (`PreToolUse`/`PostToolUse`
  fired with no error, no behavior change) - this is the explicit "did I just break my own session"
  check MAT-T94 required before declaring done.
- `pace-gate.py` also still runs cleanly invoked directly from its new path with a synthetic
  `PreToolUse` stdin payload (`exit 0`, no output = allow, same as before the move).

No `UNVERIFIED` or `CONFIRMED-NOT-SUPPORTED` entries for Claude - this is the reference
implementation and MAT-T94's own hard constraint was "do not change Claude's own observed
behavior," which the check above confirms held.

## Codex

Confirmed empirically 2026-11-06 by running `codex exec` with an **isolated `CODEX_HOME`**
(a throwaway scratch directory with just a copy of the real `auth.json`, so the real
`~/.codex/hooks.json` - live and in use by concurrently-running `codex.exe` processes on this
machine at the time - was never touched for the test itself). `--dangerously-bypass-hook-trust`
was needed for the throwaway hooks.json to run at all (Codex has its own hook-trust gate, separate
from whether the hook's response is honored); `--dangerously-bypass-approvals-and-sandbox` removed
the interactive shell-approval step so the run could be fully non-interactive.

**CONFIRMED-WORKING:**

- `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop` all fired during a
  single `codex exec "Run the shell command: echo hello-mat-t94-test"` run, each carrying Claude's
  own field names verbatim (`session_id`, `hook_event_name`, `tool_name`, `tool_input`,
  `tool_response`, `last_assistant_message`, ...) - confirmed by wiring a throwaway marker hook to
  all eight events at once and inspecting exactly which ones wrote a log line with what payload.
- `PreToolUse`'s `hookSpecificOutput.permissionDecision = "deny"` **genuinely blocks the tool call**
  - the single biggest open question in this ticket. A throwaway hook that unconditionally denied
  every `PreToolUse` call was wired in the isolated `CODEX_HOME`, then `codex exec` was asked to
  run a real shell command; Codex's own log surfaced `error=Command blocked by PreToolUse hook:
  <permissionDecisionReason>` and the agent turn reported the call as blocked back to the model -
  not a silent ignore, not a crash, a real block. The throwaway hook also wrote an
  "invoked" marker to disk as a second, independent confirmation it actually ran.
- The live `~/.codex/hooks.json` (the real, two-event wiring: `PreToolUse -> pace-gate.py`,
  `Stop -> context-gate.py codex`) was repointed by `install-hooks.ps1` to the shared path and
  re-validated as parseable JSON (`json.load`) afterward; the `codex` argv on the `Stop` hook
  command was preserved untouched by the path substring swap.

**CONFIRMED-WORKING (added by MAT-T100, 2026-11-06): `SubagentStart`/`SubagentStop`.**

Codex does have a real, literal subagent mechanism - not just an analogous one. `codex.exe`'s own
binary strings (`codex app-server generate-json-schema`'s `HookEventName` enum, and plain-text UI
strings like "Subagents are currently disabled in your config") show Codex ships a genuine
`spawn_agent`/`wait_agent`/`send_message`/`followup_task`/`close_agent`/`list_agents` tool family
that spawns a real nested child thread mid-conversation - architecturally the same shape as
Claude's Task tool, not Codex's separate top-level-session `agents`/`app-server` subsystem (that
one really is a different, unrelated concept: independent sessions a person browses with
`codex agents`, never nested mid-turn). The internal `HookEventName` enum is exhaustive and
literally includes `subagentStart`/`subagentStop` alongside `preToolUse`, `postToolUse`,
`permissionRequest`, `preCompact`, `postCompact`, `sessionStart`, `sessionEnd`,
`userPromptSubmit`, `stop`, `interrupt` - twelve variants total, nothing named `notification`.

Tested the same safe way as the rest of this section (isolated scratch `CODEX_HOME`, a copy of
`auth.json` only, the real `~/.codex/hooks.json` never touched): spawning is gated behind the
`multi_agent_v2` feature flag (off by default; confirmed accepted by `-c features.multi_agent_v2=true
--strict-config` with no "unknown field" error, unlike several guessed `subagents.*`/`tools.*` keys
that were rejected). With a throwaway `hooks.json` wiring `SubagentStart`/`SubagentStop` to a
marker-writing script and `codex exec -c features.multi_agent_v2=true --dangerously-bypass-hook-trust
--dangerously-bypass-approvals-and-sandbox` asked to use `spawn_agent` to run a real shell command
in a child agent and wait for it:

- `SubagentStart` fired with `{"session_id", "turn_id", "transcript_path", "cwd",
  "hook_event_name": "SubagentStart", "model", "permission_mode", "agent_id", "agent_type": "default"}`
  - `agent_id` is a **different** thread id from the parent `session_id`, confirming a genuinely
  separate child thread, not the parent relabeled.
- `SubagentStop` fired with the same shape plus `agent_transcript_path` (a **second, distinct**
  rollout file from the parent's own `transcript_path`) and `last_assistant_message:
  "hello-subagent-mat-t100"` - the exact text the child agent's own transcript produced, verified by
  the separate transcript path rather than trusting the parent's self-reported prose (the parent, in
  an earlier run with `multi_agent_v2` left off and no `spawn_agent` tool actually available, had
  fabricated an identical-looking "ran it, here's the output" answer with zero real tool call behind
  it - the two-file-paths-plus-marker check is what rules that false positive out here).
- Every field name is Claude's own vocabulary verbatim (`hook_event_name`, `session_id`,
  `last_assistant_message`, `stop_hook_active`), same convention already confirmed for Codex's other
  five events.

**CONFIRMED-NOT-SUPPORTED (added by MAT-T100, 2026-11-06): `Notification`.**

Not merely untested - ruled out. The internal `HookEventName` enum above is exhaustive (it is the
literal set the app-server protocol schema and the hook dispatcher both serialize against) and has
no `notification` variant under any name. Empirically, wiring a throwaway `Notification` key into
the same scratch `hooks.json` alongside the working events above produced zero errors at load time
(Codex silently accepts and just never fires an unrecognized event key) and the marker script for it
was never invoked across every test run in this ticket. The closest real analog is `permissionRequest`
(fires around an approval decision, which is conceptually what Claude's `Notification` covers -
"the agent is waiting on you") - also in the enum, also wired as a throwaway hook here, but still
**UNVERIFIED**: every attempt to force an approval prompt in non-interactive `codex exec` (default
policy, `-c approval_policy=on-request -s workspace-write`) was auto-rejected by a lower-level
Windows sandbox/execution-policy check (`Rejected("... rejected: blocked by policy")`) before any
approval decision was ever reached, so `permissionRequest` itself was never actually observed firing
in this session - a `--approve-for-me` run or an interactive (non-`exec`) session would be needed to
exercise it, left as a follow-up rather than guessed at.

### Plugin system and skill-directory correction (added by MAT-T98, 2026-11-06)

MAT-T93/MAT-T95 had assumed Codex's plugin marketplace (`codex plugin ...`) was the one real
extensibility surface and that `$CODEX_HOME\skills` held only an internal `.system` cache. MAT-T98
took the harder second look the follow-up ticket asked for, using the real, already-installed Codex
CLI on this machine (`codex-cli 0.153.4`) rather than guessing from `--help` text alone.

**What a Codex plugin actually is** - read `codex plugin --help`, the real bundled plugin manifests
under `~/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/*/.codex-plugin/plugin.json` (e.g.
`codex-app-tools`, `browser`), and the plugin-creator skill's own `plugin-json-spec.md` reference. A
`plugin.json` manifest is pure packaging around exactly three primitives, nothing else:
- `skills` - a path to `SKILL.md` folders, model-interpreted by description match, same mechanism as
  the Kimi/agy branches already in this file.
- `hooks` - lifecycle event wiring (the `browser` plugin wires `Interrupt`/`SubagentStop`/`Stop` to
  an MCP-tool hook type), not a user-facing command.
- `mcpServers` - a real local MCP server exposing tool calls the model can invoke (`codex-app-tools`
  wraps one), harness-dispatched once the model decides to call it - but still the model's judgment
  call, never a literal user-typed `/name` the harness parses deterministically the way a Claude
  Code command file is.

**No plugin was built.** A plugin only adds marketplace registration overhead (`marketplace.json`,
`[marketplaces.*]`/`[plugins."name@marketplace"]` entries in `config.toml`, versioning, `interface`
metadata for the plugin gallery) around the `skills` mechanism that turns out to already work
directly (next point) - exactly the "don't force a heavyweight, fragile mechanism for marginal gain"
case the follow-up ticket allowed for. The MCP-`mcpServers` path is real tool dispatch, but building
and registering a custom MCP server, then confirming whether Codex's interactive client additionally
surfaces an MCP server's `prompts/list`/`prompts/get` capability (the one MCP primitive actually
designed for user-invocable templated commands - present in the MCP SDK code bundled inside Codex's
own `codex-app-tools` plugin, `server.mjs`) as a literal typed `/name`, would require a real
interactive TUI session with a custom server running - not safely exercisable in a non-interactive
sandboxed session the way the rest of this file's tests are. Documented here as a genuinely open,
confirmed-possible path for whoever next has an interactive terminal to check; not forced.

**CORRECTION - `$CODEX_HOME\skills` is NOT limited to the `.system` cache.** A plain,
non-`.system`-prefixed `skills\<name>\SKILL.md` dropped there directly (no plugin, no marketplace)
IS auto-discovered and invoked. Confirmed twice:
1. An isolated scratch `CODEX_HOME` (copy of `auth.json` only, same safe-testing convention as the
   rest of this file) with one probe skill (`description`: "use this whenever the user's message is
   exactly 'run the probe'"). `codex exec --dangerously-bypass-approvals-and-sandbox "run the
   probe"` replied "I'm using the mat-t98-probe skill to run the diagnostic," read the file itself
   via its own `exec`/shell tool (a real `Get-Content` call, not a harness auto-injection), and then
   answered exactly `MAT-T98-SKILL-PROBE-OK` as instructed.
2. End-to-end against the **real, live** `$CODEX_HOME` after `render-abilities.ps1`'s new Codex
   branch (see that script) rendered the real ability catalog into `~/.codex/skills/<name>/SKILL.md`:
   `codex exec --sandbox read-only "/qq what is 2+2"` picked the real `qq` skill on its own ("I'm
   using the qq skill for a direct answer"), read `~/.codex/skills/qq/SKILL.md` via its own shell
   tool, and answered `4` directly - exactly the ability's intended behavior, with no prompting
   beyond the literal `/qq ...` text a user would actually type.

This is the same tier of mechanism as the Kimi/agy branches (model-interpreted from a description,
not a deterministic slash parser - so it still doesn't make the summary table's `$ARGUMENTS` row or
anything else "CONFIRMED-WORKING" as a true native command parser), but it is strictly better than
the AGENTS.md-embedded catalog text it was assumed to be the only option: it costs nothing in
context until a skill's description actually matches, rather than being read in full every session.
`render-abilities.ps1` now renders portable (non claude-only) abilities both ways: into
`$CODEX_HOME\skills\<name>\SKILL.md` (the real, working mechanism) and still into
`shared\codex-command-catalog.md` (kept as the human-readable index and AGENTS.md's documented
pointer target).

**`$ARGUMENTS` skill-body substitution - CONFIRMED-NOT-SUPPORTED, live-tested.** The same `/qq what
is 2+2` run above is direct evidence: the shell-read `SKILL.md` content printed in Codex's own
transcript still showed the raw, unreplaced literal text `/qq $ARGUMENTS was typed directly by the
user...`, and the model resolved "what is 2+2" out of the conversation itself to answer `4` - the
same model-activated-with-no-harness-substitution pattern already confirmed for agy, not Kimi's real
substitution layer. The placeholder is left literal in the rendered Codex skill bodies for now (it
resolved correctly in this test regardless); revisit with agy's "rewrite to plain English" treatment
if a harder ability's Codex rendering ever reads badly with it literal.

### `claude-only` abilities: real vs. unbridgeable Codex equivalents (added by MAT-T98, 2026-11-06)

Of `shared/abilities/*.md`, exactly two non-template abilities and one template are `claude-only`:
`allocate`, `research`, and the `member-contact` template behind the per-org-member commands.
MAT-T98 checked each against MAT-T100's `spawn_agent`/`wait_agent`/`send_message`/`followup_task`/
`close_agent`/`list_agents` (`multi_agent_v2`) finding and against `codex --help`'s own
`agents`/`queue`/`resume` subcommands, to see which gap is a real, bridgeable capability question
and which is architecturally a different problem no feature flag fixes.

- **`/allocate` - a real, if experimental and incomplete, Codex equivalent exists.** This ability's
  core mechanism (spawn N parallel subagents, each works a ticket, foreground, in this same session)
  is architecturally the same shape as MAT-T100's `spawn_agent` family - a genuine nested mid-turn
  child thread, not a stub. Recorded in `allocate.md`'s new `codex-equivalent: multi_agent_v2` /
  `codex-equivalent-note` frontmatter (rendered into `codex-command-catalog.md`'s `/allocate` entry
  as a distinct "confirmed-possible, not wired in automatically" block, never folded into a flat
  "unavailable"), with three honest caveats checked against this machine's real `codex features
  list`, not assumed: (1) `multi_agent_v2`'s *stage* is `stable` but it ships **OFF by default**
  (needs an explicit, user-unapproved `-c features.multi_agent_v2=true`) - the ticket's own
  instruction to distinguish a stability *label* from an actual opt-in default is the reason this is
  presented as "confirmed-possible," never as drop-in parity; (2) whether `spawn_agent` exposes a
  per-child **model-selection** parameter (this ability picks sonnet/opus per ticket from the
  Orchestrator's own `model:` line) is unconfirmed - MAT-T100's observed `SubagentStart` payload only
  carried `agent_type: "default"`, no `model` field, and `codex app-server generate-json-schema`
  (run under `-c features.multi_agent_v2=true`) has no `SpawnAgent` schema to check at all, because
  it's a model-facing tool, not an app-server RPC the schema generator covers; (3) Kimi/agy still
  have no confirmed equivalent of any kind, so marking `/allocate` portable would be uneven across
  non-Claude CLIs rather than Codex-specific. Nothing was silently wired in; this is a documented,
  caveated path for a future ticket to pick up once a user opts into `multi_agent_v2` and someone
  confirms per-child model selection.
- **`/research` and `member-contact` - genuinely unbridgeable on Codex today, confirmed rather than
  assumed.** Both need to reach a session on a **different org member's own login** (a separate
  top-level CLI process started via `orchestrator org start <repo> <who>`), not a child of the
  current session - so `multi_agent_v2`'s nested-child mechanism is the wrong primitive here by
  construction (MAT-T100 already noted `spawn_agent` is architecturally distinct from Codex's
  separate top-level-session `agents`/`app-server` subsystem; this ticket confirms the distinction
  matters in practice for these two abilities specifically, not just as a theoretical aside). That
  separate subsystem is real, though, and more solid than `multi_agent_v2` in one sense - no feature
  flag needed at all, `codex features list` doesn't even gate it: `codex agents` (browse every
  session on "the shared local app-server daemon"), `$CODEX_HOME/session_index.jsonl` (the same
  session list as a plain, scriptable file), and `codex queue --thread <uuid|name> --message <text>`
  (push a message into an existing session from outside it, found via `codex queue --help`) are all
  stable top-level `codex` subcommands today, architecturally the right shape for "list other
  sessions" + "message one directly." But "the shared local app-server daemon" is scoped to one
  `CODEX_HOME`/one login - it has no path to a session running under a *different* org member's own
  separate login the way these two abilities need. So this is a confirmed real primitive for a
  narrower, different feature nobody has asked for (same-login, cross-window messaging), not a
  bridge for the cross-login gap `research`/`member-contact` actually have. Both abilities' frontmatter
  now carries a `codex-equivalent-note` recording this precisely (and explicitly warning a future
  reader off the `multi_agent_v2` red herring), but `claude-only: true` stays as-is for both -
  correctly, not just cautiously.

**MAT-T103 addendum (2026-11-06): the gap is more fundamental than `SendMessage` alone.** Reading
`MindAttic.Orchestrator`'s own source (not just the CLI surface checked above) found that
`orchestrator org start <repo> <who>` - the half of `/research` that starts the actual work on
another member's login - is itself hardcoded to a Claude session: `OrgStartCommand` never passes
`--provider`, `StartCommand.Settings.Provider` defaults to `"Claude"`, and its `--account` login path
explicitly refuses any other provider ("`--account is a Claude login: {provider} has none`",
`Program.cs`). So there is no cross-CLI "the work gets done under their own Codex/Kimi/agy" path at
all yet, independent of the notify-back question. The final "tell the asker" step does have a
complete, generic, async substitute that needs no new code - any CLI can poll the research ticket
with `tickets ticket show <ID> --json` for its closed-with-note state, which `research.md`'s own
instructions already produce. Full breakdown (which part is a confirmed implementation gap, which
part is genuinely architecturally impossible, and which part is already a working generic
equivalent): **docs/claude-only-abilities.md**.

## Kimi

**UPDATE (MAT-T98, 2026-11-06): resolved from Kimi's own source, after the live-test path below
remained blocked.** No funded/logged-in Kimi account became available this round either, so instead
of repeating the live-call attempt, this round read Kimi Code's actual bundled JavaScript straight
out of its own executable - the same strategy MAT-T100 used against `codex.exe` (extracting its
`HookEventName` enum and UI strings) rather than guessing from a live call.

**Methodology**: `kimi.exe` (found at `C:\Users\<user>\.kimi-code\bin\kimi.exe`, confirmed via
`where kimi`) is a ~124 MB PE32+ Windows executable - a Node.js "single executable application"
bundle, not a native Rust/Go binary (no `strings` tool was available, so a small Python script read
the file in 4 MB chunks and pulled out every printable-ASCII run of 6+ characters, a cheap
poor-man's `strings`). The embedded JS is bundled (esbuild-style, module paths rewritten to
`//#region ../../packages/agent-core/...` and `.../agent-core-v2/...` comments - two parallel
near-identical copies of the same framework, apparently an in-progress "v2" migration) but **not
aggressively minified**: real statement-per-line formatting, real (if shortened, `$1`/`$2`-suffixed)
variable names, and original comments survive, so entire function bodies could be read directly by
anchoring on a known string (e.g. `"async runPreToolUse(ctx) {"`) and dumping the surrounding bytes,
exactly like reading a lightly obfuscated but otherwise intact source file.

### `PreToolUse` deny enforcement - CONFIRMED-WORKING FROM SOURCE

Kimi's hook contract is, in the literal field-name sense, a verbatim copy of Claude Code's own -
down to the exact schema names:

```js
// packages/agent-core/src/session/hooks/runner.ts (and the agent-core-v2 mirror, byte-identical
// apart from `$1`-suffixed names from the duplicate bundle copy)
HookSpecificOutputSchema = preprocess((value) => isRecord(value) ? value : void 0, looseObject({
    message: OptionalStringSchema,
    permissionDecision: unknown().optional(),
    permissionDecisionReason: unknown().optional()
}).optional());
HookJsonOutputSchema = looseObject({
    message: OptionalStringSchema,
    hookSpecificOutput: HookSpecificOutputSchema
});
```

The hook child process is spawned with `child_process.spawn(command, ...)`, fed the JSON input on
stdin, and its exit code/stdout are turned into a result by `resultFromExitCode(exitCode, stdout,
stderr)`:

```js
function resultFromExitCode(exitCode, stdout, stderr) {
    if (exitCode === 2) {
        const message = stderr.trim();
        return { action: "block", message, reason: message, stdout, stderr, exitCode };
    }
    const structured = exitCode === 0 ? structuredOutput(stdout) : void 0;
    if (structured?.action === "block") return { action: "block", message: ..., reason: ..., ... };
    ...
}
```

i.e. Kimi honors **both** of Claude's own documented hook-output conventions verbatim: a plain
`exit 2` with the reason on stderr (the "simple" protocol), or `exit 0` plus JSON on stdout shaped
like `{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "..."}}`
(the "advanced" protocol) - the JSON-parsing helper does exactly
`if (hookSpecificOutput?.permissionDecision !== "deny") return result; return { action: "block",
reason: hookSpecificOutput.permissionDecisionReason, ... };`.

That `{action: "block", reason}` result is not merely logged - it genuinely short-circuits the real
tool call. The tool-execution path is a middleware chain (`onBeforeExecuteTool.register(name, async
(ctx, next) => {...})`) and the hook's wiring is:

```js
registerToolHooks(toolExecutor) {
    this._register(toolExecutor.hooks.onBeforeExecuteTool.register("externalHooks", async (ctx, next) => {
        const reason = await this.runPreToolUse(ctx);
        if (reason !== void 0) {
            ctx.decision = { block: true, reason };
            return;              // <-- next() is never called - the tool body never runs
        }
        await next();            // <-- only reached when no hook blocked
    }));
    ...
}
```

`runPreToolUse(ctx)` itself is `return block?.reason;` from `this.runner.triggerBlock("PreToolUse",
{...})`, so a non-`deny` result (or no hooks matching at all) yields `reason === undefined` and
`next()` runs the real tool; a `deny` result yields a truthy `reason`, `ctx.decision = {block:true,
reason}` is set, and `next()` - the actual tool execution continuation - is **never invoked**. This
is as close to a live confirmation as static analysis gets: the control-flow structure itself proves
a `deny` result prevents the real tool from ever executing, it isn't just surfaced as a warning.

`~/.kimi-code/config.toml`'s `[[hooks]]` TOML block (the thing `install-hooks.ps1` already repoints
at the shared `pace-gate.py` path - see "What was confirmed" below) feeds this exact mechanism: it's
read via `this.config.get(HOOKS_SECTION)`, merged with any plugin-contributed hooks, and indexed by
event name (`indexHooks`) into the same `byEvent` map `triggerBlock`/`trigger` read from.

### Full hook-event enum and other events - CONFIRMED-WORKING FROM SOURCE

Kimi's own exhaustive event-name list (`packages/agent-core/src/session/hooks/types.ts`,
`HOOK_EVENT_TYPES`) is **larger** than Claude's or Codex's:

```js
HOOK_EVENT_TYPES = [
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionResult",
    "UserPromptSubmit", "Stop", "StopFailure", "Interrupt", "SessionStart", "SessionEnd",
    "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Notification"
];
```

A real `.trigger(...)`/`.fireAndForgetTrigger(...)` call site was found for every one of these
except `Interrupt` and `StopFailure` (zero occurrences of either as a literal event-name argument -
genuinely `UNVERIFIED`, not assumed working just because they're in the enum):

- `PostToolUse`/`PostToolUseFailure`: `notifyPostToolUse(ctx)` fires one or the other (fire-and-forget,
  non-blocking, matching Claude's own convention for this event) right after `onDidExecuteTool`.
- `Stop`: `this.runner.triggerBlock("Stop", {...})` inside `runStop(ctx)`, wired into the agent's
  step-loop finish handler exactly like `PreToolUse` - a `Stop` hook can likewise block/continue the
  turn (`this.stopHookContinuationUsed = true` when it does).
- `SessionStart`/`SessionEnd`: `triggerSessionStart(source)`/`triggerSessionEnd(reason)`, each a thin
  `this.hookEngine.trigger(...)` call.
- `UserPromptSubmit`: `runPromptSubmitHook(ctx)` -> `this.runner.trigger("UserPromptSubmit", {...})`;
  a block result sets `ctx.block = true` before the prompt is submitted to the model.
- `SubagentStart`/`SubagentStop`: `triggerSubagentStart`/`triggerSubagentStop`, firing around Kimi's
  own subagent spawn/stop lifecycle (`emitSubagentStarted`, `fireAndForgetTrigger("SubagentStop", ...)`).
- `PreCompact`/`PostCompact`: `triggerPreCompactHook`/`triggerPostCompactHook`, wired into
  `registerFullCompactionHooks`'s `onWillCompact` middleware.
- `PermissionRequest`/`PermissionResult`: fired around the interactive tool-approval flow
  (`registerPermissionHooks`, subscribing to `permission.approval.requested`/`.resolved` events).
- **`Notification`**: unlike Codex (`CONFIRMED-NOT-SUPPORTED` - no such variant exists in its enum
  at all), Kimi's `Notification` is real and does fire: `fireNotificationHook(notification)` calls
  `this.agent.hooks?.fireAndForgetTrigger("Notification", {matcherValue: notification.type,
  inputData: {sink: "context", notificationType, title, body, severity, ...}})`, and a separate
  `notifyTaskNotification(ctx)` also fires `"Notification"` for background-task events. Classified
  `CONFIRMED-WORKING (source)`, not "exists in the enum so probably works" - an actual call site with
  a real payload shape was found, the same bar used for the other confirmed events above.

None of this is a substitute for an actual live `kimi -p` run with a real tool call reaching the
hook - no process was spawned, no JSON actually crossed a real stdin/stdout pipe this round. It is,
however, a strictly stronger form of evidence than the inconclusive live attempt below: that attempt
never got far enough to observe *any* behavior; this one reads the exact logic that would execute if
it had. The summary table marks every Kimi row above `(source)` rather than bare `CONFIRMED-WORKING`
for this honest reason.

### $ARGUMENTS skill-body substitution - CONFIRMED-WORKING FROM SOURCE (NOT a category error)

The ticket's own working hypothesis going in was that `$ARGUMENTS` might be "a Claude-slash-command-
specific concept with no Kimi equivalent." Source reading shows the opposite: Kimi deliberately
re-implements the same substitution convention.

```js
// packages/agent-core-v2/src/app/skillCatalog/registry.ts (agent-core/src/skill mirrors this)
function expandSkillParameters(body, rawArgs, context) {
    const tokens = tokenizeArgs(rawArgs);          // whitespace-split, quote-aware (e.g. -m "fix bug")
    ...
    content = content.replaceAll(/\$ARGUMENTS\[(\d+)\]/g, (_m, indexText) => tokens[Number(indexText)] ?? "");
    ...
    return content.replaceAll("$ARGUMENTS", escapeXmlTags(rawArgs));
}
// renderSkillPrompt(skill, rawArgs) { return expandSkillParameters(skill.content, rawArgs, {...}); }
```

and, from the same bundle's own in-code comment: `* Placeholder syntax ($ARGUMENTS, $0, $name, etc.)
is modelled after common conventions` - an explicit acknowledgment this is deliberately
Claude-slash-command-compatible, not an independent or absent mechanism. A companion function,
`skillArgumentNames(metadata)`, reads an `arguments:` frontmatter field to support named `$NAME`
placeholders too, and a trailing fallback (`if (!body.includes("$ARGUMENTS") && args.length > 0)
return `${replaced}\n\nARGUMENTS: ${args}``) appends the raw args as a visible line when a skill body
has no placeholder at all, so argument text is never silently dropped either way.

`rawArgs` is populated from two paths, both of which land in this same function:
- An explicit `/name args` invocation (Kimi supports slash-command-style dispatch, with its own
  `argumentHint`/`argument-hint` concept mirroring Claude's - found alongside a generic editor
  `setArgumentHints` call).
- The model's own choice, when it decides on its own to invoke a skill: the model-facing tool schema
  for doing so carries `args: string().optional().describe("... It is split on whitespace (quotes
  group a token) and expanded into the skill's placeholders ($NAME, $1, $ARGUMENTS) ... Omit it only
  when there is nothing to pass.")` - i.e. Kimi explicitly instructs the model to supply the relevant
  argument text itself when invoking a skill that wasn't triggered by a literal slash command.

Both paths substitute for real before the model ever reads the rendered body. Omitting `args`
(nothing to pass) substitutes an empty string rather than leaving `$ARGUMENTS` literal - e.g.
`renderSkillPrompt(skill, "")` is the exact call used for an automatically-triggered
`plugin_session_start` skill reminder.

**Consequence for this repo**: `render-abilities.ps1`'s Kimi branch (which had, earlier in this same
round, been changed to apply agy's "rewrite `$ARGUMENTS` to plain-English guidance" treatment to Kimi
too, "by analogy" with agy - see the agy section's own `$ARGUMENTS` write-up) was corrected back:
Kimi's branch now renders `$ARGUMENTS` **literally**, unchanged, exactly like the Claude branch does,
because Kimi's own harness will substitute it for real. The analogy to agy was the wrong call - the
two CLIs' skill systems look identical on the surface (same `SKILL.md` directory shape, same
model-activation idea) but Kimi added a real slash-command-style argument-substitution layer on top
that agy does not have. Live `~/.kimi-code/skills/*/SKILL.md` files were re-rendered with the fix
applied (confirmed by spot-checking `bughunt/SKILL.md`: it now contains literal `` `$ARGUMENTS` ``
again, not the "the rest of the user's own message" rewrite).

---

### Original live-test attempt (MAT-T94, kept for the record)

**Attempted but inconclusive** - the empirical `PreToolUse`-deny test could not be completed this
session, for reasons unrelated to the hook wiring itself (see below). Document honestly rather than
guessing: this is UNVERIFIED, not CONFIRMED either way.

What was confirmed:

- `~/.kimi-code/config.toml`'s `[[hooks]]` block (`event = "PreToolUse"`, `command = 'python "..."'`,
  `timeout = 330`) is the only hook Kimi has wired at all today - no other event has an entry.
- `install-hooks.ps1` repointed that one `command` string's path (a plain substring swap on the raw
  TOML text, since the value is just a quoted string) to the shared
  `D:/Projects/MindAttic/mindattic-agent-standard/shared/hooks/pace-gate.py` path; the result was
  re-validated as parseable TOML (Python `tomllib.load`) and `kimi doctor config` reported it valid.

What blocked the deny test: no Kimi process was running on this machine, so (unlike Codex) the
live `~/.kimi-code/config.toml` itself was edited directly for the test (backed up first,
byte-verified identical, restored after, byte-verified identical again - confirmed clean with
`cmp` before this doc was written). The `[[hooks]]` `command` was swapped to a throwaway
unconditional-deny script and `kimi -p "..."` (non-interactive prompt mode) was run repeatedly to
try to trigger a tool call:

- The default model (`kimi-code/k3`, provider `managed:kimi-code`) fails immediately in print mode
  with `auth.login_required: OAuth provider "managed:kimi-code" requires login before it can be
  used` - its OAuth session isn't available to `-p` mode on this machine.
- The only other configured model (`moonshot-cn/kimi-k2.7-code`, a direct API key, no OAuth) was
  tried instead (`kimi -p ... -m moonshot-cn/kimi-k2.7-code`). Every attempt stalled for minutes
  with zero output, including a prompt that needed no tool call at all ("just reply pong"), then
  eventually surfaced `error: failed to run prompt: provider.rate_limit: 429 ... account ... is
  suspended due to insufficient balance, please recharge your account` - a billing problem on that
  API key, not a hook problem. Confirmed unrelated to the hook edit specifically: the identical
  stall/429 reproduced after reverting `config.toml` back to its pre-test (post-`install-hooks.ps1`)
  state, i.e. it happens with or without the throwaway deny hook in place.
- No tool call was ever reached in any Kimi test run (the throwaway hook's own "invoked" marker
  file, which the Codex test proved the same technique reliably catches, never appeared), so there
  is literally no data on whether Kimi's `PreToolUse` hook runner honors `deny` - not "it doesn't
  work," just never exercised.

**Follow-up needed at the time** (left for whoever next has a funded Kimi model or a machine where
the `managed:kimi-code` OAuth session is valid in print mode): rerun the same throwaway-deny-hook
technique used for Codex (see that section) against a working `kimi -p` invocation, watching for
the marker file plus whether the shell command Kimi was asked to run actually executed or was
blocked. All other Kimi events (`PostToolUse`, `SessionStart`, `UserPromptSubmit`,
`SubagentStart`/`Stop`, `Notification`) were UNVERIFIED too, for the same reason, and were not even
wired in `config.toml` at the time - whether Kimi's hook runner supports them was a separate open
question from whether it honors `deny`. **Superseded by the source-analysis sections above**: that
live follow-up is still worth doing someday as the strictly strongest possible confirmation, but is
no longer blocking - the control-flow/schema evidence above is about as conclusive as it gets short
of an actual funded run.

## agy (Google Antigravity CLI)

Config shape discovered empirically 2026-11-06 (MAT-T96), by running `agy -p "say hello"`
non-interactively in a throwaway scratch directory and inspecting what appeared under
`%USERPROFILE%` afterward, then reading agy's own bundled `agy-customizations` skill docs
(`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/*.md`).

**Real config shape (previously unknown - MAT-T93/MAT-T96 had guessed `~/.agy`/`~/.antigravity`,
neither of which exists):**

- **Global customization root: `%USERPROFILE%\.gemini\config\`** - agy's own docs call this
  "Global Configuration (Machine-Local)". This is where `hooks.json`, `skills/<name>/SKILL.md`,
  `skills.json`, `plugins.json` and `mcp_config.json` all live for machine-wide scope. A
  project-local equivalent also exists (`.agents/` at a repo root, walked up from cwd) but was not
  used here - everything below targets the global root so it applies to every MindAttic repo agy
  touches.
- agy's own CLI runtime/data home is a **separate sibling directory**,
  `%USERPROFILE%\.gemini\antigravity-cli\` (conversation "brain" transcripts, logs, cache, and its
  own tiny `settings.json` - which, after the bootstrap run, held only `{"trustedWorkspaces": [...]}`,
  nothing hook- or skill-related).
- `%USERPROFILE%\.gemini\settings.json` (one level up from both of the above) is a **third, unrelated
  file**, already in use by Gemini CLI itself for its own hooks, in a different shape
  (`BeforeTool`/`AfterAgent` event names). Do not confuse it with agy's `hooks.json` - they are
  different files with different event vocabularies that happen to share a parent directory.
- `%APPDATA%\Antigravity` is the separate Antigravity IDE (Electron app cache) - unrelated to the
  `agy` CLI's hook/skill system.
- **Hooks**: a standalone `hooks.json` (not nested inside `settings.json`, unlike Claude). Shape
  differs from Claude/Codex at the top level: each key is an arbitrary **hook name** (not an event
  name), mapping to an object of event arrays. Tool-scoped events (`PreToolUse`, `PostToolUse`) use
  the same `{"matcher": "...", "hooks": [{"type": "command", "command": "...", "timeout": N}]}`
  wrapper Claude/Codex already use. Non-tool events (`SessionStart`, `PreInvocation`,
  `PostInvocation`, `Stop`) are **flat arrays of handler objects, no matcher wrapper**. `timeout` is
  in seconds (matches the convention already used for Claude/Codex). Hook stdin/stdout is
  camelCase JSON (`toolCall.name`, `conversationId`, etc.), not Claude's `tool_name`/`session_id`
  shape.
- **Skills**: `skills/<name>/SKILL.md` under the same customization root, with `name` +
  `description` YAML frontmatter - identical shape to Kimi's skill convention.

**What got wired (this ticket):**

- `%USERPROFILE%\.gemini\config\hooks.json` - `PreToolUse -> pace-gate.py`, `Stop ->
  context-gate.py agy` (the "agy" argv, same pattern as Codex's "codex" argv), both pointed at the
  canonical mirror path `D:/Projects/MindAttic/mindattic-agent-standard/shared/hooks/` per MAT-T94's
  new layout.
- `%USERPROFILE%\.gemini\config\skills\<name>\SKILL.md` - the full non-claude-only portable ability
  catalog (18 abilities) rendered by `render-abilities.ps1`'s new agy branch (MAT-T96, filling in
  the extension point MAT-T95 left), mirroring its Kimi branch exactly.

**CONFIRMED-WORKING** (observed directly):

- `%USERPROFILE%\.gemini\config\hooks.json` is discovered and fired at the global (all-workspaces)
  level - no project `.agents/` folder needed. Verified with a disposable probe hook script that
  wrote stdin to a marker file: both `PreToolUse` (on a `run_command` tool call) and `Stop` (at
  turn end) fired, carrying exactly the JSON shapes agy's own docs describe.
- The real wiring (`pace-gate.py` / `context-gate.py agy`) ran cleanly end-to-end: a tool-triggering
  prompt (`agy -p "Run the shell command: echo ..."`) completed normally through both hooks, no
  error, no hang, no behavior change - both scripts no-op by design (`context-gate.py`'s
  `provider != "Claude"` early exit; `pace-gate.py` finds no `tool_name` key in agy's differently
  shaped payload and falls through its default/no-op path), confirmed both by watching the live
  `agy` run and by replaying the same JSON shape directly through each script's stdin.
- `%USERPROFILE%\.gemini\config\skills\<name>\SKILL.md` is discovered and genuinely **activated by
  the model**: a disposable probe skill instructing "respond with the exact phrase BANANA-PROBE-77"
  was picked up by a matching `agy -p` prompt and the exact phrase came back verbatim. The full
  18-skill rendered catalog (real abilities, not the probe) also loaded without error and `agy -p`
  continued to answer normally (`/qq what is 2+2` -> `4`).
- **GOTCHA**: agy's hook command parser does **not** reliably handle a double-quoted path argument
  on Windows the way Claude Code/Codex do. `"command": "python \"D:/.../pace-gate.py\""` failed -
  the quote character ended up folded into a bogus path concatenated onto the `hooks.json`
  directory (`C:\Users\...\.gemini\config\"D:\...\pace-gate.py"`), i.e. agy appears to treat a
  leading `"` as defeating its "is this absolute" check and falls back to resolving the path
  relative to the hooks.json directory. The identical command **unquoted**
  (`"command": "python D:/.../pace-gate.py"`) works, since the shared/hooks path has no spaces.
  Keep agy's hook commands unquoted as long as that holds.

**CONFIRMED-WORKING (added by MAT-T99, 2026-11-06):**

- **`PreToolUse` `{"decision": "deny", "reason": "..."}` genuinely blocks a real agy tool call
  end-to-end.** A disposable unconditional-deny hook (unquoted command, per the GOTCHA above) was
  wired into the real `~/.gemini/config/hooks.json`; `agy -p "Run the shell command: echo
  should-be-blocked"` returned "The command execution was blocked by a pre-tool hook: tool call
  denied by pre-tool hook: MAT-T99-PROBE-DENY" - not a silent ignore. The probe's own marker file
  independently confirmed the hook ran, carrying the documented `toolCall.name` /
  `toolCall.args.CommandLine` / `conversationId` payload shape. The real `pace-gate.py`/
  `context-gate.py agy` wiring was backed up before this edit and restored + byte-diff-verified
  identical afterward.
- `SessionStart`, `PreInvocation`, `PostInvocation` all fired on a single plain prompt, each with
  the exact flat-array, no-matcher payload shape agy's own `hooks.md` documents.
- Project-local `.agents/hooks.json` discovery works the same as the global `~/.gemini/config/`
  root: a scratch directory's `.agents/hooks.json` `SessionStart` hook fired when agy was run with
  that directory as cwd.

**UNVERIFIED:**

- Whether `pace-gate.py`'s real pacing/slot-holding logic (not just its current no-op fast path)
  would behave correctly if it were ever taught to recognize agy's payload shape - only the no-op
  path was exercised.

**CONFIRMED (added by MAT-T98, 2026-11-06): no harness substitution of a skill's `$ARGUMENTS`
placeholder - the model infers the argument from the user's own message instead.**

- Tested directly against a real `agy -p` invocation (not inferred): a disposable probe skill was
  written to `~/.gemini/config/skills/argprobe/SKILL.md` (frontmatter `description` told the model
  to activate it whenever the user's message starts with the word `argprobe`) with a body containing
  a literal `$ARGUMENTS` token, the same way a Claude slash command's body would.
- **First probe** - body: "respond with the exact phrase MAT-98-ARG-PROBE followed immediately by
  whatever arguments were given ... MAT-98-ARG-PROBE $ARGUMENTS". Run as
  `agy -p "argprobe hello-world-123"` from a throwaway scratch directory (no project `.agents/`
  folder, so only the global skill applied). Output: exactly `MAT-98-ARG-PROBE hello-world-123` -
  the right answer, but this alone doesn't distinguish harness substitution from the model simply
  reading "hello-world-123" out of its own conversation context.
- **Second probe (the one that settles it)** - rewrote the body to ask the model to stop answering
  the user's request and instead quote back, character-for-character, the literal 30 characters of
  its own instruction text immediately surrounding a `TOKEN-START[$ARGUMENTS]TOKEN-END` marker, then
  say `LITERAL` if the five characters `$ARGUMENTS` were still literally present there or `REPLACED`
  if something else (e.g. actual argument text) appeared instead. Run as
  `agy -p "argprobe zzz-canary-998877"`. Output:
  ```
  TOKEN-START[$ARGUMENTS]TOKEN-END
  LITERAL
  ```
  The model's own context still contained the raw, unreplaced `$ARGUMENTS` string - `zzz-canary-998877`
  never appeared in the skill body itself at all, confirming no harness ever touched it.
- Conclusion: agy's skills are purely model-activated context, exactly as `BANANA-PROBE-77` (MAT-T96)
  already proved for activation-without-arguments. There is no slash-command-style harness expansion
  of `$ARGUMENTS` before the model sees a skill body (unlike Claude Code, where the harness expands
  it before the model's turn even starts). When the first probe worked, it worked because the model
  read the trailing text of the user's own prompt and connected it to "whatever arguments were
  given" by itself - not because anything was substituted into the skill text. **CORRECTION (same
  ticket, later the same night): the analogy to Kimi below turned out to be wrong.** Kimi's skills
  share the same `SKILL.md` shape and model-activation idea, but reading Kimi's own bundled source
  (see the Kimi section above) found a genuine slash-command-style `$ARGUMENTS` substitution layer
  that agy simply does not have - the two CLIs are not architecturally identical on this specific
  point after all. Kimi's finding is now source-confirmed, not inferred by analogy from agy's.
- Probe skill removed from the live `~/.gemini/config/skills/` catalog afterward; it never shipped
  as a real ability.
- `render-abilities.ps1`'s **agy branch only** was updated as a result: a rendered skill body no
  longer carries a literal, never-substituted `$ARGUMENTS` token for agy. It's rewritten to the
  plain-English phrase "the rest of the user's own message" (readable by a model with no harness
  expansion in play), with a short note prepended to any skill whose body actually used `$ARGUMENTS`
  explaining that there's no substitution mechanism on agy and the model should read the argument
  directly from the conversation itself. (The Kimi branch was briefly given the same treatment
  before the correction above, then reverted back to rendering `$ARGUMENTS` literally - see the Kimi
  section's own `$ARGUMENTS` write-up for why.)

**CONFIRMED-NOT-SUPPORTED:**

- `~/.agy` and `~/.antigravity` as config locations - neither exists; the real global root is
  `~/.gemini/config/`.
- Double-quoted absolute paths in a `hooks.json` command string (see GOTCHA above) - unquoted only.

## Generic wakeup scheduling (MAT-T103)

Claude Code's `ScheduleWakeup` tool had been recorded above (and in AGENTS.md's cross-CLI
capability framework section) as permanently Claude-only, on the theory that "resume this CLI's
work later without the user typing continue" needs a Claude-SDK mechanism with no equivalent
elsewhere. MAT-T103 re-examined that: the actual job is just "re-invoke this CLI non-interactively
with a prompt at a future time," and Windows' own Task Scheduler (`schtasks`) can do exactly that
for any CLI, because every CLI this workspace runs ships a confirmed non-interactive mode -
**TRUE-EQUIVALENT-BUILT**, not merely a paper equivalent:

- `claude -p "<prompt>"` - confirmed via `claude --help` (`-p`/`--print` for non-interactive
  output); cwd is read directly, no separate `-C`/`--cwd` flag.
- `codex exec -C "<dir>" "<prompt>"` - confirmed via `codex exec --help` (`-C, --cd <DIR>`: "Tell
  the agent to use the specified directory as its working root").
- `kimi -p "<prompt>"` - confirmed via `kimi --help` (`-p, --prompt <prompt>`: "Run one prompt
  non-interactively and print the response"); no `-C`/`--cwd` flag, relies on the process cwd.
- `agy -p "<prompt>"` - confirmed via `agy --help` (`-p`/`--print`: "Run a single prompt
  non-interactively and print the response"); no `-C`/`--cwd` flag either, same cwd reliance.

**What was built**: `mindattic-agent-standard/schedule-wakeup.ps1`, plus its ability wrapper
`shared/abilities/schedule-wakeup.md` (`claude-only: false` - deliberately, since portability is
the entire point). Given a CLI name, a working directory, a prompt, and a delay (`-DelaySeconds`/
`-DelayMinutes`) or an absolute `-At` time, it:

1. Generates a small, self-contained wrapper `.ps1` (stored under
   `%LOCALAPPDATA%\MindAttic\ScheduledWakeups\`, not inside any repo) that `cd`s to the working
   directory, decodes a Base64-embedded copy of the prompt (sidesteps every `schtasks`/`cmd`
   quoting limit - the prompt can contain quotes or newlines with no escaping problem), invokes the
   target CLI's own non-interactive mode above, pipes all output through one explicit
   `-Encoding utf8` sink to a log file, then deletes its own scheduled task
   (`schtasks /delete /tn ... /f`) and finally itself - nothing lingers but the log.
2. Registers that wrapper via `schtasks /create ... /sc once`.
3. Defaults the log location to a `wakeup-logs` folder created as a **sibling** of the working
   directory (never inside a git-tracked checkout), and supports `-EnvOverrides 'KEY=VALUE'` for
   setting process env vars before the CLI runs (used below to point Codex at an isolated
   `CODEX_HOME`) and `-Cancel <TaskName>` to tear down a wakeup that's no longer needed.

**Confirmed end-to-end against a real CLI (2026-11-06)**, using the same isolated-`CODEX_HOME`
safe-testing convention MAT-T94/95/98/100 already established for Codex (a scratch `CODEX_HOME`
holding only a copy of `auth.json`, so the real, concurrently-used `~/.codex/hooks.json`/config was
never touched):

- Recorded the 8 pre-existing scheduled tasks on this machine (`\MindAttic\Scheduler\*` and
  `\MindAttic\UnstuckTaskbar\Logon`) before any test, as a baseline.
- Scheduled a one-shot wakeup (`-Cli codex`, a scratch working directory, `-EnvOverrides
  'CODEX_HOME=...'`, `-ExtraCliArgs '--dangerously-bypass-approvals-and-sandbox'`, delays of
  70-120 seconds across three runs) asking Codex to reply with an exact marker string.
- Each run fired on schedule, ran `codex exec` in the correct working directory under the scratch
  `CODEX_HOME` (a fresh session id each time, confirming it never touched the real login's live
  session), and the log showed Codex's own reply containing exactly the requested marker text and
  `exit code: 0`.
- The scheduled task and the wrapper script were both gone immediately after each run (re-querying
  `schtasks /query /tn <name>` returned "cannot find the file specified"; the wrapper directory was
  empty) - the self-delete worked both times, with nothing left behind but the log.
- Re-queried all scheduled tasks after testing: exactly the same 8 pre-existing tasks as the
  baseline, confirming no test task was left behind and no pre-existing task was disturbed.
- One real bug found and fixed mid-test: the first run's log file was unreadable garbage (embedded
  NULs) because the wrapper mixed `Add-Content`'s Windows-PowerShell-5.1 default ANSI encoding with
  the native `*>>` redirection operator's own default encoding for the CLI's captured output, in the
  same file. Fixed by routing every write through one explicit `-Encoding utf8` sink (`Add-Content
  -Encoding utf8` for the header lines, `... | Out-File -Append -Encoding utf8` for the CLI's own
  output and the final `schtasks /delete`); re-tested and confirmed the log reads as clean UTF-8
  throughout.

**Limitation (real, not a gap in the build)**: this is a `schtasks`-level constraint, not something
a different implementation could route around - the machine must be on and the triggering user's
Windows session logged in at fire time. Fine for same-session pacing waits and deferred follow-ups
within a normal working day; not a way to wake a fully powered-off machine.

**Not yet done**: `render-abilities.ps1` was not re-run as part of this ticket, so
`schedule-wakeup` is not yet mirrored into Codex's/Kimi's/agy's own skill directories the way other
non-claude-only abilities are - it exists as a documented `shared/abilities/*.md` source and a
working script today, with the mechanical render-and-install pass left for a follow-up (or the next
routine `render-abilities.ps1` run) to avoid touching the live `$CODEX_HOME`/`$env:LOCALAPPDATA`
skill directories and the real Claude `commands` folder while MAT-T103's other two items were being
worked concurrently in this same checkout.
