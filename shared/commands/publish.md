---
description: Build the current repo's latest mod version and publish it to NexusMods via the Upload API, cutting a GitHub release that triggers CI by default.
argument-hint: "[--local to skip GitHub Actions and upload directly from this machine]"
allowed-tools: Read, Bash, PowerShell
---

Global MindAttic command, for a repo that ships a mod page on NexusMods. Requires a `nexus.json`
at the repo root:

```json
{
  "modId": 651,
  "fileId": 12345,
  "modFolderName": "RogueTraderBrevity",
  "project": "src/BrevityMod",
  "category": "main"
}
```

If `nexus.json` is missing, tell the user plainly this repo has no automated Nexus publish
configured, and stop - never fabricate `modId`/`fileId`. If `fileId` is `0` or absent, stop and say
which field still needs filling in (get it from the mod page's Files tab -> API Info, or Manage
Files -> edit menu).

## 1. Build and find the new version

Run `dotnet build <project> -c Release` from the repo root (per `RogueTrader.Package.targets`,
this also packages `dist\<modFolderName>-<version>.zip`). Take the newest
`dist\<modFolderName>-*.zip` and read `<version>` from its filename.

## 2. Stop if this version is already published

If a git tag `v<version>` already exists, tell the user there's nothing new to publish (the dist
zip's version hasn't moved since the last publish) and stop.

## 3. Cut the release (triggers CI) - the default path

Unless `--local` was passed:

- `git tag v<version>` and `git push origin v<version>`.
- `gh release create v<version> "dist\<modFolderName>-<version>.zip" --title "<modFolderName> <version>" --generate-notes`.
  Attaching the dist zip as a release asset is what lets CI publish it without needing the game
  installed on the runner.
- That `release: published` event is what the repo's `.github/workflows/publish.yml` (if present)
  listens for: it downloads the release asset and runs the official `Nexus-Mods/upload-action`
  against it, using the repo's `NEXUSMODS_API_KEY` secret. Watch it with
  `gh run list --workflow publish.yml -L 1` then `gh run watch <run-id>`, and report its real
  outcome - don't claim success before it finishes. If the repo has no `publish.yml`, say so and
  fall back to step 4 instead.

## 4. Local fallback

If `gh` isn't available, the repo has no `origin` on GitHub, `.github/workflows/publish.yml`
doesn't exist, or `--local` was passed: still create the tag (step 2's check needs it to exist
afterward so a second `/publish` doesn't re-upload the same version), then run
`mindattic-agent-standard/shared/publish-nexus-local.ps1 -RepoPath <repo root>`. It reads the API
key from the Nexus Vault bucket (`%APPDATA%\MindAttic\Nexus\tokens.json`) and runs the same
vendored `Nexus-Mods/upload-action` code directly with Node - no GitHub involved.

## Always

- Never invent a `modId`/`fileId` - only use what `nexus.json` says.
- Surface the real build/CI/upload output; don't summarize away a failure.
- If the Vault bucket has no `apiKey`, say so and point at
  https://next.nexusmods.com/settings/api-keys - don't try to upload without one.
- Never force-push or skip hooks to "just get it published."
