# MindAttic.Vault Project Rules

## Conversation
- A bare "do" / "do it" / "yes" from the user means "continue", "keep going", "proceed". Resume the current task without asking for clarification.

## Credentials (single source of truth)
- **The APPDATA Vault store is the one local home for every MindAttic credential.** Each bucket lives at `%APPDATA%\MindAttic\<Bucket>\` and the folder name **equals** its config section `MindAttic:Vault:<Bucket>` (e.g. `LLM`, `Brokers`, `Tokens`, `Subtitles`, `Notifications`, `AudioStore`). Keyrings/structured creds use `providers.json`; the flat token bag uses `tokens.json`. Each file is a faithful image of its config subtree. `Ftp` (`ftp.json`, `FtpCredentialStore`) is the one deliberate exception to the config-section rule — a single flat deploy credential consumed by MindAttic.Deploy/MindAttic.Bob, never surfaced through `IConfiguration`/Key Vault, so it's excluded from `MindAtticConfigurationSource`'s default `Buckets` list.
- **User Secrets is retired — do not reintroduce it.** Never add `AddUserSecrets(...)` to a `Program.cs` or `<UserSecretsId>` to a `.csproj`. User Secrets ranked *above* the writable APPDATA store, so a stale CLI value could silently mask a freshly-rotated key — that drift is exactly what this convention eliminates.
- **Production** resolves the same `MindAttic:Vault:*` keys from environment variables / App Service Application Settings / Azure Key Vault — unchanged. Only local dev changed.
- When adding a new credential to any project, put it in the matching APPDATA bucket (create the bucket folder if needed, name == `MindAttic:Vault:<Bucket>`) so it surfaces through `AddMindAtticVaultFiles()` automatically; never split a credential across two stores.

## Codex — canonical documentation (how to work)
This repo follows the MindAttic **Codex** standard. The canon lives in `docs/`:
- `docs/BIBLE.md` (L0) — the source of truth for what Vault IS, is NOT, and its Laws. Stable IDs `{#M.VALT-§N}` / `{#M.VALT-LAW-n}`. CODE = **VLT**, domain = **library**.
- `docs/AMENDMENTS.md` (L1) — append-only change log; an **amendment wins** over the bible. Never rewrite one; supersede it.
- `docs/USER_STORIES.md` (L2) — test-cited stories; a story is `✅` only when it names a passing test.
- `docs/rfc/*.md` — design notes that graduate into L0 + L2.
- `docs/BIBLE.digest.md` — **generated**; never hand-edit (run the tool).
- Org-wide laws live in [`../MindAttic.HouseRules.md`](../MindAttic.HouseRules.md) and are inherited by BIBLE §5 — do not restate or modify them.

Rules of engagement:
- One home per fact: state a fact in exactly one layer and link to it by ID elsewhere.
- Before claiming `✅`, prove it (clean build + green tests). See BIBLE §8 (quality bar).
- After editing `docs/BIBLE.md`, regenerate the digest: `pwsh tools/codex.ps1 digest`.
- Validate the canon any time: `pwsh tools/codex.ps1 doctor` (must exit 0).
- A SessionStart hook (`.claude/hooks/inject-digest.ps1`) injects the digest as authoritative context.

