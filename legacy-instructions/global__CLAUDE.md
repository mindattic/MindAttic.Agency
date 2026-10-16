# Global Claude Code Rules

## Conversation
- A bare "do" / "do it" / "yes" from the user means "continue", "keep going", "proceed". Resume the current task without asking for clarification.

## Versioning (every MindAttic project)
- Whole-number versioning only. The package/assembly version increments by **major version** every release and nothing else: `1.0.0`, then `2.0.0`, then `3.0.0`, … Minor and patch are always `0`. Never use semver-style minor/patch bumps (no `2.6.0`, `1.5.11`). A bare integer (`<Version>3</Version>`) is acceptable when the tooling allows it; if that's illegal markup, use the `N.0.0` form. This applies to every project under MindAttic.

## Cost
- Spawn routine subagents (Explore, general-purpose search/research, mechanical fan-out) on **Sonnet** (`claude-sonnet-4-6`), not Opus, unless the task genuinely needs Opus-level reasoning. The user stays on Opus for the main thread; this only lowers the model for delegated sub-work. Pass `model: "sonnet"` on the Agent call.

## Git workflow (every MindAttic project)
- Always commit directly to the default branch (`main` or `master`). Never create a branch of any kind — no feature branches, no fix branches, no worktree branches. All work builds continuously on top of main. The only exception is an explicit user instruction to create a branch.

## Quicksave / context handoff across /clear (every MindAttic project)
- Every MindAttic repo ships a `/quicksave` slash command (renamed from `/checkpoint`, which
  collided with the built-in `/rewind` alias). The flow is **save → /clear → restore on demand**
  (Person-of-Interest "paper transcript" protocol):
  1. `/quicksave [optional emphasis note]` prints the live discussion to `.claude/quicksave.md`
     in the repo root (current task, locked decisions, state, next steps, anchors).
  2. The user runs `/clear`.
  3. On the other side, the transcript restores when the user types a **bare `do`** (a
     `UserPromptSubmit` hook, `.claude/hooks/quickload-on-do.ps1`, injects it) or runs
     `/quickload` explicitly. Either path **deletes the file** (one-shot — no residue).
- Standard files, identical in every repo: `.claude/commands/quicksave.md`,
  `.claude/commands/quickload.md`, `.claude/hooks/quickload-on-do.ps1`, `.claude/statusline.ps1`,
  a `UserPromptSubmit` hook entry + a `statusLine` entry in `.claude/settings.json` (both use
  `%CLAUDE_PROJECT_DIR%`), and `.claude/quicksave.md` in `.gitignore`. The transcript is
  gitignored and ephemeral — never commit it. When a restored transcript appears in context,
  treat it as working memory: continue the Current task without re-asking what was already
  settled.
- **Context gauge (room to spare).** `.claude/statusline.ps1` shows live context-window usage and
  escalates: green `ctx N%` → amber `[!] quicksave soon` at ≥80% → red `[!!] /quicksave NOW` at
  ≥90% (thresholds are the `$WARN`/`$CRIT` vars at the top of the script). This is a **user-facing
  nudge** — the model does not see the statusline. When it turns red, the user runs `/quicksave`
  then `/clear` while there's still budget, rather than getting force-compacted at the limit. The
  harness exposes context-% only to the statusline: no hook (PreCompact included) receives it, and
  PreCompact fires at the compaction moment with no room to spare, so this early gauge is the
  correct place for the warning.

## Tooling
- Never use Unix-only commands (`tail`, `head`, `grep`, `find`, `sed`, `awk`) in PowerShell tool calls. Use PowerShell equivalents: `tail -N` → `Select-Object -Last N`, `head -N` → `Select-Object -First N`. Use the Bash tool when POSIX syntax is needed.
- Never auto-wrap shell commands in `psst` (or any `psst -- <command>` invocation). `psst` is an attention-getter — playing the sound and firing an SMS on every CLI process completion is unwanted noise. Only invoke `psst` when the user explicitly asks for it (e.g. "run X with psst", "notify me when Y finishes via psst"). This applies to every project, including `MindAttic.Psst` itself.
