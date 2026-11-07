---
description: Build the current repo's mod, skip the whole thing if nothing actually changed, otherwise bump its version, write a player-facing changelog and README update, and publish to NexusMods and/or Thunderstore (whichever the repo is configured for) via a GitHub release that triggers CI by default.
argument-hint: "[--local to skip GitHub Actions and upload directly from this machine]"
allowed-tools: Read, Bash, PowerShell
---

Global MindAttic command for a repo that ships a mod. Supports two independent platforms, each
gated on its own config file - a repo may have one or the other:

- **NexusMods** - `nexus.json` at the repo root:
  ```json
  { "modId": 651, "fileId": 12345, "modFolderName": "RogueTraderBrevity", "project": "src/BrevityMod", "category": "main" }
  ```
- **Thunderstore** - `thunderstore.toml` at the repo root (GTFO mods). Name/namespace/version come
  from `package/manifest.json`, which `thunderstore.toml` itself says is the source of truth for
  `tcli publish --file <zip>`.

If neither config file exists, tell the user plainly this repo has no automated publish configured,
and stop - never fabricate IDs. For NexusMods, if `fileId` is `0` or absent, stop and say which
field still needs filling in (get it from the mod page's Files tab -> API Info, or Manage Files ->
edit menu).

## 1. Build the current (unbumped) version

- RogueTrader mods: `dotnet build <nexus.json's project> -c Release` (per
  `RogueTrader.Package.targets`, this packages into `<project>\obj\Release\<tfm>\package\<ModFolderName>\`
  before zipping to `dist\<modFolderName>-<version>.zip` - glob for the `<tfm>` segment, it varies
  per project). The pre-zip folder `.../package/<ModFolderName>/` is the payload to hash.
- GTFO mods: `./build.ps1` from the repo root. `package/` (repo root, not `dist/`) is the payload to
  hash - it's rebuilt in place from `src/` output each run, same folder Thunderstore ships.

## 2. No-op guard - never bump or republish unmodified code

Read `.publish-state.json` at the repo root (`{ "lastPublishedVersion": "...", "lastPublishedHash":
"...", "lastPublishedRef": "<git sha>" }`). If it doesn't exist, this is the first tracked publish -
skip the comparison below but still create the file after a successful publish.

Hash the payload directory from step 1 with
`mindattic-agent-standard/shared/compute-mod-hash.ps1 -Path <payload dir> -ExcludeNames <...>`.
**Exclude every file whose content is expected to change on every publish regardless of whether the
compiled/packaged mod itself changed** - otherwise the hash can never repeat and the guard is
useless:
- RogueTrader: the mod's own manifest (`Info.json` for Brevity, `OwlcatModificationManifest.json`
  for Overwatch) embeds the version string.
- GTFO: `manifest.json`, `CHANGELOG.md`, `README.md`.

This hashes actual payload bytes, not the zip - zip format embeds timestamps and can
reorder/recompress identical content differently between builds, which would make an unchanged mod
look "changed". Don't substitute a zip-file hash or a git-diff-since-last-tag check for this.

**If the new hash equals `lastPublishedHash`:** tell the user plainly, e.g. "No code changes since
v<lastPublishedVersion> - skipping publish (payload hash unchanged)," and stop. Do not touch the
version, changelog, README, or cut a release. This is the point of the whole guard.

**If it differs (or there's no prior state):** continue to step 3.

## 3. Bump the version

Read the current version from its canonical source (RogueTrader: the `Info.json`/
`OwlcatModificationManifest.json` field the `.csproj`'s `ModVersion` regex reads; GTFO:
`package/manifest.json`'s `version_number`, keep `thunderstore.toml`'s `versionNumber` in sync).
Increment the leading integer by 1, preserving whatever suffix format was already there (a bare
integer stays bare; an `X.0.0` triple stays `X.0.0` - Thunderstore requires strict semver, this repo
family only ever bumps the major component). Write the new version back, then rebuild (step 1's
command again) so the dist zip/package reflects it.

If a GTFO mod's `AGENTS.md` documents a cross-repo dependency pin on another MindAttic mod's version
(e.g. GTFO.EZ's `MindAttic-GtfoEZAbsurdItems-X.Y.Z` in `package/manifest.json`), check whether that
pinned mod also needs a bump per that doc's own rule before assuming it's unrelated - don't silently
leave a stale pin.

## 4. Write a player-facing changelog entry

`git log <lastPublishedRef>..HEAD --oneline` lists every commit since the last publish (each ends
with its ticket ID, per house convention). Read any whose summary alone doesn't make the user-facing
effect clear (`git show <sha>`), then write 2-6 genuine, player-facing bullets - what changed for
someone playing the mod, not ticket titles or raw commit text - grouped as Added/Changed/Fixed only
when that helps; a small release can stay a flat list. Match the repo's own existing changelog voice
(GTFO.EZ's `package/CHANGELOG.md` bolds a short headline per entry, explains the player-visible
effect in plain language, then cites the ticket ID in parentheses - follow that pattern). Cite each
entry's ticket ID the same way.

Prepend the new `## <version>` entry to:
- GTFO: `package/CHANGELOG.md` (existing convention, ships in the Thunderstore package and renders
  on its listing page).
- RogueTrader (no existing CHANGELOG.md): a `## Changelog` section in the repo's `README.md`,
  newest version first; create the section if it doesn't exist yet.

## 5. Review the README(s) for accuracy

Bump every version reference. Then **read the whole README end to end** (repo root, and GTFO's
`package/README.md` which ships in the Thunderstore package) and compare its prose against the
actual current code/behavior - not just the commits since last publish, the whole document. Correct
anything stale: a described feature that no longer works that way, a removed option still
documented, a stated limitation that's since been fixed, wrong file paths. This is a judgment pass,
not a mechanical one - read the source for anything you're not sure is still accurate rather than
assuming the README was already correct.

## 6. Record the publish state and commit

Write `.publish-state.json` with the new hash (recompute after the step-3 rebuild, in case the
version bump itself changed payload bytes - e.g. an embedded version string in a DLL), the new
version, and `lastPublishedRef` set to the commit you're about to make (fill in its real sha after
committing). Commit the version-bump file(s), changelog, README(s) and `.publish-state.json` together
under one ticket, by path (never a bare `git commit`), and push.

**This commit happens before the upload is confirmed.** If the CI run in step 7 (or the local
fallback) fails, the state file already claims this version as published - don't leave that
standing: tell the user plainly that the version/changelog/README landed but the upload itself
failed, and that retrying needs the upload step re-run directly (`gh workflow run publish.yml` or
the local fallback script), not a second `/publish` - a second `/publish` will see the hash already
matches and skip.

## 7. Cut the release (triggers CI) - the default path

Unless `--local` was passed:

- `git tag v<version>` and `git push origin v<version>`.
- `gh release create v<version> "dist\<modFolderName>-<version>.zip"` (RogueTrader) or
  `"dist\<DisplayName>-<version>.zip"` (GTFO, per `build.ps1`) `--title "<name> <version>" --notes
  "<the changelog entry from step 4>"`. Attaching the zip as a release asset is what lets CI publish
  it without needing the game (or, for GTFO, a configured BepInEx profile) on the runner.
- That `release: published` event is what the repo's `.github/workflows/publish.yml` listens for: it
  downloads the release asset and runs `Nexus-Mods/upload-action` (NexusMods repos, using
  `NEXUSMODS_API_KEY`) and/or installs `tcli` and runs `tcli publish --file <zip> --token
  $env:THUNDERSTORE_API_KEY` (Thunderstore repos). Watch it with `gh run list --workflow publish.yml
  -L 1` then `gh run watch <run-id>`, and report its real outcome - don't claim success before it
  finishes. If the repo has no `publish.yml`, say so and fall back to step 8 instead.

## 8. Local fallback

If `gh` isn't available, the repo has no `origin` on GitHub, `.github/workflows/publish.yml` doesn't
exist, or `--local` was passed: still create the tag (so a second `/publish` doesn't re-detect this
version as new), then:
- NexusMods: `mindattic-agent-standard/shared/publish-nexus-local.ps1 -RepoPath <repo root>`. Reads
  the key from `%APPDATA%\MindAttic\Nexus\tokens.json` and runs the vendored `Nexus-Mods/upload-action`
  code directly with Node.
- Thunderstore: `tcli publish --file <dist zip> --token (mindattic-agent-standard/shared/get-thunderstore-api-key.ps1)`
  (install `tcli` first - `dotnet tool install -g tcli` - if it's not already on PATH). Reads the key
  from `%APPDATA%\MindAttic\Thunderstore\tokens.json`.

## Always

- Never invent a `modId`/`fileId`/namespace - only use what the repo's own config says.
- Surface the real build/CI/upload output; don't summarize away a failure.
- If the relevant Vault bucket has no `apiKey`, say so and point at
  https://next.nexusmods.com/settings/api-keys (NexusMods) or
  https://thunderstore.io/settings/teams/ (Thunderstore, Service Accounts) - don't try to upload
  without one.
- Never force-push or skip hooks to "just get it published."
- The no-op guard (step 2) is the whole point of this redesign - never bypass it to "just publish
  anyway" unless the user explicitly says to force a republish of unchanged code.
