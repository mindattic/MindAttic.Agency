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
- `/progress`, `/show`, `/bootstrap`, `/queue` — implemented directly by the shared runner
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
  autopilot and keep-going skip it until then, and so must you.

## Commits: one ticket, one story, nothing else

This applies to every commit, whoever makes it (`/commit`, autopilot, the orchestrator, a subagent, a
manual `git commit`):

- Every commit names its workflow ticket. The subject line ends with the ticket ID in parentheses,
  e.g. `... (M.ORCH-T56)`. A commit that has no ticket yet gets one *before* it's made: `workflow ticket
  new` prints the new ID. Work the user asked for directly counts as approved, so its ticket can be
  logged `--status closed` when the commit finishes it. Every repo's `commit-msg` hook
  (`shared/hooks/commit-msg`, installed by `install-commit-hooks.ps1`) refuses a commit whose subject
  doesn't end with an ID that exists in the workflow database; merges, reverts and fixup!/squash!
  commits pass. Never bypass it with `--no-verify`.
- A commit holds the work of one ticket (and the story it belongs to) and nothing else. Two
  tickets or stories mean two commits. Stage by explicit path, and split a file that holds hunks
  for different tickets (stage only that ticket's hunks). Leave anything that belongs to another
  ticket, or to no ticket of yours, unstaged.
- The workflow database and its generated `docs/USER_STORIES.md` are the only shared files that may
  ride along, and only for the ticket being committed.

Never copy a command's body into a provider-specific or per-project folder. A client-specific
alias (e.g. a non-Claude provider's own command file) must invoke the shared global command or the
runner — never reimplement it.
