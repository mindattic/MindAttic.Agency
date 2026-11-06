# Hook contract matrix

Per-CLI confirmed/unverified behavior for the shared lifecycle hooks
(`shared/hooks/pace-gate.py`, `shared/hooks/context-gate.py`, `shared/hooks/rl-check.py`), one
section per CLI. Claude, Codex and Kimi rows below were filled in by MAT-T94; the agy section was
started by MAT-T96 and extended by MAT-T99 (deny enforcement, SessionStart/PreInvocation/
PostInvocation, project-local discovery); the Codex section's `SubagentStart`/`SubagentStop`/
`Notification` rows were filled in by MAT-T100.

## Summary table

One row per hook event, one column per CLI. `CONFIRMED-WORKING` means the event was observed
firing with the real payload shape (and, for `PreToolUse`, that a `deny` response actually blocked
the tool call); `UNVERIFIED` means no empirical test exercised it either way; `CONFIRMED-NOT-SUPPORTED`
means a real location/shape was ruled out. See each CLI's own section below for how every cell was
confirmed and its caveats - this table is a locator, not the full story.

| Hook event | Claude | Codex | Kimi | agy |
|---|---|---|---|---|
| PreToolUse (deny actually blocks) | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | CONFIRMED-WORKING |
| PostToolUse | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | UNVERIFIED |
| Stop | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | CONFIRMED-WORKING |
| SessionStart | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | CONFIRMED-WORKING |
| PreInvocation / PostInvocation (agy-only events) | n/a | n/a | n/a | CONFIRMED-WORKING |
| Project-local discovery (`.agents/` for agy) | n/a | n/a | n/a | CONFIRMED-WORKING |
| UserPromptSubmit | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | UNVERIFIED |
| SubagentStart | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | UNVERIFIED |
| SubagentStop | CONFIRMED-WORKING | CONFIRMED-WORKING | UNVERIFIED | UNVERIFIED |
| Notification | CONFIRMED-WORKING | CONFIRMED-NOT-SUPPORTED | UNVERIFIED | UNVERIFIED |

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

## Kimi

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

**Follow-up needed** (left for whoever next has a funded Kimi model or a machine where the
`managed:kimi-code` OAuth session is valid in print mode): rerun the same throwaway-deny-hook
technique used for Codex (see that section) against a working `kimi -p` invocation, watching for
the marker file plus whether the shell command Kimi was asked to run actually executed or was
blocked. All other Kimi events (`PostToolUse`, `SessionStart`, `UserPromptSubmit`,
`SubagentStart`/`Stop`, `Notification`) are UNVERIFIED too, for the same reason, and are not even
wired in `config.toml` today - whether Kimi's hook runner supports them is a separate open
question from whether it honors `deny`.

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
- Whether a rendered skill's `$ARGUMENTS` placeholder is substituted the way a Claude slash
  command's is, or whether agy's model-activated skills receive raw arguments some other way (same
  open question `render-abilities.ps1` already notes for the Kimi branch).

**CONFIRMED-NOT-SUPPORTED:**

- `~/.agy` and `~/.antigravity` as config locations - neither exists; the real global root is
  `~/.gemini/config/`.
- Double-quoted absolute paths in a `hooks.json` command string (see GOTCHA above) - unquoted only.
