# Hook contract matrix

Per-CLI confirmed/unverified behavior for the shared lifecycle hooks
(`shared/hooks/pace-gate.py`, `shared/hooks/context-gate.py`, `shared/hooks/rl-check.py`), one
section per CLI. **Claude, Codex and Kimi rows are owned by MAT-T94** (a sibling of this ticket) and
had not landed yet when the agy row below was added by MAT-T96 - merge their rows in above/below
this one rather than overwriting it, and vice versa.

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

**UNVERIFIED:**

- Whether `pace-gate.py`'s real pacing/slot-holding logic (not just its current no-op fast path)
  would behave correctly if it were ever taught to recognize agy's payload shape - only the no-op
  path was exercised.
- Whether a `PreToolUse` hook's `"decision": "deny"` / `"ask"` actually blocks an agy tool call
  end-to-end - only the default (no hook output / implicit allow) path was exercised.
- `SessionStart`, `PreInvocation`, `PostInvocation` events (unused by the Claude/Codex wiring) -
  not exercised at all here.
- Whether `.agents/` project-local discovery (as opposed to the global `~/.gemini/config/` root
  used throughout this work) behaves identically.
- Whether a rendered skill's `$ARGUMENTS` placeholder is substituted the way a Claude slash
  command's is, or whether agy's model-activated skills receive raw arguments some other way (same
  open question `render-abilities.ps1` already notes for the Kimi branch).

**CONFIRMED-NOT-SUPPORTED:**

- `~/.agy` and `~/.antigravity` as config locations - neither exists; the real global root is
  `~/.gemini/config/`.
- Double-quoted absolute paths in a `hooks.json` command string (see GOTCHA above) - unquoted only.
