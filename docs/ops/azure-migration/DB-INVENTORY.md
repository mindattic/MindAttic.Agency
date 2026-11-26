# Azure database keep-or-drop inventory (MAT-T243)

Read-only inventory taken 2026-11-26 with `az sql db list/show` and `az monitor metrics list`, plus each repo's
configs. Nothing was dropped, moved, paused, resumed, scaled or exported, and nothing was spent. Every line in the
Recommendation column is a **recommendation**; the keep-or-drop call on each is the owner's.

Servers: `sql-mindattic-f65744` (rg-mindattic-data), `prose-sql` and `streetsamurai-sql` (rg MyApps),
`sql-mindatticid-l47dc4` (rg-mindattic-ideas). Sizes are the Azure `storage` metric (allocated), 2026-11-26.
The migration scripts and BACKUP.md referred to below live in the workspace root's `docs/ops/azure-migration/`.

## Findings that change the picture

1. **The ticket's premise is half stale.** `%APPDATA%\MindAttic\MindAttic.Tickets\database.json` and
   `...\MindAttic.Orchestrator\database.json` point at `localhost` (written 2026-10-22/23), and local SQL holds
   `MindAttic.Tickets` and `MindAttic.Orchestrator` (both recreated 2026-11-25, next to `*_Local_20261125` copies).
   So the Azure copies are not read by the apps today; they are stale mirrors from the 2026-11-17/18 cutover
   (`Cutover.ps1`), which was evidently rolled back.
2. **`ClaudeActivity` on Azure is the only copy.** `Switch-PromptLog.ps1` moved it to Azure and made the local copy
   read-only; the local server now has no `ClaudeActivity` database at all, while `prompt-log.json` says
   `Target: Local`. The Azure database (171 MB) must not be dropped; the hook's target needs fixing.
3. **`prose_schematest` exists nowhere**: not on any of the four Azure servers, not on local SQL, and no file in
   the Prose repo mentions it. Already gone; nothing to decide.
4. **Prose has two Azure copies, and the code uses the big one.** `Prose.Core/Data/ProseSqlResilience.cs`,
   `Prose/README.md`, `scripts/gspl_db.ps1` and `SCHEMA.md` all name `sql-mindattic-f65744` / `Prose`.
   Nothing in the Prose, Gadfly, IdeaCms or IdiotProof repos references `prose-sql`.
5. The Azure web apps point at: `mindattic` (stopped) and `mindattic-ideas-demo` -> `sql-mindatticid-l47dc4`
   (`MindAtticIdeas`, `MindAtticIdeasDemo`); `mindattic-gadfly` (stopped) -> `Gadfly`. No web app references any
   other database. The streetsamurai web app was already deleted (MAT-T168).

## Table

| Database (server) | Owning app | Size | State / evidence | Recommendation | Owner decides |
|---|---|---|---|---|---|
| `Prose` (prose-sql) | Prose (old server) | 2.4 GB | Paused; created 2026-08-08; 19 connections in 14 days; no repo references the server. Not the one Prose's code connects to. | **Archive then drop.** One bacpac to R:\Backup first, confirm row counts against the sql-mindattic Prose, then delete; the whole `prose-sql` server can follow. | Yes, drop |
| `Prose` (sql-mindattic) | Prose | 18.6 GB | Online, free offer; the connection string in Prose code. | **Keep.** Canonical. | No |
| `IdiotProof_Research_T375` | IdiotProof (IP-T375 penny walk-forward) | 2.8 GB | Paused, free offer. `CloudDatabases.cs` treats the `IdiotProof_Research_` prefix as real data; cited by `docs/research/evidence-sweep-2026-11.md`. | **Archive** (keep the bacpac), then drop the live copy once the study is closed. | Yes |
| `IdiotProof_Research_T405` | IdiotProof | <0.1 GB | Paused, free offer. | **Archive** bacpac, then drop; trivial cost either way. | Yes |
| `IdiotProof_Research_T407` | IdiotProof (claims event study) | <0.1 GB | Paused, free offer. Read-only copy of the live research claims, cited by the evidence-sweep doc. | **Archive** bacpac, then drop. | Yes |
| `IdiotProof_Research_GAP` | IdiotProof | 8.0 GB | Paused, free offer. Largest research database; on the 28-day backup list. | **Archive** (keep the 0.9 GB bacpac), then drop the live copy if the GAP study is finished; otherwise keep. | Yes |
| `IdiotProof`, `IdiotProof_History` | IdiotProof | 0.01 / 4.7 GB | Live trading and history databases (the Hub). | **Keep.** | No |
| `MindAttic.Tickets` (Azure) | MindAttic.Tickets | 179 MB | Online, billed serverless. The app uses local SQL; stale mirror from the cutover. | **Archive** a final bacpac, **drop** after confirming local is authoritative (row counts and max Id against local). Saves a billed database. | Yes |
| `MindAttic.Orchestrator` (Azure) | MindAttic.Orchestrator | 44 MB | Online, Basic (about $0.16/day). App uses local SQL; stale mirror. | **Archive** then **drop**, same check as Tickets. | Yes |
| `ClaudeActivity` (Azure) | Prompt hook (`shared/hooks/log-user-input.ps1`) | 171 MB | Online, Basic. **Only copy**: no local database exists. | **Keep.** Then either move it back local (`Switch-PromptLog.ps1 -To Local`) or set `prompt-log.json` to `Azure`; today it says Local with no local database. | Yes, direction |
| `StreetSamurai` (streetsamurai-sql) | StreetSamurai (web app deleted, MAT-T168) | about 2.7 GB (IdiotProof backup-gap doc) | Paused; 15 connections in 14 days (probably probes); no consumer left. | **Archive** (one bacpac to R:), then **drop** the database and the `streetsamurai-sql` server. | Yes, drop |
| `MindAtticIdeas` | Ideas / IdeaCms (`mindattic` web app) | 32 MB | Online, Basic; about 3,400 connections in 14 days; the live Ideas database. | **Keep.** | No |
| `MindAtticIdeasDemo` | Ideas demo (`mindattic-ideas-demo`, running) | about 0 MB | Created today; the demo app points at it. | **Keep** while the demo site runs. | Yes, if the demo is retired |
| `MindAtticIdeasDemoTemplate` | Ideas demo seed | 9.8 MB | Basic, about $0.16/day; no web app points at it. | **Archive** a bacpac, then **drop**; keep only if the demo is re-seeded from it. | Yes |
| `IdeaCmsDev` | IdeaCms dev | 9.9 MB | Basic; in the nightly backup set. | **Keep** while IdeaCms development uses it. | Yes |
| `Gadfly` | Gadfly (`mindattic-gadfly`, stopped) | 53 MB | Paused, created 2026-11-21. | **Keep** (no billing while paused); revisit if the app stays stopped. | Yes |
| `ThinkTank` | ThinkTank | 8 MB | Online, Basic. Not in BACKUP.md's lists; no repo directory by that name under the workspace. | **Keep for now**; the owner confirms who uses it. | Yes |
| `OpenCredentials`, `TaxRateCollector`, `Formicarium`, `TutorAuth` | their own repos | <0.1 GB each | Paused, free offer; TutorAuth saw 197 connections in 14 days, the others could not be measured. | **Keep**; they cost nothing at rest. | No |

Not measured: connection counts for most `sql-mindattic` databases (the metrics call rejected the window). Sizes of
the free-offer research databases are from the Azure metric or BACKUP.md.

## Order of operations if the owner agrees (each step is the owner's to run)

1. Take a fresh bacpac of anything marked Archive (`Backup-AzureDatabase.ps1`) and test-restore one.
2. Verify the stale mirrors against local (row counts, max Id) before dropping Azure Tickets/Orchestrator.
3. Drop in this order: `streetsamurai-sql` (server), `prose-sql` (server), the Ideas template, the two stale
   mirrors, then finished research databases.
4. Fix the `ClaudeActivity` hook target first; it is the only live data with a single copy.

Free-offer databases cannot use long-term retention and a dropped database cannot be restored from a deleted
server, so step 1 is not optional.
