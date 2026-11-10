Stage, commit, and push the current working-tree changes.

Run these in parallel first:
- `git status` (no `-uall` flag - large repos)
- `git diff` (staged + unstaged)
- `git log -n 10 --oneline` (match the repo's commit-message style)

**Commit only what this session wrote.** Other agents (autopilot worktrees, other CLI tabs) may
have pending edits in the same repos, so the working tree is not "your changes". The files this
session changed are the ones its own file-edit/write actions (and its own commands) touched; go by
that, not by `git status`.
- From the **General session** (cwd is the workspace root `D:\Projects\MindAttic`, not inside a
  repo), there's no single repo: list every repo this session wrote to, and run the steps below
  once per repo with `git -C <repo>`, each with its own ticket and commit.
- Stage by explicit path (`git add -- <paths>`) only files this session changed. A file only
  someone else changed is never staged, whatever it is.
- A file this session changed that also holds someone else's uncommitted hunks: stage only your
  hunks. Write `git diff -- <file>` to a patch in the scratchpad, delete the hunks you didn't
  write, and `git apply --cached <patch>`. Check `git diff --cached -- <file>` shows only your
  work. If the hunks can't be separated cleanly, leave the file unstaged and say so.
- Afterwards, name the changes you left (other agents' files and hunks) so the user knows they
  were seen and left on purpose.

Then:
0. Log the work as a ticket with the `tickets` CLI. Every repo's tickets and stories live in the
   MindAttic.Tickets database (`MindAttic.Tickets/data/Tickets.db`). `docs/USER_STORIES.md` is a
   generated view the CLI rewrites after each change: never edit it, but stage it with the rest when it changed. Pass `--repo <name>` when you
   aren't standing in the repo (e.g. in a worktree):
   - new work: `tickets ticket new --type feature|fix|chore|docs --status closed --summary "<one line: what and why>" --ref "<story ID / test name>"`
   - work that finishes an open ticket: `tickets ticket close <CODE-Tn> --ref "<test or story>"`
     (`tickets ticket list --repo <name> --status open` shows them; `tickets ticket show <ID>` shows one with its links)
   - a story it completes: `tickets story status <CODE-US-...> done`
   Then run `tickets ticket verify` and fix anything it reports. If `tickets` isn't on PATH, stop
   and say so rather than editing any file by hand. The orchestrator commits the database itself.
   **One ticket per commit, no cross-contamination.** If this session's changes cover more than
   one ticket or story, make one commit per ticket: repeat steps 0-6 for each, staging only that
   ticket's files and hunks. Never fold another ticket's work, or unticketed work, into a commit.
1. Draft a concise (1-2 sentence) commit message focused on the *why*, not the *what*. Match the
   recent log's tone. The subject line MUST end with the ticket ID in parentheses, e.g.
   `... (M.ORCH-T56)`, and the ID must exist in the ticket database: every repo's `commit-msg`
   hook refuses anything else. No ticket ID, no commit: go back to step 0 and create the ticket.
2. Stage this session's files by name (see above). Never `git add -A`, `git add .` or `git commit -a`: they pull in other agents' work as well as `.env` files, credentials and large binaries.
3. Skip secrets: warn before committing anything that looks like a credential file.
4. Create a NEW commit (never `--amend`), ending with the attribution footer this session was
   given - the `Co-Authored-By:` line, plus a session-reference line whenever one is provided.
   Do NOT hardcode a model name here: it goes stale the moment the model changes, and a commit
   log that credits the wrong model is worse than one that credits none. If the session was given
   no attribution guidance, omit the footer rather than guessing.
   Pass the message via heredoc so multi-line formatting is preserved.
5. Run `git status` after the commit and confirm it succeeded.
6. Push to the upstream remote (`git push`). If the branch has no upstream yet, push with `-u origin <branch>`. Surface the remote's response - and if the push is rejected (e.g. non-fast-forward), STOP and report to the user instead of force-pushing.
   Before pushing, note the range being pushed (`git rev-parse @{u}` .. `HEAD`); step 6b needs it.
6b. **Push git subtrees too.** A repo can embed another repo as a `git subtree` (e.g. a `shared/`
   folder). Its changes only reach that other repo through `git subtree push`, so `/commit` does it
   every time; it is part of committing, not a separate cross-repo action, so no `/crossrepo` is needed.
   - Find the subtrees: the `git-subtree-dir: <prefix>` lines in `git log --grep=git-subtree-dir: --format=%B`,
     unique. None: skip this step. History keeps a folder that was folded in for good, so skip any prefix
     the repo's `AGENTS.md` says is no longer a subtree.
   - For each prefix, check whether the pushed range touched it: `git log --oneline <old upstream>..HEAD -- <prefix>`.
     Nothing: skip that prefix.
   - Find its upstream: the URL and branch the repo's `AGENTS.md` (or README) gives for that subtree,
     else a remote named after it. Can't find one: don't guess; say which prefix has unpushed changes.
   - Run `git subtree push --prefix <prefix> <url> <branch>` (it can take minutes on long histories)
     and surface the output. If it is rejected because the upstream moved on, STOP and report: the
     fix is `git subtree pull --prefix <prefix> <url> <branch> --squash`, then `/commit` again. Never
     force-push a subtree upstream, and never push to a remote the repo's `AGENTS.md` forbids.
7. Print the commit hash + a one-line summary, and each subtree pushed (prefix -> upstream).

Do NOT skip hooks (`--no-verify`). Do NOT force-push. If a pre-commit hook fails, fix the underlying issue and create a fresh commit - never amend. If a push to `main`/`master` is rejected, warn the user before any recovery action; do not force-push protected branches.

If there are no changes, say so and exit without creating an empty commit (and skip the push).
