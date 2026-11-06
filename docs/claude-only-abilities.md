# Claude-only abilities: precise verdicts (MAT-T103)

MAT-T93/MAT-T98's Stop-hook feedback reopened scrutiny of every ability marked permanently
Claude-only: checking only whether Codex/Kimi/agy happen to ship an identically-named SDK feature
risks writing off a need that could be rebuilt generically. MAT-T103 re-examined three such
abilities. **ScheduleWakeup** is its own item, built and documented separately in
`shared/abilities/schedule-wakeup.md`. This file records the final verdict for the other two:
cross-login messaging (`/research`, `member-contact`) and `Artifact` (claude.ai-hosted publishing).

Three labels are used, exactly as the ticket specified, with no vaguer language:

- **TRUE-EQUIVALENT-BUILT** - a generic mechanism exists (or already existed) that fully replaces
  the Claude-only one; nothing is lost.
- **PARTIAL-EQUIVALENT** - some of the need is covered generically; the rest genuinely isn't. Named
  precisely, not left as a vague "mostly."
- **CONFIRMED-ARCHITECTURALLY-IMPOSSIBLE** - a specific technical reason, not just "no SDK feature
  named this."

## 1. Cross-login messaging (`/research`, `member-contact`)

**Overall: PARTIAL-EQUIVALENT.** The mechanism has three logically separate parts, with three
different verdicts. `claude-only: true` stays correct for the ability as a whole, but for a more
fundamental and more precise reason than previously recorded (MAT-T98 only checked the notify-back
half against Codex's `spawn_agent`/`agents` subsystem; MAT-T103 checked the other half - starting
the work itself - directly in `MindAttic.Orchestrator`'s source).

### a) Starting the actual research under another member's login - Claude-only by a confirmed, explicit guard, not just an unchecked default

`/research`'s `orchestrator org start <repo> <who> --prompt <text>` is `OrgStartCommand.Execute`
(`MindAttic.Orchestrator/src/MindAttic.Orchestrator.Cli/OrgCommands.cs:360-380`), which resolves
`<who>` to a member and calls:

```csharp
new StartCommand().Execute(context, new StartCommand.Settings { Repo = settings.Repo, Account = who.Email, Prompt = settings.Prompt })
```

No `Provider` is passed. `StartCommand.Settings.Provider` defaults to `"Claude"`
(`Program.cs:302-304`, `[DefaultValue("Claude")]`), so every `org start` runs with `provider ==
"Claude"` regardless of what CLI the target member actually has configured in their own Launcher
settings. This is not merely an unset default that happens to resolve to Claude - `StartCommand`'s
`OwnLogin` helper (the method that logs a member's own account in before handing the CLI its config
dir, `Program.cs:356-382`) explicitly refuses anything else:

```csharp
if (provider != "Claude")
{
    AnsiConsole.MarkupLine($"[red]--account is a Claude login: {Markup.Escape(provider)} has none.[/]");
    return null;
}
```

So `--account` (the option `org start` always uses) is hard-gated to Claude by name, not just by an
unexamined default; passing `--provider Codex --account <email>` would be refused outright, even
called directly.

This is a genuinely different mechanism from `MindAttic.Launcher`'s `AgentProviderRegistry`/
`RunCommand`, which the Launcher uses to open whichever CLI a project/window is configured for and
*is* provider-aware. `MindAttic.Orchestrator`'s org/account subsystem - `AccountDirs`, the per-member
login folders under `~/.claude-accounts` that `org login`/`org start --account` sign in and reuse -
is a parallel, Claude-specific concept with no analog "per-member Codex/Kimi/agy login directory"
built anywhere in the codebase. Nothing here is a fundamental impossibility: a comparable
multi-account directory scheme could in principle be built for another CLI's own per-account config
folders. But it does not exist today, and building it is `MindAttic.Orchestrator` application code,
outside this ticket's file list (AGENTS.md, this doc, and the two ability files). **Verdict for this
part: Claude-only today by a confirmed, deliberate implementation choice - not yet built, and not
attempted by this ticket.**

### b) The live, synchronous "message the sender back mid-session" step - CONFIRMED-ARCHITECTURALLY-IMPOSSIBLE

`research.md` step 5 calls Claude's own `SendMessage` to push a reply into the *specific, already
open* conversation that sent the research request, addressed by its `ListAgents` session name. That
requires reaching into another specific process's live, already-open conversation turn from outside
it. No inspected CLI exposes an API for that:

- Codex's closest primitive, `codex queue --thread <uuid|name> --message <text>` (found via `codex
  queue --help`, recorded by MAT-T98), only reaches a session on the *same* `CODEX_HOME`/login's
  shared local app-server daemon - not a different org member's own separate login, which is what
  this ability needs - and even there it queues a message for the target's *next* turn rather than
  joining the live one synchronously.
- Kimi and agy have no confirmed equivalent of any kind (MAT-T99/MAT-T100).

**Verdict for this part: CONFIRMED-ARCHITECTURALLY-IMPOSSIBLE** - pushing into another specific,
already-running conversation's live turn, mid-stream, from outside it, is a capability no inspected
CLI's API surface exposes, same-login or cross-login.

### c) The asker eventually learning the research landed - TRUE-EQUIVALENT-BUILT, no new code needed

`research.md`'s own step 4 already writes the answer into `docs/research/<Topic>.md`, commits it,
and closes the ticket with a one-paragraph note of the answers. `tickets ticket show <ID> --json` is
a plain, provider-neutral CLI call - any CLI, Claude or not, can already poll it for `status:
closed` and read the note, with zero Claude-specific dependency. The ability's own body already says
as much ("If that session has ended, the ticket notes carry the answer.") - MAT-T103 is formalizing
that this is a complete, generic substitute for "find out the research finished," just not an
instant push. Paired with the sibling MAT-T103 item's `schedule-wakeup.ps1` (not built by this item;
see `shared/abilities/schedule-wakeup.md`), a non-Claude asker could schedule itself to re-check the
ticket later instead of needing a live notification at all.

**Verdict for this part: TRUE-EQUIVALENT-BUILT.** This is the "the asker doesn't find out in real
time, but the deliverable is there and discoverable" half the ticket asked to separate out from the
genuinely-impossible half (b) - and it already works, today, for any CLI, with the tooling that
exists.

### Net effect

`research.md` and `member-contact.md` stay `claude-only: true` - correctly, since parts (a) and (b)
are both still true blockers today - but their `claude-only-reason` now names (a) as the primary,
more fundamental reason (no cross-CLI "start this under their own login" path exists at all yet,
independent of messaging) rather than leading with `SendMessage`, and records (c) as a documented,
already-working fallback rather than leaving the whole ability looking like a dead end once/if (a)
is ever addressed.

## 2. Artifact via the docs-site pipeline

**Overall: PARTIAL-EQUIVALENT** - covered: producing a shareable, version-controlled static page;
not covered: any of Artifact's live/interactive runtime capabilities, in-chat iteration, or
claude.ai's own collaboration surface.

`shared/docs-site/build-docs-site.ps1` and `shared/docs-site/adopt-docs-site.ps1` were read in full
to confirm there is genuinely nothing Claude-specific in the mechanism. There isn't: `build-docs-site.ps1`
is plain PowerShell (`Resolve-Path`, `Get-ChildItem`, regex-based Markdown link rewriting,
`ConvertTo-Json`) that stages `README.md` + `docs/**/*.md` into a temp folder and shells out to
`docfx.exe`; `adopt-docs-site.ps1` writes a `.github/workflows/docs.yml` caller and uses the `gh`
CLI to turn on GitHub Pages and set the repo homepage. Both run identically for any CLI that can
invoke `powershell -File ...` and `git`/`gh` - exactly like `build-docs-site.ps1`'s own doc comment
already claimed, now verified by reading the source rather than assumed.

**What it replaces (Artifact's most common real use - "I need to produce something shareable"):** a
static (rebuilt on every push to `main` via the reusable `docs-pages.yml` GitHub Actions workflow)
page, version-controlled in the repo's own git history, viewable by anyone at
`https://mindattic.github.io/<Repo>/`, built from `README.md` and `docs/**/*.md`, with an optional
generated C# API reference (`-Api`), diffable like any other file, and linkable like any ordinary
URL - no claude.ai account needed to view it.

**What it genuinely cannot replace** (see this session's own `Artifact`/`ArtifactData`/
`ArtifactComments` tool descriptions and the `artifact-capabilities` skill for the full capability
roster):

- Any **runtime capability** a published Artifact page can declare: reading live/connected data on
  each view, `ArtifactData`'s shared mutable database written and read across viewers, the page
  asking Claude a question of its own, remembering per-viewer state server-side (a poll, a sign-up
  sheet, a document that saves new versions of itself), storing files viewers upload, handing the
  viewer a generated file to save, knowing who is currently viewing, or using the viewer's
  camera/microphone/location/screen/device motion. The docs-site pipeline produces a plain static
  (DocFX-rendered) page with no backend of its own.
- **In-chat preview and iterate-in-place**: Artifact's own `read`/`publish` loop inside a live Claude
  conversation, where the page can be opened, screenshotted and re-published in the same turn.
  Docs-site requires a commit + push + a GitHub Actions run before a change is live.
- **claude.ai's native collaboration surface**: `ArtifactComments` threads, pin/share-link UI, and
  per-viewer access control through claude.ai's own sharing model. A GitHub Pages site has none of
  that; sharing it means sharing a plain URL, and feedback happens wherever the team already talks
  (a PR comment, a ticket note, chat), not inline on the page itself.
- **Immediacy**: an Artifact republish is live in seconds; a docs-site update is live after a commit,
  a push, and a GitHub Actions run (typically well under a few minutes, but never instant).

### What changed as a result

AGENTS.md's "Docs site" section (HOUSE-LAW-14) now explicitly frames the pipeline as the cross-CLI
equivalent for "I need to produce something shareable," with this same honest covered/not-covered
split, right after the pipeline's own three numbered steps. No `shared/abilities/*.md` file's
`claude-only-reason` named "needs Artifact" as its blocker (a search of `shared/abilities/*.md` for
`Artifact` found none), so there was no ability frontmatter to repoint - AGENTS.md's own "Cross-CLI
capability framework" paragraph, which previously stated flatly that `Artifact` "remain[s] genuinely
Claude-only with no plausible Codex/Kimi/agy equivalent," was corrected to point here instead.
