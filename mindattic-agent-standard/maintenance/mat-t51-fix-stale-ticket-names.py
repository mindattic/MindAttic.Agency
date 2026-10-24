"""
MAT-T51: one-off correction of ticket summaries that still name pre-rename projects/CLIs
(found by the MAT-T26 sweep). `tickets` has no summary-edit verb (only `ticket correct`, for
`type`), so this applies the same sanctioned, append-only exception TicketsDb.CorrectType uses
-- drop the tickets_append_only guard for one update, set the new summary, record the change in
ticket_events, put the guard straight back, all in one transaction -- to `summary` instead of
`type`. Recorded in each ticket's history as a 'summary' event with the old and new text.

Works against whichever store this machine has configured (see TicketsServer.Configured):
data/Tickets.db directly, or -- the case this actually ran against -- SQL Server, reached
through its own session-scoped write lock (sp_getapplock) the way TicketsDb.Begin() takes it,
with the same dialect rewrite TicketsDb.Server.ToTransactSql applies (DROP/CREATE TRIGGER
text, $param -> @param, strftime -> FORMAT(SYSUTCDATETIME(), ...)).

Run once, directly against the live database (this workspace's database.json pointed at
localhost/MindAttic.Tickets at the time, so the SQL Server branch is the one that actually ran;
53 tickets corrected, `tickets db check` clean afterward, `tickets db render` refreshed the 45
affected repos' generated docs/USER_STORIES.md). Kept in MindAttic.Agency only as the auditable
record of what ran and how (MAT-T4/MAT-T5: Agency is the home for org-wide maintenance like this).
Re-running it is safe but a no-op: each UPDATE is guarded by a check that the live summary still
reads exactly as this script expects, so it throws rather than double-applying or overwriting a
summary someone else changed since.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

REASON = "MAT-T51 -- reworded to use current project/CLI names"

# ---- Group 1: the "...shared Toolkit DocFX pipeline..." tickets (MindAttic.Toolkit is now
# MindAttic.Agency). Plain substring fix, same for all of them.
TOOLKIT_IDS = [
    'AUT-T23', 'AWN-T16', 'CM-T10', 'CUR-T18', 'FOR-T20', 'G.AWPN-T217', 'G.CTD-T38', 'G.SD-T12',
    'GAD-T14', 'GAI-T18', 'GAM-T47', 'GES-T2', 'GGC-T22', 'IP-T27', 'JF-T10', 'JFP-T10', 'JH-T18',
    'KP-T17', 'M.AUTH-T20', 'M.BRWS-T15', 'M.CRYP-T10', 'M.DPLY-T16', 'M.EXPT-T10', 'M.HELP-T10',
    'M.IDEA-T23', 'M.LOGS-T15', 'M.MDIA-T13', 'M.PSST-T22', 'M.SCHD-T16', 'M.TELE-T13', 'M.VALT-T16',
    'M.WEB-T14', 'MAU-T4', 'MB-T20', 'OC-T25', 'PL-T26', 'PRS-T217', 'SET-T18', 'TRC-T20', 'TT-T20',
    'TUT-T24', 'U.EVE-T19', 'UNS-T11',
]
TOOLKIT_OLD = "shared Toolkit DocFX pipeline"
TOOLKIT_NEW = "shared Agency DocFX pipeline"

# ---- Group 2: M.SCHD-T16 needs the Toolkit fix *and* its own repo's old name
# (MindAttic.WatchDog -> MindAttic.Scheduler) fixed in the publish line and the Pages URL.
# ---- Group 3: IP-T25 / JFP-T8 / UNS-T9 / PRS-T187 cite "MindAttic.WatchDog M.WD-Tn"; the
# repo is MindAttic.Scheduler and M.WD-Tn was renumbered 1:1 to M.SCHD-Tn (id_history seq 178-194).
# ---- Group 4: M.TIX-T72/74/78/86/87 cite "workflow ticket ..." commands; the CLI is `tickets`
# (and T72 also names the old WorkflowDb class, now TicketsDb).
# ---- Group 5: GG-T99 cites "the shared MindAttic.Unity package"; the package now lives in
# Unity.Shared (com.mindattic.unity.shared, file:../../Unity.Shared/unity/com.mindattic.unity.shared).
EXPLICIT = {
    'M.SCHD-T16': (
        "Publish MindAttic.WatchDog docs to GitHub Pages via the shared Toolkit DocFX pipeline: run adopt-docs-site.ps1 (README.md as home page, docs/*.md as articles, API reference only where the code builds in CI), enable Pages with build_type=workflow, set the repo homepage URL, retire tools/build-readme.ps1 and README.htm, confirm the docs Actions run is green and https://mindattic.github.io/MindAttic.WatchDog/ returns 200. Depends on MAT-T8.",
        "Publish MindAttic.Scheduler docs to GitHub Pages via the shared Agency DocFX pipeline: run adopt-docs-site.ps1 (README.md as home page, docs/*.md as articles, API reference only where the code builds in CI), enable Pages with build_type=workflow, set the repo homepage URL, retire tools/build-readme.ps1 and README.htm, confirm the docs Actions run is green and https://mindattic.github.io/MindAttic.Scheduler/ returns 200. Depends on MAT-T8.",
    ),
    'IP-T25': (
        "Retire tools/register-research-scan-task.ps1 (job now in MindAttic.WatchDog M.WD-T8)",
        "Retire tools/register-research-scan-task.ps1 (job now in MindAttic.Scheduler M.SCHD-T8)",
    ),
    'JFP-T8': (
        "Retire scripts/register_scheduled_task.ps1 and its README steps (job now in MindAttic.WatchDog M.WD-T7)",
        "Retire scripts/register_scheduled_task.ps1 and its README steps (job now in MindAttic.Scheduler M.SCHD-T7)",
    ),
    'UNS-T9': (
        "Stop registering the UnstuckTaskbar Logon task in deploy/setup (job now in MindAttic.WatchDog M.WD-T9)",
        "Stop registering the UnstuckTaskbar Logon task in deploy/setup (job now in MindAttic.Scheduler M.SCHD-T9)",
    ),
    'PRS-T187': (
        "Retire scripts/fix-task-focus-stealing.ps1: WatchDog's install.ps1 registers every job headless and non-interactive, so no task needs patching after the fact (job now in MindAttic.WatchDog M.WD-T11)",
        "Retire scripts/fix-task-focus-stealing.ps1: Scheduler's install.ps1 registers every job headless and non-interactive, so no task needs patching after the fact (job now in MindAttic.Scheduler M.SCHD-T11)",
    ),
    'M.TIX-T72': (
        "Append-only ticket comments: ticket_notes table (ticket, author, at, markdown), WorkflowDb.AddNote/Notes, workflow ticket note, shown in show and Desktop",
        "Append-only ticket comments: ticket_notes table (ticket, author, at, markdown), TicketsDb.AddNote/Notes, tickets ticket note, shown in show and Desktop",
    ),
    'M.TIX-T74': (
        "Ticket labels and components: ticket_labels table, workflow ticket label add/remove, list --label filter, Desktop chips and filter",
        "Ticket labels and components: ticket_labels table, tickets ticket label add/remove, list --label filter, Desktop chips and filter",
    ),
    'M.TIX-T78': (
        "Ticket query language and saved filters: parser for repo:/type:/status:/label:/approval: and free text, workflow ticket list --query, named saved filters in the database, Desktop filter bar",
        "Ticket query language and saved filters: parser for repo:/type:/status:/label:/approval: and free text, tickets ticket list --query, named saved filters in the database, Desktop filter bar",
    ),
    'M.TIX-T86': (
        "Ticket metrics: throughput, cycle time from ticket_events, open by repo and type over time, in CLI (workflow ticket stats) and a Desktop view with accessible tables",
        "Ticket metrics: throughput, cycle time from ticket_events, open by repo and type over time, in CLI (tickets ticket stats) and a Desktop view with accessible tables",
    ),
    'M.TIX-T87': (
        "Ticket export: workflow ticket list --format csv|md and Desktop Export for the current filter",
        "Ticket export: tickets ticket list --format csv|md and Desktop Export for the current filter",
    ),
    'GG-T99': (
        "Multiple player profiles in GridGameGaiden using the shared MindAttic.Unity package (owner 2026-10-19; requires MAU-T2). Reverses AMENDMENTS 'Settings are per save slot (no profile-level settings)': settings move OUT of each SaveData into the active profile's Profiles/<Name>/settings.json (common keys = volumes/mutes/reduce motion/language; Gaiden-only keys such as battle speed, drag timer, menu theme, colorblind, difficulty under game), and the 3 save slots move under Profiles/<Name>/Saves/slot1-3.json. Reference com.mindattic.unity via file:../../MindAttic.Unity in Packages/manifest.json and make Tests/Gaiden.Core compile the package's engine-free core. Migration: on first launch, existing persistentDataPath/Saves/slot*.json move into a 'Default' profile and the most recently played slot's settings seed its settings.json; nothing is lost, the old folder is kept as Saves.migrated. UI: Title gets a profile picker (current profile name shown; switch / create / rename / delete-with-confirm, as GridGame2026's ProfileSelect/ProfileCreate), code-built like every other screen; Settings edits the profile's settings. Automation/harness: a -profile <name> flag and the existing test root override so harness/tests never touch real profiles; -demo/-testmode use a throwaway profile. Evidence: dotnet tests (migration, per-profile isolation of saves and settings, switching profiles reloads settings), harness sweep screenshots of the picker and Settings, BIBLE (15 Save, AMENDMENTS reversal), USER_STORIES.",
        "Multiple player profiles in GridGameGaiden using the shared Unity.Shared package (owner 2026-10-19; requires MAU-T2). Reverses AMENDMENTS 'Settings are per save slot (no profile-level settings)': settings move OUT of each SaveData into the active profile's Profiles/<Name>/settings.json (common keys = volumes/mutes/reduce motion/language; Gaiden-only keys such as battle speed, drag timer, menu theme, colorblind, difficulty under game), and the 3 save slots move under Profiles/<Name>/Saves/slot1-3.json. Reference com.mindattic.unity.shared via file:../../Unity.Shared/unity/com.mindattic.unity.shared in Packages/manifest.json and make Tests/Gaiden.Core compile the package's engine-free core. Migration: on first launch, existing persistentDataPath/Saves/slot*.json move into a 'Default' profile and the most recently played slot's settings seed its settings.json; nothing is lost, the old folder is kept as Saves.migrated. UI: Title gets a profile picker (current profile name shown; switch / create / rename / delete-with-confirm, as GridGame2026's ProfileSelect/ProfileCreate), code-built like every other screen; Settings edits the profile's settings. Automation/harness: a -profile <name> flag and the existing test root override so harness/tests never touch real profiles; -demo/-testmode use a throwaway profile. Evidence: dotnet tests (migration, per-profile isolation of saves and settings, switching profiles reloads settings), harness sweep screenshots of the picker and Settings, BIBLE (15 Save, AMENDMENTS reversal), USER_STORIES.",
    ),
}

TRIGGER_BODY_SQLSERVER = """CREATE TRIGGER tickets_append_only ON tickets AFTER UPDATE AS
BEGIN
    IF EXISTS (SELECT 1 FROM inserted) AND (UPDATE(id) OR UPDATE(repo) OR UPDATE(number) OR UPDATE(date) OR UPDATE(type) OR UPDATE(summary) OR UPDATE(ordinal))
        AND EXISTS (SELECT 1 FROM deleted d LEFT JOIN inserted i ON i.id = d.id
                    WHERE i.id IS NULL OR i.repo <> d.repo OR ISNULL(i.number, -1) <> ISNULL(d.number, -1) OR i.date <> d.date
                       OR i.type <> d.type OR i.summary <> d.summary OR i.ordinal <> d.ordinal)
        THROW 50000, 'tickets are append-only: only status and ref may change', 1;
END"""


def all_corrections():
    """{id: (old, new)} for every ticket this script corrects."""
    out = dict(EXPLICIT)
    for tid in TOOLKIT_IDS:
        if tid in out:
            continue
        out[tid] = None  # filled in by each backend once it has read the current summary
    return out


# ── SQLite path (this machine's database.json has no SqlServer entry) ──────────────────────

def fix_sqlite(db_path: str) -> int:
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA busy_timeout = 15000")
    cur = con.cursor()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    changed = 0
    try:
        cur.execute("BEGIN IMMEDIATE")
        cur.execute("DROP TRIGGER IF EXISTS tickets_append_only")
        for tid in TOOLKIT_IDS:
            if tid in EXPLICIT:
                continue
            old, = cur.execute("SELECT summary FROM tickets WHERE id = ? COLLATE NOCASE", (tid,)).fetchone()
            if TOOLKIT_OLD not in old:
                raise SystemExit(f"{tid}: expected text not found in its summary.")
            changed += apply_one(cur, now, tid, old, old.replace(TOOLKIT_OLD, TOOLKIT_NEW))
        for tid, (expected_old, new) in EXPLICIT.items():
            old, = cur.execute("SELECT summary FROM tickets WHERE id = ? COLLATE NOCASE", (tid,)).fetchone()
            if old != expected_old:
                raise SystemExit(f"{tid}: current summary doesn't match what this script expects; aborting.")
            changed += apply_one(cur, now, tid, old, new)
        cur.execute("""
            CREATE TRIGGER IF NOT EXISTS tickets_append_only BEFORE UPDATE OF id, repo, number, date, type, summary, ordinal ON tickets
            WHEN NEW.id IS NOT OLD.id OR NEW.repo IS NOT OLD.repo OR NEW.number IS NOT OLD.number OR NEW.date IS NOT OLD.date
              OR NEW.type IS NOT OLD.type OR NEW.summary IS NOT OLD.summary OR NEW.ordinal IS NOT OLD.ordinal
            BEGIN SELECT RAISE(ABORT, 'tickets are append-only: only status and ref may change'); END;
        """)
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()
    return changed


def apply_one(cur, now, tid, old, new):
    if old == new:
        return 0
    cur.execute("UPDATE tickets SET summary = ?, row_md = NULL WHERE id = ? COLLATE NOCASE", (new, tid))
    cur.execute("INSERT INTO ticket_events (ticket_id, at, field, old, new) VALUES (?, ?, 'summary', ?, ?)",
                (tid, now, old, f"{new} ({REASON})"))
    print(f"  {tid}: corrected")
    return 1


# ── SQL Server path (this is the one that actually ran: this workspace's database.json
# pointed at localhost/MindAttic.Tickets at the time) ───────────────────────────────────────

def tsql_str(s: str) -> str:
    return "N'" + s.replace("'", "''") + "'"


def fix_sqlserver(server: str, database: str) -> int:
    rows = query_sqlserver(server, database,
                            "SELECT id, summary FROM tickets WHERE id IN (" +
                            ",".join(tsql_str(t) for t in all_corrections()) + ")")
    current = {r["id"]: r["summary"] for r in rows}

    mapping = {}
    for tid in TOOLKIT_IDS:
        if tid in EXPLICIT:
            continue
        old = current[tid]
        if TOOLKIT_OLD not in old:
            raise SystemExit(f"{tid}: expected text not found in its summary.")
        mapping[tid] = (old, old.replace(TOOLKIT_OLD, TOOLKIT_NEW))
    for tid, (expected_old, new) in EXPLICIT.items():
        old = current[tid]
        if old != expected_old:
            raise SystemExit(f"{tid}: live summary doesn't match what this script expects; aborting.")
        mapping[tid] = (old, new)

    lines = ["SET NOCOUNT ON;", "BEGIN TRY", "    BEGIN TRANSACTION;", "    DROP TRIGGER IF EXISTS tickets_append_only;"]
    for tid, (old, new) in mapping.items():
        new_event = f"{new} ({REASON})"
        lines += [
            f"    IF NOT EXISTS (SELECT 1 FROM tickets WHERE id = {tsql_str(tid)} AND summary = {tsql_str(old)})",
            f"        THROW 50000, {tsql_str(tid + ': summary changed since this script was checked; aborting.')}, 1;",
            f"    UPDATE tickets SET summary = {tsql_str(new)}, row_md = NULL WHERE id = {tsql_str(tid)};",
            "    INSERT INTO ticket_events (ticket_id, at, field, old, new) VALUES "
            f"({tsql_str(tid)}, FORMAT(SYSUTCDATETIME(), 'yyyy-MM-ddTHH:mm:ssZ'), 'summary', {tsql_str(old)}, {tsql_str(new_event)});",
        ]
    lines += [
        f"    IF OBJECT_ID(N'tickets_append_only', N'TR') IS NULL EXEC ({tsql_str(TRIGGER_BODY_SQLSERVER)});",
        "    COMMIT TRANSACTION;",
        f"    PRINT 'OK: committed {len(mapping)} ticket summary corrections';",
        "END TRY",
        "BEGIN CATCH",
        "    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;",
        "    PRINT 'FAILED: ' + ERROR_MESSAGE();",
        "    THROW;",
        "END CATCH",
    ]
    run_sqlserver_script(server, database, "\n".join(lines))
    return len(mapping)


def query_sqlserver(server, database, sql):
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(sql)
        path = f.name
    try:
        out = subprocess.run(
            ["sqlcmd", "-S", server, "-d", database, "-E", "-C", "-i", path, "-s", "\x1f", "-W", "-h", "-1"],
            capture_output=True, text=True, check=True,
        ).stdout
        rows = []
        for line in out.splitlines():
            if not line.strip() or line.startswith("("):
                continue
            cells = line.split("\x1f")
            if len(cells) >= 2:
                rows.append({"id": cells[0], "summary": cells[1]})
        return rows
    finally:
        os.unlink(path)


def run_sqlserver_script(server, database, script):
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(script)
        path = f.name
    try:
        subprocess.run(["sqlcmd", "-S", server, "-d", database, "-E", "-C", "-i", path], check=True)
    finally:
        os.unlink(path)


def main():
    config_file = os.path.join(os.environ["APPDATA"], "MindAttic", "MindAttic.Tickets", "database.json")
    server_env = os.environ.get("MINDATTIC_TICKETS_SQLSERVER")
    connection = None
    if server_env and server_env.lower() != "off":
        connection = server_env
    elif not server_env and os.path.exists(config_file):
        with open(config_file, encoding="utf-8") as f:
            connection = json.load(f).get("SqlServer")

    if connection:
        # "Server=localhost;Database=MindAttic.Tickets;..." -> (server, database)
        parts = dict(p.split("=", 1) for p in connection.split(";") if "=" in p)
        server = parts.get("Server") or parts.get("Data Source") or "localhost"
        database = parts.get("Database") or parts.get("Initial Catalog") or "MindAttic.Tickets"
        changed = fix_sqlserver(server, database)
    else:
        db_path = (os.environ.get("MINDATTIC_TICKETS_DB") or os.environ.get("MINDATTIC_WORKFLOW_DB")
                   or r"D:\Projects\MindAttic\MindAttic.Tickets\data\Tickets.db")
        changed = fix_sqlite(db_path)

    print(f"\nDone: {changed} ticket summaries corrected.")


if __name__ == "__main__":
    sys.exit(main())
