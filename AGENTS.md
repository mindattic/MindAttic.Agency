# MindAttic Agent Standard

Start with the repository's local `AGENTS.md`, then read this shared layer and its project
protocol. Common commands are implemented once, at the global level, so every repo has them on Day
1 with no per-project setup:

- `/do`, `/quicksave`, `/quickload` — real global commands at `~/.claude/commands/` (for Claude
  Code) that invoke the shared runner, `mindattic-agent-standard/prose-agent.ps1` (`save`/`load`).
- `/commit` — global, Claude Code's own `~/.claude/commands/commit.md`.
- `/run` — global, a Claude Code built-in skill; no MindAttic-specific file needed.
- `/deploy` — global router at `~/.claude/commands/deploy.md`: defers to the repo's own
  `deploy.ps1`, else routes through MindAttic.Deploy, else says plainly that the repo has no
  automated deploy. Per-project deploy *behavior* still varies — the router doesn't.
- `/progress` — a real global command at `~/.claude/commands/progress.md` that runs
  `mindattic-agent-standard/agent-progress.ps1`: every running subagent (any session or project),
  its ticket, what it is doing now, and an estimated percent done from its milestones (explore →
  edit → test → commit → push → ticket closed). `prose-agent.ps1 progress` runs the same report
  outside Prose; inside Prose, Prose's own project `/progress` (the strand dashboard) still wins.
- `/show`, `/bootstrap`, `/queue` — implemented directly by the shared runner
  (`prose-agent.ps1`); invoke it by path rather than duplicating its logic.

## Cloning a new repo

Never run a bare `git clone` into the workspace. Use
`mindattic-agent-standard/clone-repo.ps1 -Repo <owner/name or name>`, which does all four steps
every new repo needs, in order, with nothing left to remember:

- **A)** creates the destination folder, **B)** clones the repo into it,
- **C)** tags the repo `wip` on GitHub — the only lever
  `MindAttic.Launcher`'s `TopicRepoSync`/`GitHubTopicRepos` filter the project roster by; an
  untagged repo exists on disk but never shows up in the Launcher,
- **D)** restarts any open `MindAttic.Launcher` **program** instance (a bare, no-argument
  process — the interactive menu) so it re-fetches the tagged-repo set and offers the new repo
  through Discover Projects. A `host ...`/`commit ...`/`backup ...`/`restore ...`/`bootstrap
  ...`/`version` instance is a live per-tab CLI invocation, not "the program", and is left
  running untouched.

This applies whether the clone is for a brand-new repo or an existing one the workspace hasn't
picked up yet (e.g. a repo missing its `wip` topic): `clone-repo.ps1` tags and restarts even when
skipped past the clone step for a repo already on disk — see the script's own doc comment.

## Branches

Every repo's main line is `main` (Automata, MindAttic.Authentication, MindAttic.Ideas, Prose and this workspace root
repo were renamed from `master` on 2026-10-16; four archived repos, MindAttic.Bob among them, are read-only and stay as they are). Rebase onto and push to `origin/main`; never push
`master` anywhere: it would only recreate a stray branch, and the pace gate refuses it.

## Ticket intake: what may join the queue without the user

- Bugs (something that's broken or wrong): file them straight away as `open` tickets with
  `--type fix`; fixes are worked without asking.
- Anything else (a feature, a change of behaviour, a chore, tests, docs), whether the user suggested it or
  you thought of it: write the ticket, print its full text for the user, and wait for the user's yes. A
  non-fix ticket is never worked until the user approves it (`orchestrator approve <ID>`); the orchestrator,
  `/allocate` and keep-going skip it until then, and so must you.

## Commits: one ticket, one story, nothing else

This applies to every commit, whoever makes it (`/commit`, `/allocate`, the orchestrator, a subagent, a
manual `git commit`):

- Every commit names its ticket. The subject line ends with the ticket ID in parentheses,
  e.g. `... (M.ORCH-T56)`. A commit that has no ticket yet gets one *before* it's made: `tickets ticket
  new` prints the new ID. Work the user asked for directly counts as approved, so its ticket can be
  logged `--status closed` when the commit finishes it. Every repo's `commit-msg` hook
  (`shared/hooks/commit-msg`, installed by `install-commit-hooks.ps1`) refuses a commit whose subject
  doesn't end with an ID that exists in the ticket database; merges, reverts and fixup!/squash!
  commits pass. Never bypass it with `--no-verify`.
- A commit holds the work of one ticket (and the story it belongs to) and nothing else. Two
  tickets or stories mean two commits. Stage by explicit path, and split a file that holds hunks
  for different tickets (stage only that ticket's hunks). Leave anything that belongs to another
  ticket, or to no ticket of yours, unstaged.
- The ticket database and its generated `docs/USER_STORIES.md` are the only shared files that may
  ride along, and only for the ticket being committed.

Never copy a command's body into a provider-specific or per-project folder. A client-specific
alias (e.g. a non-Claude provider's own command file) must invoke the shared global command or the
runner — never reimplement it.

## Artifacts: every one also lives in the repo (HOUSE-LAW-12)

A Claude artifact lives on claude.ai and has been observed going missing, so the repo copy is the
durable one. This applies to every artifact published or updated while working on a MindAttic
project, not just ones the user asks to save:

1. **Get the full content.** After publishing or updating, read it back
   (`Artifact action: read`, `page: true`) so you have the exact bytes the host now serves —
   never retype or paraphrase it. A multi-file artifact's other published files
   (`action: read`, `path`/`paths`) get inlined into the one HTML file (styles and scripts
   inline, images as data URIs) — a Google Fonts `<link>` is the one exception and stays a link.
2. **Name it from its `<title>`.** Sanitize for the filesystem (strip `< > : " / \ | ? *` and
   control characters, collapse whitespace) and add `.html`. Never name it after the artifact's
   id or URL slug.
3. **Place it.** `<repo>/artifacts/<Title>.html` in the one MindAttic project repo the artifact
   is for. An artifact that isn't about any single project (a general reference page, a tool
   demo) goes in the workspace-root `artifacts/` folder instead. If the repo's `artifacts/`
   folder is already used for something else (e.g. GridGameCaravan's `tools/labcheck.py`
   screenshots), the HTML file sits alongside it — same folder, no collision, since the filename
   comes from the title.
4. **Commit it with the ticket for the work that produced it.** New work and its artifact are one
   story, one commit. A backfill of an artifact from earlier work gets its own `chore` ticket
   (`tickets ticket new --repo <name> --type chore --summary "..."`) in that artifact's repo —
   root-level artifacts (and other workspace-root-only chores) use `--repo MindAttic.Agency`,
   the established home for org-wide tickets, per MAT-T4/MAT-T5.

See `MindAttic.HouseRules.md` HOUSE-LAW-12 for the one-paragraph version every project's
`docs/BIBLE.md` can cite by reference.

## Docs site: every repo on GitHub Pages (HOUSE-LAW-14)

A repo's docs are published by MindAttic.Agency's shared pipeline, never by a per-repo renderer.

1. **Preview locally** (needs `dotnet tool install -g docfx`):
   `powershell -File MindAttic.Agency/shared/docs-site/build-docs-site.ps1 -Root <repo> [-Api] -Serve`.
   It stages README.md as `index.md` plus `docs/**/*.md` in a temp folder, generates `toc.yml` and
   `docfx.json` there, and runs DocFX. Nothing is written into the repo.
2. **Adopt**: `powershell -File MindAttic.Agency/shared/docs-site/adopt-docs-site.ps1 -Repo <name> [-Api] [-RunsOn windows-latest]`.
   It writes `.github/workflows/docs.yml`, deletes `tools/build-readme.ps1`/`.js` and `README.htm`,
   turns Pages on (`build_type=workflow`), sets an empty repo homepage to the site URL, and lists
   any file that still mentions the old renderer. Use `-Api` for any repo with C# code: the API
   reference is read from the `.cs` sources without a NuGet restore (packages in `C:\LocalNuGet`
   aren't in CI), so it works for libraries, apps, GTFO mods and Unity games alike; external types
   just show by name.
3. **Commit** the result with the repo's own docs ticket, push, and check that the `docs` run is
   green and `https://mindattic.github.io/<Repo>/` loads.

Links are rewritten while staging: links between published pages stay page links, images are
copied in, anything else in the repo links to it on GitHub, and links that leave the repo keep
only their text. BIBLE-style `{#id}` anchors and codex front matter are handled too.
