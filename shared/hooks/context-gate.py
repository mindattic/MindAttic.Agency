#!/usr/bin/env python3
# MindAttic.Orchestrator's context gate (written by the orchestrator; edits are overwritten).
# Records each session's turn state, which the orchestrator reads to save, clear and reload a session
# whose context is past the cycle point once its turn is over.
import json, os, re, sys, time
from datetime import datetime, timezone
from pathlib import Path

DIR = Path.home() / ".claude" / "session-context"
PERCENT = 80
# Claude Code kills this hook at 60s (M.ORCH-T1005): its slow asks (the ticket database, the workspace scan,
# `orchestrator next`) all fit inside this, counted from the script's start, with room left to save and answer.
STARTED = time.monotonic()
BUDGET = 45

def time_left():
    return BUDGET - (time.monotonic() - STARTED)

# What `orchestrator next` is kept, out of the budget, at a Stop (M.ORCH-T1045): its 30s and its start. The cheap first looks
# (the ticket database, the workspace scan) get only what's left over, so next always gets its slice.
NEXT_SLICE = 32

def cheap_left():
    return time_left() - NEXT_SLICE
KEEP_GOING = True
# The orchestrator's database (M.ORCH-T524), found as OrchestratorDb.StatePath finds it: MINDATTIC_ORCHESTRATOR_DB when
# set, else the main checkout's data/orchestrator.db under the default workspace (never a worktree's copy), else the
# machine-local one beside the old JSON files.
ORCH_DIR = Path(os.environ.get("APPDATA", "")) / "MindAttic" / "MindAttic.Orchestrator"
def orchestrator_db():
    if os.environ.get("MINDATTIC_ORCHESTRATOR_DB"):
        return os.environ["MINDATTIC_ORCHESTRATOR_DB"]
    repo = Path(r"D:\Projects\MindAttic") / "MindAttic.Orchestrator"
    if repo.is_dir():
        return str(repo / "data" / "orchestrator.db")
    return str(ORCH_DIR / "orchestrator.db")
ORCH_DB = orchestrator_db()
_held = {}  # "long": a read already waited and found the database held; "at": when a mark's read last did
# One budget for every wait on the database in a hook run (M.ORCH-T653): a hook's several reads each waited out their
# own timeout while a write held it (25s in all). The waits that found it locked add up here; once DB_BUDGET seconds
# are spent, every access goes straight to the files without connecting.
DB_BUDGET = 3.0
_db_spent = [0.0]
def db_connect(timeout, **kw):
    import sqlite3
    left = DB_BUDGET - _db_spent[0]
    if left <= 0:
        raise sqlite3.OperationalError("database is locked (budget spent)")
    return sqlite3.connect(ORCH_DB, timeout=max(0.05, min(timeout, left)), **kw)
def db_locked(e, started):
    # Counts the time a use of the database waited when it found it locked.
    if "locked" in str(e) and "budget spent" not in str(e):
        _db_spent[0] += time.monotonic() - started
def orch_rows(sql, args=(), timeout=5):
    # Rows from the orchestrator's database; None when it isn't there (a read never creates it) or couldn't be read
    # (held by a write past timeout seconds, or from before the table).
    try:
        import sqlite3
        if not os.path.isfile(ORCH_DB):
            return None
        started = time.monotonic()
        try:
            db = db_connect(min(timeout, 1) if _held.get("long") else timeout)
            try:
                return db.execute(sql, args).fetchall()
            finally:
                db.close()
        except Exception as e:
            db_locked(e, started)
            raise
    except Exception as e:
        if "locked" in str(e):
            _held["long"] = True
        return None
def orch_settings():
    # The orchestrator's settings, one row per setting; a settings.json no daemon has read in yet is read instead.
    rows = orch_rows("SELECT name, value FROM settings")
    if rows:
        out = {}
        for name, value in rows:
            try:
                out[name] = json.loads(value)
            except Exception:
                pass
        return out
    try:
        s = json.loads((ORCH_DIR / "settings.json").read_text(encoding="utf-8-sig"))
        return s if isinstance(s, dict) else {}
    except Exception:
        return {}
def orch_state(name, max_age=None):
    # A state value the orchestrator keeps (allocate holds, stale claims, ...); None when it isn't kept, can't be read,
    # or was written more than max_age seconds ago (a daemon that stopped). Its old file until a daemon reads it in.
    rows = orch_rows("SELECT value, written_at FROM state WHERE name = ?", (name,))
    if rows:
        value, at = rows[0]
        if max_age is not None and time.time() - at > max_age:
            return None
        try:
            return json.loads(value)
        except Exception:
            return None
    f = ORCH_DIR / (name + ".json")
    try:
        if max_age is not None and time.time() - f.stat().st_mtime > max_age:
            return None
        return json.loads(f.read_text(encoding="utf-8-sig"))
    except Exception:
        return None
GATE_LOG = Path.home() / ".claude" / "session-context" / "pace-gate.jsonl"
def log_gate_event(at, decision, held, tool, percent, account=None):
    # One of the pace gate's events (a hold, a refusal, an exempt call, a prompt answered at the stop) for the pace
    # ledger (M.ORCH-T526): a row of the database's gate_events; appended to the old pace-gate.jsonl instead when the
    # database can't take it right now (held past a short wait, or from before the table), which the daemon reads in.
    # Tagged with the Claude login it ran for (M.ORCH-T774), so a per-CLI login's own window counts only its own gate
    # events, not another account's sharing the same machine-wide log.
    try:
        import sqlite3
        if os.path.isfile(ORCH_DB):
            started = time.monotonic()
            try:
                db = db_connect(2)
                try:
                    db.execute("INSERT INTO gate_events (at, decision, held, tool, percent, account) VALUES (?, ?, ?, ?, ?, ?)",
                               (at, decision, float(held), tool, percent if isinstance(percent, (int, float)) else None, account or None))
                    db.commit()
                    return
                finally:
                    db.close()
            except Exception as e:
                db_locked(e, started)
    except Exception:
        pass
    try:
        GATE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(GATE_LOG, "a", encoding="utf-8") as log:
            log.write(json.dumps({"at": at, "decision": decision, "held": held, "tool": tool, "percent": percent, "account": account}) + "\n")
    except Exception:
        pass
def state_tx(timeout=2, table="state"):
    # The orchestrator's database with a write transaction open on it, for a mark the hooks keep in it (M.ORCH-T528);
    # None when it isn't there, is from before the table, or stays held past timeout seconds.
    try:
        import sqlite3
        if not os.path.isfile(ORCH_DB):
            return None
        db = db_connect(timeout, isolation_level=None)
    except Exception:
        return None
    started = time.monotonic()
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute("SELECT 1 FROM " + table + " LIMIT 0")
        return db
    except Exception as e:
        db_locked(e, started)
        db.close()
        return None
def mark_file(path):
    # A mark's old JSON object file; {} when there's none (or it can't be read).
    try:
        for _ in range(20):
            try:
                value = json.loads(path.read_text(encoding="utf-8-sig"))
                return value if isinstance(value, dict) else {}
            except PermissionError:
                time.sleep(0.05)
    except Exception:
        pass
    return {}
def mark_text(path):
    # A mark file's text; None when there's none (or it can't be read).
    for _ in range(20):
        try:
            return path.read_text(encoding="utf-8-sig")
        except PermissionError:
            time.sleep(0.05)
        except Exception:
            return None
    return None
def retire_mark_file(path, seen):
    # Moves a mark's file aside as .bak once its text (seen) is in the row, only if it still holds that text
    # (M.ORCH-T544): another hook whose write found the database held may have written it since. It's claimed by a
    # rename first, so a write meanwhile lands as a new file; a claim that isn't what was read goes back.
    claim = path.with_name(path.name + "." + str(os.getpid()) + ".retiring")
    try:
        os.rename(path, claim)
    except Exception:
        return
    bak = path.with_name(path.name + ".bak")
    try:
        if mark_text(claim) == seen:
            os.replace(claim, bak)
            return
        try:
            os.rename(claim, path)  # not when a newer one is already there: that one is kept
        except FileExistsError:
            os.replace(claim, bak)
    except Exception:
        pass
_marks_read, _unknown = {}, set()
def mark_rows(key, sql, args):
    # A mark's rows (M.ORCH-T542): [] without a database or from before its table. A database held by another write (it's
    # read on every call) isn't waited on long once this hook has read the mark: its copy stands in, and while it was held
    # a moment ago it isn't asked again (a check reads several marks). A fresh hook has no copy, so it waits longer, once,
    # unless a read here already waited and found it held; still held, it's None and the key is in _unknown: the files are
    # all a reader has, and nothing is written from a value that couldn't be read.
    import sqlite3
    if not os.path.isfile(ORCH_DB):
        return []
    def query(timeout):
        started = time.monotonic()
        try:
            db = db_connect(timeout)
            try:
                return db.execute(sql, args).fetchall()
            finally:
                db.close()
        except sqlite3.OperationalError as e:
            db_locked(e, started)
            return [] if "no such table" in str(e) else None
        except Exception:
            return None
    if time.monotonic() - _held.get("at", -60.0) <= 5:
        if key in _marks_read:
            return _marks_read[key]
        _unknown.add(key)
        return None
    rows = query(1)
    if rows is None and key not in _marks_read and not _held.get("long"):
        rows = query(5)
        _held["long"] = rows is None
    if rows is None:
        _held["at"] = time.monotonic()
        if key in _marks_read:
            return _marks_read[key]
        _unknown.add(key)
        return None
    _marks_read[key] = rows
    _unknown.discard(key)
    return rows
def hook_mark(name, path):
    # A mark the hooks keep (the stop latch, when a key was set aside: M.ORCH-T528): its state row in the orchestrator's
    # database, with the entries of its old file over it, a file being one no hook has read in yet or one a hook kept
    # while the database was held (newer, so it wins). The file is read first: a write reading it in commits the row
    # before it moves the file aside, so a hook reading meanwhile sees the entries in one or the other.
    found = mark_file(path)
    value = {}
    rows = mark_rows(name, "SELECT value FROM state WHERE name = ?", (name,))
    if rows:
        try:
            v = json.loads(rows[0][0])
            value = v if isinstance(v, dict) else {}
        except Exception:
            pass
    value.update(found)
    return json.loads(json.dumps(value))
def change_hook_mark(name, path, change):
    # Applies change (a function of the mark's entries returning the new entries, or None for no change) as one write
    # transaction on its state row, reading its old file in (kept as .bak) the first time. While the database is held
    # past a short wait, missing or from before the state table, the file is written as before, and read in later.
    # Nothing is written when change has nothing to do.
    if change(json.loads(json.dumps(hook_mark(name, path)))) is None and not path.exists():
        return
    db = state_tx()
    if db is not None:
        try:
            rows = db.execute("SELECT value FROM state WHERE name = ?", (name,)).fetchall()
            value = {}
            if rows:
                try:
                    v = json.loads(rows[0][0])
                    value = v if isinstance(v, dict) else {}
                except Exception:
                    pass
            seen = mark_text(path)
            try:
                found = json.loads(seen) if seen is not None else {}
            except Exception:
                found = {}
            value.update(found if isinstance(found, dict) else {})
            new = change(json.loads(json.dumps(value)))
            if new is None and seen is None:
                db.execute("ROLLBACK")
                return
            db.execute("INSERT OR REPLACE INTO state (name, value, written_at) VALUES (?, ?, ?)",
                       (name, json.dumps(value if new is None else new), time.time()))
            db.execute("COMMIT")
            if seen is not None:
                retire_mark_file(path, seen)
            return
        except Exception:
            try:
                db.execute("ROLLBACK")
            except Exception:
                pass
        finally:
            db.close()
    current = hook_mark(name, path)
    if name in _unknown:
        return  # the row couldn't be read: a file made from the rest would lose what it holds (M.ORCH-T542)
    new = change(json.loads(json.dumps(current)))
    if new is not None:
        write_json(path, new)
def exported_mark(name, path, table="state", key="name"):
    # A mark kept as a state row and still exported as its file for readers outside the orchestrator (the billing mode
    # for the Launcher, the account record for the statusline: M.ORCH-T528, Settings.ExportedState): whichever of the
    # two was written later; None when there's neither. A database held by a write isn't waited on long.
    row = None
    rows = orch_rows("SELECT value, written_at FROM " + table + " WHERE " + key + " = ?", (name,), timeout=1)
    if rows:
        try:
            row = (json.loads(rows[0][0]), float(rows[0][1]))
        except Exception:
            pass
    try:
        at = path.stat().st_mtime
        if row is None or at >= row[1]:
            return read_json(path)
    except Exception:
        pass
    return row[0] if row else None
def write_exported_mark(name, path, value, table="state", key="name"):
    # The row in one write transaction (when the database takes it), then the exported file.
    db = state_tx(table=table)
    if db is not None:
        try:
            db.execute("INSERT OR REPLACE INTO " + table + " (" + key + ", value, written_at) VALUES (?, ?, ?)", (name, json.dumps(value), time.time()))
            db.execute("COMMIT")
        except Exception:
            try:
                db.execute("ROLLBACK")
            except Exception:
                pass
        finally:
            db.close()
    write_json(path, value)
CLI_MARKS_DIR = Path.home() / ".claude" / "session-context"
def cli_marks(kind):
    # {pid: value} of one kind of per-CLI mark ("allocate", "noallocate", "crossrepo": M.ORCH-T528): the database's
    # cli_marks rows, with any <kind>-<pid> file over them (one the daemon hasn't read in yet, or one kept while the
    # database was held: newer either way), less those a <kind>-<pid>.cleared file says were removed while it was held.
    # The files are listed first: the daemon reading one in commits its row before it moves the file aside.
    files, cleared = {}, set()
    try:
        for f in CLI_MARKS_DIR.glob(kind + "-*"):
            rest = f.name[len(kind) + 1:]
            try:
                if rest.isdigit():
                    files[rest] = f.read_text(encoding="utf-8", errors="replace")
                elif rest.endswith(".cleared") and rest[:-len(".cleared")].isdigit():
                    cleared.add(rest[:-len(".cleared")])
            except Exception:
                pass
    except Exception:
        pass
    rows = mark_rows("cli:" + kind, "SELECT pid, value FROM cli_marks WHERE kind = ?", (kind,)) or []
    out = {str(pid): str(value) for pid, value in rows if str(pid) not in cleared}
    out.update(files)
    return out
def cli_mark_since(kind):
    # {pid: when it was first written} for each CLI's mark of the kind (M.ORCH-T558: /allocate warms up from when it
    # turned on): its row's since (written_at from before the column), or for a mark only a file holds, the file's time.
    # Read through the gate's deciding transaction while one is open (TX_SINCE).
    marks = cli_marks(kind)
    rows = {}
    def query(sql):
        if TX_SINCE[0] is not None:
            return TX_SINCE[0].execute(sql, (kind,)).fetchall()
        return orch_rows(sql, (kind,), timeout=1)
    try:
        got = query("SELECT pid, COALESCE(since, written_at) FROM cli_marks WHERE kind = ?")
    except Exception:
        got = None
    if got is None:
        try:
            got = query("SELECT pid, written_at FROM cli_marks WHERE kind = ?")
        except Exception:
            got = None
    for pid, at in got or []:
        try:
            rows[str(pid)] = float(at)
        except Exception:
            pass
    out = {}
    for pid in marks:
        f = CLI_MARKS_DIR / (kind + "-" + pid)
        try:
            at = f.stat().st_mtime if f.exists() else None
        except Exception:
            at = None
        row = rows.get(pid)
        if (CLI_MARKS_DIR / (kind + "-" + pid + ".cleared")).exists() and at is not None:
            row = None
        out[pid] = min(t for t in (row, at) if t is not None) if (row is not None or at is not None) else time.time()
    return out
TX_SINCE = [None]  # the gate's deciding transaction while one is open: cli_mark_since reads through it
def cli_mark(kind, pid):
    # This CLI's mark of the kind (its text), or None when it has none.
    return cli_marks(kind).get(str(pid)) if pid else None
def may_have_cli_mark(kind, pid):
    # Whether this CLI has (or, its rows unreadable, may have) a mark of the kind: a removal goes ahead either way.
    return cli_mark(kind, pid) is not None or "cli:" + kind in _unknown
def set_cli_mark(kind, pid, value):
    # Sets (or with None, removes) a CLI's mark: its cli_marks row in one write transaction, any file for it gone; the
    # file while the database is held past a short wait, missing or older (a removal then leaves <kind>-<pid>.cleared).
    # False when neither could be written.
    if not pid:
        return
    f = CLI_MARKS_DIR / (kind + "-" + str(pid))
    gone = CLI_MARKS_DIR / (kind + "-" + str(pid) + ".cleared")
    def drop(p):
        try:
            if p.exists():
                p.unlink()
        except Exception:
            pass
    db = state_tx(table="cli_marks")
    if db is not None:
        try:
            if value is None:
                db.execute("DELETE FROM cli_marks WHERE kind = ? AND pid = ?", (kind, int(pid)))
            else:
                # A mark already there keeps when it was first written (M.ORCH-T558: /allocate warms up from when it
                # turned on); a new one is from now, or from its file kept while the database was held. One removed
                # while it was held (its .cleared file) starts again. A database from before the column is written as before.
                now = time.time()
                try:
                    first = f.stat().st_mtime if f.exists() and not gone.exists() else now
                except Exception:
                    first = now
                try:
                    if gone.exists():
                        db.execute("DELETE FROM cli_marks WHERE kind = ? AND pid = ?", (kind, int(pid)))
                    db.execute("INSERT INTO cli_marks (kind, pid, value, written_at, since) VALUES (?, ?, ?, ?, ?) "
                               "ON CONFLICT (kind, pid) DO UPDATE SET value = excluded.value, written_at = excluded.written_at, "
                               "since = MIN(COALESCE(cli_marks.since, cli_marks.written_at), excluded.since)",
                               (kind, int(pid), str(value), now, first))
                except Exception as e:
                    if "since" not in str(e):
                        raise
                    db.execute("INSERT OR REPLACE INTO cli_marks (kind, pid, value, written_at) VALUES (?, ?, ?, ?)", (kind, int(pid), str(value), now))
            db.execute("COMMIT")
            drop(f)
            drop(gone)
            return True
        except Exception:
            try:
                db.execute("ROLLBACK")
            except Exception:
                pass
        finally:
            db.close()
    def write(p, text):
        # A file held open by another process for a moment is retried; one held longer isn't written (M.ORCH-T545:
        # the error went up through the context gate, which isn't inside a try where it's called).
        for _ in range(20):
            try:
                p.write_text(text, encoding="utf-8")
                return True
            except PermissionError:
                time.sleep(0.05)
            except Exception:
                return False
        return False
    try:
        CLI_MARKS_DIR.mkdir(parents=True, exist_ok=True)
    except Exception:
        return False
    if value is None:
        drop(f)
        if os.path.isfile(ORCH_DB):
            return write(gone, "")
    else:
        if not write(f, str(value)):
            return False
        drop(gone)
    return True
def slot_db(timeout=3):
    # The orchestrator's database with a write transaction open on it, for the subagent slots and wants (M.ORCH-T527):
    # a pace gate's check and the slot it takes are one transaction, so Agent calls sent together queue on SQLite's
    # lock instead of the old subagent-slots.lock file. None when the database isn't there, is from before the tables,
    # or stays held past timeout seconds: the gate keeps its slot as a file then, which every gate counts too.
    # None for a CLI on its own login (M.ORCH-T559): its slots are files in its account's folder, apart from every
    # other account's.
    if globals().get("PROFILE_DIR"):
        return None
    try:
        import sqlite3
        if not os.path.isfile(ORCH_DB):
            return None
        # Not held to the run's wait budget (M.ORCH-T653): the slot claim has no file fallback that
        # keeps the allowance, so it waits its own timeout.
        db = sqlite3.connect(ORCH_DB, timeout=timeout, isolation_level=None)
    except Exception:
        return None
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute("SELECT 1 FROM subagent_slots, subagent_wants LIMIT 0")
        return db
    except Exception:
        db.close()
        return None
def slot_done(db, commit=True):
    # Ends slot_db's transaction; False when its writes didn't go in.
    ok = True
    try:
        db.execute("COMMIT" if commit else "ROLLBACK")
    except Exception:
        ok = False
    try:
        db.close()
    except Exception:
        pass
    return ok and commit
def slot_sql(tx, sql, args=()):
    # One statement on the slot tables: in the open transaction tx when there is one, else its own short one. False
    # when the database can't take it (the caller keeps a file instead).
    if tx is not None:
        tx.execute(sql, args)
        return True
    db = slot_db(2)
    if db is None:
        return False
    try:
        db.execute(sql, args)
    except Exception:
        slot_done(db, False)
        return False
    return slot_done(db)
def release_oldest_slot(cli, marks):
    # SubagentStart: the subagent's mark now counts it, so this CLI's oldest slot (a row, or a file a gate kept while
    # the database was held) is let go.
    mine = str(cli) + "-"
    held = []
    try:
        for f in (marks / "subagent-slots").iterdir():
            try:
                if f.name.startswith(mine):
                    held.append((int(f.name.split("-")[1]), f))
            except Exception:
                pass
    except Exception:
        pass
    db = slot_db()
    try:
        if db is not None:
            held += [(int(ns), rid) for rid, ns in db.execute("SELECT id, taken_ns FROM subagent_slots WHERE cli = ?", (str(cli),))]
        if held:
            oldest = min(held, key=lambda h: h[0])[1]
            if isinstance(oldest, int):
                db.execute("DELETE FROM subagent_slots WHERE id = ?", (oldest,))
            else:
                oldest.unlink()
    except Exception:
        pass
    finally:
        if db is not None:
            slot_done(db)
def orch_assignments():
    # The tickets the orchestrator has handed out; assignments.json until a daemon reads it in.
    f = ORCH_DIR / "assignments.json"
    rows = orch_rows("SELECT ticket_id FROM assignments")
    if rows is not None and (rows or not f.exists()):
        return [r[0] or "" for r in rows]
    try:
        return [(a.get("TicketId") or "") for a in json.loads(f.read_text(encoding="utf-8-sig")) or []]
    except Exception:
        return []

# The folders the orchestrator is set to (settings' WorkspaceRoot and WorktreeRoot), not always the default ones
# (M.ORCH-T409); MINDATTIC_WORKSPACE still overrides both, its worktrees beside it as before.
def orchestrator_roots():
    if os.environ.get("MINDATTIC_WORKSPACE"):
        return (os.environ["MINDATTIC_WORKSPACE"], None)
    s = orch_settings()
    return (s.get("WorkspaceRoot") or None, s.get("WorktreeRoot") or None)
_ws_root, _wt_root = orchestrator_roots()
WS = Path(_ws_root or "D:/Projects/MindAttic")
WT = Path(_wt_root) if _wt_root else WS.parent / (WS.name + ".worktrees")
# The ticket database the orchestrator and the tickets CLI open (M.ORCH-T398): MINDATTIC_TICKETS_DB when set (or
# MINDATTIC_WORKFLOW_DB, its name before the rename), else MindAttic.Tickets\data\Tickets.db, in the MindAttic.Workflow
# folder while only that one exists, as TicketsDb.DefaultPath/HomeFolder find it (M.ORCH-T564).
def tickets_home():
    return "MindAttic.Workflow" if not (WS / "MindAttic.Tickets").is_dir() and (WS / "MindAttic.Workflow").is_dir() else "MindAttic.Tickets"
TICKETS_DB = (os.environ.get("MINDATTIC_TICKETS_DB") or os.environ.get("MINDATTIC_WORKFLOW_DB")
              or str(WS / tickets_home() / "data" / "Tickets.db"))
def tickets_db(timeout=5.0):
    # The ticket database opened read-only: a missing one raises instead of being created empty (M.ORCH-T546). A caller
    # on a time budget passes how long a locked read may wait.
    import sqlite3
    return sqlite3.connect(Path(os.path.abspath(TICKETS_DB)).as_uri() + "?mode=ro", uri=True, timeout=timeout)

def repo_of(path, worktrees=True):
    # A repo checkout under the workspace, or (with worktrees) one of /allocate's worktrees of it; None elsewhere.
    try:
        # Git Bash's /d/Projects/... is D:/Projects/... (Windows Python would read it as a folder on this drive).
        p = Path(re.sub(r"^/([a-zA-Z])(?=/|$)", r"\1:", str(path))).resolve()
    except Exception:
        return None
    for base, in_ws in ((WS, True), (WT, False)):
        if not (in_ws or worktrees):
            continue
        try:
            rel = p.relative_to(base.resolve())
        except Exception:
            continue
        if not rel.parts:
            return None
        name = rel.parts[0]
        if in_ws and not (base / name / ".git").exists():
            return None
        return name
    return None

_canonical_repo_cache = {}
def canonical_repo(name):
    # name's current name, by the ticket database's repo rename history (repo_renames): the same chain
    # TicketsDb's own rename resolver follows for a former repo name (M.ORCH-T565). A repo's folder on disk
    # is renamed by hand, sometime after `tickets repo rename` moves every ticket to the new name there, so
    # a window still standing in the old folder (or a ticket, or a typed --repo, naming the old one) would
    # otherwise look like a different repo from the one the ticket database now calls it. Cached per name
    # for this call: the chain is walked at most once per name per hook invocation.
    key = (name or "").lower()
    if not key:
        return name
    if key in _canonical_repo_cache:
        return _canonical_repo_cache[key]
    cur, seen = name, {key}
    try:
        db = tickets_db()
        try:
            while True:
                row = db.execute("SELECT new_name FROM repo_renames WHERE old_name = ? COLLATE NOCASE ORDER BY seq DESC LIMIT 1", (cur,)).fetchone()
                if not row or row[0].lower() in seen:
                    break
                cur = row[0]
                seen.add(cur.lower())
        finally:
            db.close()
    except Exception:
        pass
    _canonical_repo_cache[key] = cur
    return cur

def same_repo(a, b):
    # Whether a and b name the same repo: the same folder, or one a former name of the other's current one
    # (M.ORCH-T565), so a rename doesn't make a window refuse its own repo's tickets until its folder catches up.
    if not a or not b:
        return False
    return a.lower() == b.lower() or canonical_repo(a).lower() == canonical_repo(b).lower()
SESSION_MARKS = Path.home() / ".claude" / "session-context"
# What the user's typed prompt asks for by name ("use crossrepo for X", "turn auto-pilot on", or the command itself).
ASKS_FOR = {"crossrepo": re.compile(r"\bcross[\s_-]?repos?\b", re.I), "allocate": re.compile(r"\bauto[\s_-]?pilot\b|\ballocate\b", re.I)}
def asked_for(prompt):
    return sorted(k for k, r in ASKS_FOR.items() if r.search(prompt or ""))
def session_state(sid):
    sid = re.sub(r"[^A-Za-z0-9_.-]", "_", str(sid or ""))
    if not sid:
        return {}
    # Its session_states row or its exported .state.json, whichever was written later (M.ORCH-T528).
    try:
        value = exported_mark(sid, SESSION_MARKS / (sid + ".state.json"), table="session_states", key="session_id")
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}
def allocate_repos(pid):
    # What /allocate turned on in THIS CLI (its repos, or "*"): it works them through its own subagents.
    # Never another CLI's: one you're using is never pushed onto tickets because its repo was named elsewhere.
    # Its cli_marks row (M.ORCH-T528), or its allocate-<pid> file as cli_marks reads it.
    try:
        return [n.strip() for n in (cli_mark("allocate", pid) or "").split(",") if n.strip()] if pid else []
    except Exception:
        return []
ALLOCATE_NOTE = [None]
def known_clis():
    # {pid: {"sessions": [ids], "cwd": its latest cwd}} of every CLI still running that a session's state (its
    # session_states row or .state.json) or an /allocate mark names (M.ORCH-T599).
    found = {}
    def add(sid, s, at):
        if not isinstance(s, dict) or not str(s.get("pid") or "").isdigit():
            return
        e = found.setdefault(str(s["pid"]), {"sessions": [], "cwd": None, "at": -1.0})
        if sid and sid not in e["sessions"]:
            e["sessions"].append(sid)
        if s.get("cwd") and at > e["at"]:
            e["cwd"], e["at"] = s.get("cwd"), at
    try:
        for sid, value, at in orch_rows("SELECT session_id, value, written_at FROM session_states", (), timeout=1) or []:
            try:
                add(str(sid), json.loads(value), float(at))
            except Exception:
                pass
    except Exception:
        pass
    try:
        for f in SESSION_MARKS.glob("*.state.json"):
            try:
                add(f.name[:-len(".state.json")], json.loads(f.read_text(encoding="utf-8")), f.stat().st_mtime)
            except Exception:
                pass
    except Exception:
        pass
    for kind in ("allocate", "noallocate"):
        try:
            for each in cli_marks(kind):
                found.setdefault(str(each), {"sessions": [], "cwd": None, "at": -1.0})
        except Exception:
            pass
    return {p: e for p, e in found.items() if process_started(p) is not None}
def cli_label(pid, cwd):
    r = repo_of(cwd) if cwd else None
    return "CLI " + str(pid) + (" (" + r + ")" if r else "")
def set_allocate(pid, args, cwd):
    # /allocate [off|all] [-repo=A,B] [-target=X,Y|others|all] (M.ORCH-T599): -target names the CLIs whose own records
    # change (PIDs, session ids or a CLI's repo or folder name; "others" is every CLI but this one, "all" every one);
    # without it, this CLI's alone. ALLOCATE_NOTE says which it changed and any target that matched none.
    ALLOCATE_NOTE[0] = None
    m = re.search(r"(?:^|\s)-{1,2}targets?\b\s*[=:]?\s*(\[[^\]]*\]|\"[^\"]*\"|'[^']*'|\S+(?:\s*,\s*\S+)*)", args, re.I)
    if not m:
        return set_allocate_one(pid, args, cwd)
    # "off all" with a -target is off for those targets: -target=all is how every CLI is named.
    rest = re.sub(r"^off\s+all\b", "off", (args[:m.start()] + " " + args[m.end():]).strip(), flags=re.I)
    wanted = [t.strip(" \t.;:'\"`()[]<>") for t in re.split(r"[\s,]+", m.group(1).strip("[]\"'"))]
    wanted = [t for t in wanted if t]
    if not wanted:
        return "/allocate -target= names the CLIs (PIDs or session ids or names, comma-separated), others or all. Nothing changed."
    clis = known_clis()
    me = str(pid or "")
    if me:
        clis.setdefault(me, {"sessions": [], "cwd": cwd, "at": -1.0})
        clis[me]["cwd"] = cwd or clis[me]["cwd"]
    import fnmatch
    picked, missed = [], []
    for t in wanted:
        low = t.lower()
        if low in ("all", "*", "every", "everyone"):
            hits = list(clis)
        elif low in ("others", "other", "rest"):
            hits = [p for p in clis if p != me]
        elif low in ("this", "me", "self", "here"):
            hits = [me] if me else []
        elif t.isdigit():
            hits = [t] if t in clis else []
        else:
            hits = []
            for p, e in clis.items():
                c = e.get("cwd") or ""
                names = [n.lower() for n in (repo_of(c) if c else None, Path(c).name if c else None) if n]
                if (any(s.lower() == low or (len(low) >= 4 and s.lower().startswith(low)) for s in e["sessions"])
                        or any(n == low or fnmatch.fnmatchcase(n, low) for n in names)):
                    hits.append(p)
        if not hits:
            missed.append(t)
        for p in hits:
            if p not in picked:
                picked.append(p)
    if not picked:
        return ("/allocate -target=" + ",".join(wanted) + " matched no running CLI, so nothing changed. Name them by PID, session id or "
                "repo (orchestrator clis lists them), or use -target=others or -target=all.")
    changed, refused = [], []
    for p in sorted(picked, key=lambda x: int(x) if x.isdigit() else 0):
        c = clis.get(p, {}).get("cwd") or (cwd if p == me else "")
        if not re.match(r"(off|all)\b", rest, re.I) and not re.search(r"-{1,2}repo\b", rest, re.I) and not repo_of(c or ""):
            refused.append(cli_label(p, c) + ": its repo isn't known, so name the repos with -repo=")
            continue
        why = set_allocate_one(p, rest, c)
        if why:
            refused.append(cli_label(p, c) + ": " + why)
        else:
            changed.append(cli_label(p, c) + (" (this one)" if p == me else ""))
    if not changed:
        return "/allocate -target changed no CLI. " + " ".join(refused)
    what = "off" if re.match(r"off\b", rest, re.I) else "on"
    note = "/allocate " + what + " was recorded for " + ", ".join(changed) + "."
    if refused:
        note += " Not changed: " + "; ".join(refused) + "."
    if missed:
        note += " No running CLI matched " + ", ".join(missed) + "."
    if me not in picked:
        note += " This CLI's own /allocate is unchanged, so don't work any tickets here for it: just say which CLIs changed."
    ALLOCATE_NOTE[0] = note
    return None
def set_allocate_one(pid, args, cwd):
    # /allocate [off|all] [-repo=A,B]: the CLI works those repos' tickets through its own subagents (its own
    # repo when none are named) until /allocate off there. Nothing is marked for any other CLI. A name may be a
    # wildcard (-repo=GTFO.*), kept as typed and matched wherever the repos are read (M.ORCH-T165).
    # Returns why nothing changed, or None once it's recorded.
    import fnmatch
    if re.search(r"-{1,2}repos\b", args, re.I):
        # The -repos alias is gone (it read as a different switch); say so rather than guess what was meant.
        return "/allocate takes -repo=A,B (wildcards too: -repo=GTFO.*); -repos is gone. Nothing changed: type it again with -repo."
    names = allocate_repos(pid)
    if "cli:allocate" in _unknown:
        # Its row couldn't be read (M.ORCH-T542): a list made from nothing would drop the repos it already has.
        return "The orchestrator's database is held by another write, so this CLI's /allocate couldn't be read. Nothing changed: type it again in a moment."
    mine = repo_of(cwd or "")
    m = re.search(r"-{1,2}repo\b\s*[=:]?\s*\[?([^\]]*)\]?", args, re.I)
    named = [r.strip() for r in m.group(1).replace(" ", ",").split(",") if r.strip() and r.strip().lower() not in ("on", "off", "this", "all")] if m else ([mine] if mine else [])
    lower = {n.lower() for n in named}
    if re.match(r"off\b", args, re.I):
        # A repo this CLI covers only through "*" or a wildcard can't be switched off on its own: removing its name
        # would change nothing and it would go on being worked, so say so and change nothing.
        covered = [(n, p) for n in named if m for p in names
                   if p.lower() != n.lower() and fnmatch.fnmatchcase(n.lower(), p.lower())]
        if covered and not re.match(r"off\s+all\b", args, re.I):
            n, p = covered[0]
            return (n + " is worked here through /allocate " + ("all" if p == "*" else "-repo=" + p) + ", so it can't be switched "
                    "off on its own. Nothing changed: type /allocate off, then /allocate -repo= with the repos you do want.")
        names = [] if re.match(r"off\s+all\b", args, re.I) or not m else [n for n in names if n.lower() not in lower]
    elif re.match(r"all\b", args, re.I):
        names = ["*"]
    else:
        names = [n for n in names if n != "*" and n.lower() not in lower] + named
    try:
        (SESSION_MARKS / "autopilot.order").unlink()  # the old workspace-wide list: nothing reads it any more
    except Exception:
        pass
    if re.match(r"off\s+all\b", args, re.I):
        for each in cli_marks("allocate"):  # off everywhere: every CLI's, recorded as typed off, each winding down
            try:
                set_cli_mark("noallocate", each, WIND)
                set_cli_mark("allocate", each, None)
            except Exception:
                pass
    if pid and names:
        if set_cli_mark("allocate", pid, ",".join(names)) is False:
            return ("The orchestrator's database is held by another write and this CLI's /allocate file is held open, so it "
                    "couldn't be recorded. Nothing changed: type it again in a moment.")
        if may_have_cli_mark("noallocate", pid):
            set_cli_mark("noallocate", pid, None)
    else:
        if may_have_cli_mark("allocate", pid):
            set_cli_mark("allocate", pid, None)
        if pid and re.match(r"off\b", args, re.I):
            set_cli_mark("noallocate", pid, WIND)
    return None
# A freshly opened CLI starts with /allocate off (M.ORCH-T522, reversing M.ORCH-T476's on-by-default): only a typed
# /allocate marks it.
CROSSREPO_NOTE = [None]
def set_crossrepo(pid, args):
    # /crossrepo <A,B|all> lets this CLI work other repos too (the explicit exception to M.ORCH-T95); /crossrepo off ends it.
    if not pid:
        return None
    if not args or re.match(r"off\b", args, re.I):
        if may_have_cli_mark("crossrepo", pid):
            set_cli_mark("crossrepo", pid, None)
    else:
        # The -repo= form /allocate takes is accepted too, and each name is trimmed of surrounding punctuation
        # ("-repo=A,B." is A and B, M.ORCH-T591): the mark holds clean names the write guard can match.
        body = re.sub(r"^\s*-{1,2}repo\b\s*[=:]?\s*", "", args, flags=re.I)
        names = []
        for r in re.split(r"[\s,;]+", body):
            r = r.strip(" \t.,;:'\"`()[]<>")
            if r and r.lower() not in [n.lower() for n in names]:
                names.append(r)
        if names:
            set_cli_mark("crossrepo", pid, ",".join(names))
            import fnmatch
            def known(n):
                if n in ("*",) or n.lower() == "all":
                    return True
                try:
                    dirs = [d.name for d in WS.iterdir() if (d / ".git").exists()]
                    canon = (canonical_repo(n) or n).lower()
                    return any(fnmatch.fnmatchcase(d.lower(), n.lower()) or d.lower() == canon for d in dirs)
                except Exception:
                    return False
            ok = [n for n in names if known(n)]
            bad = [n for n in names if n not in ok]
            note = "/crossrepo: this CLI may work " + (", ".join(ok) if ok else "no known repo") + "."
            if bad:
                note += " Not a known repo here (check the spelling): " + ", ".join(bad) + "; edits there stay refused."
            CROSSREPO_NOTE[0] = note
        elif may_have_cli_mark("crossrepo", pid):
            set_cli_mark("crossrepo", pid, None)
    return None
# /allocate off winds this CLI down (M.ORCH-T572, which retired /handoff): no new ticket is claimed, the subagents working
# finish, land and close, and once the last of them has, its turn quicksaves this repo's handoff as /quicksave does. Its
# noallocate mark reads WIND until that quicksave, then "" (off, wound down).
WIND = "wind"
# The shared runner's save, as /quicksave runs it.
QUICKSAVE = re.compile(r"prose-agent\.ps1['\"]?\s+(?:-Command\s+)?save\b", re.I)
def winding_down(pid):
    # Whether /allocate off left this CLI to quicksave once its last subagent has landed.
    try:
        return bool(pid) and cli_mark("noallocate", pid) == WIND
    except Exception:
        return False
def wound_down(pid):
    # Its quicksave is made: off stays off, nothing more to save.
    if winding_down(pid):
        set_cli_mark("noallocate", pid, "")
def wind_down_told(repo):
    # What a winding-down CLI is told when its turn ends with none of its subagents still working.
    return ("/allocate is off in this CLI and its last subagent has landed and closed. Quicksave this repo's handoff now, "
            "exactly as /quicksave does: compose Task, Decisions, State and Next for what this CLI was doing and run the shared "
            "runner's save from this CLI's folder (& <workspace root>\\mindattic-agent-standard\\prose-agent.ps1 save "
            "-RepoRoot (Get-Location) -Task '...' -Decisions '...' -State '...' -Next '...'). Then say exactly \"" + repo +
            " quiet, handoff saved\" and end your turn. Start no ticket or subagent.")
def publish_status(kind, payload):
    if os.name != "nt":
        return
    try:
        envelope = dict(kind=kind, v=1, at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), pid=os.getpid(), payload=payload or dict())
        line = json.dumps(envelope) + "\n"
        fd = os.open(r"\\.\pipe\mindattic-orchestrator-status-in-ryand", os.O_WRONLY | getattr(os, "O_BINARY", 0))
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
    except Exception:
        pass

def pacing_off(pid):
    # /pacing off's mark on this CLI (see the /pacing command below): no pace holds until it closes or /pacing on.
    return bool(pid) and (DIR / ("unthrottled-" + str(pid))).exists()

# Every image you paste is kept and linked to the ticket filed from its prompt (M.ORCH-T1117). Claude Code saves a pasted
# image only in the session's temp folder, %TEMP%\claude\<cwd with every non-alphanumeric as ->\<session>\images\<N>.png,
# and the prompt says "[Image #N]" where it was. Each one is copied, once, into the ticket database's data folder (committed
# with it): attachments\_inbox\<session>\<yyyy-MM-dd>-image-<N>.png, and the agent is told to link it from the ticket.
IMAGE_MAX_BYTES = 20 * 1024 * 1024
def save_images(typed, sid, cwd):
    # The line telling the agent where this prompt's images were saved; None when it has none (or none could be saved).
    # Never raises, and gives up past a few seconds: the prompt is never held up or lost over an image.
    try:
        numbers = sorted({int(n) for n in re.findall(r"\[Image #(\d+)\]", typed or "")})
        if not numbers or not re.fullmatch(r"[A-Za-z0-9_.-]+", str(sid or "")):
            return None
        import shutil, tempfile
        base = Path(os.environ.get("CLAUDE_CODE_TMPDIR") or tempfile.gettempdir()) / "claude"
        own = base / re.sub(r"[^A-Za-z0-9]", "-", str(cwd or "")) / str(sid) / "images"
        folders = [own] if own.is_dir() else [f for f in base.glob("*/" + str(sid) + "/images") if f.is_dir()]
        if not folders:
            return None
        inbox = Path(os.path.abspath(TICKETS_DB)).parent / "attachments" / "_inbox" / str(sid)
        started, saved = time.monotonic(), []
        for n in numbers:
            if time.monotonic() - started > 5:
                break
            src = next((f for d in folders for f in sorted(d.glob(str(n) + ".*")) if f.is_file()), None)
            if src is None or src.stat().st_size > IMAGE_MAX_BYTES:
                continue
            kept = next(iter(sorted(inbox.glob("*-image-" + str(n) + ".*"))), None) if inbox.is_dir() else None
            if kept is None:
                inbox.mkdir(parents=True, exist_ok=True)
                kept = inbox / (datetime.now().strftime("%Y-%m-%d") + "-image-" + str(n) + (src.suffix or ".png").lower())
                shutil.copyfile(src, kept)
            saved.append("[Image #" + str(n) + "] " + kept.as_uri())
        if not saved:
            return None
        return ("[Images] This prompt's images are saved: " + ", ".join(saved) + ". Link each as a markdown image, e.g. "
                "![image N](file:///...), in the --description of any ticket you file from this prompt, or with "
                "tickets ticket note <ID> \"<markdown>\" on the ticket the prompt is about. Move them first into "
                "attachments\\<ticket-id>\\ beside _inbox (same name) and link them there; if that's awkward, link them where they are.")
    except Exception:
        return None

def orchestrator_start_lines(pid):
    # What SessionStart tells this CLI about itself, after the "[Billing]" line: add more here as the
    # orchestrator gains more to report at a CLI's start.
    return [
        "[Orchestrator] Pacing is " + ("off" if pacing_off(pid) else "on") + ".",
        "[Orchestrator] Allocation is " + ("on" if allocate_repos(pid) else "off") + ".",
        "[Orchestrator] Crossrepo is " + ("on" if cli_mark("crossrepo", pid) else "off") + ".",
    ]

# A turn ending on one of these is asking for a go-ahead the orchestrator gives itself.
ASKS = re.compile(r"\b(shall i|should i|do you want|want me to|would you like|ready for me to|ok(?:ay)? to (?:start|continue|proceed|go)|"
                  r"let me know (?:if|when|whether)|(?:go ahead|proceed|continue|carry on|keep going)\?)", re.I)

def workable(repos, sid=None):
    # The open fixes and approved tickets of repos (names or wildcards such as GTFO.*; "*": every repo), in ticket order.
    # None when it couldn't tell (no time left for it, the database locked or unreadable): next is then asked instead.
    try:
        import fnmatch, sqlite3
        # Its four reads share what's left of the Stop hook's budget once next's slice is kept back (M.ORCH-T1005,
        # M.ORCH-T1045), so a locked database can't outlast it or eat into next's time.
        spare = cheap_left() - 1
        if spare < 2:
            return None
        db = tickets_db(timeout=max(0.5, min(5.0, spare / 4)))
        try:
            rows = db.execute("SELECT id, type, repo, summary FROM tickets WHERE status = 'open' ORDER BY ordinal").fetchall()
        except sqlite3.OperationalError:  # a database from before tickets had summaries
            rows = [r + (None,) for r in db.execute("SELECT id, type, repo FROM tickets WHERE status = 'open' ORDER BY ordinal").fetchall()]
        # A ticket waiting on another open one isn't handed out by `orchestrator next`, so it isn't work to push on
        # to either: a 'requires' link (tickets ticket block writes them) or "blocked by X" in its summary, as the
        # scheduler reads them (M.ORCH-T762).
        open_ids = {r[0].upper() for r in rows}
        waits = {}
        try:
            for f, t in db.execute("SELECT from_id, to_id FROM links WHERE kind = 'requires'").fetchall():
                waits.setdefault(f.upper(), set()).add(t.upper())
        except Exception:
            pass
        # Only fixes and tickets the user approved are work; the rest wait for their yes. Approval lives in the database's
        # queue (tickets ticket approve, the Tickets Desktop), as the scheduler reads it (M.ORCH-T384).
        try:
            approved = {a.upper() for (a,) in db.execute("SELECT ticket_id FROM ticket_queue WHERE approval = 'approved'").fetchall()}
        except Exception:
            approved = set()
        # An epic (label 'epic') is never work itself, and a ticket requiring one may start once it's approved, not
        # only once it's closed (M.ORCH-T1146), as the scheduler reads them.
        try:
            epics = {e.upper() for (e,) in db.execute("SELECT ticket_id FROM ticket_labels WHERE label = 'epic'").fetchall()}
        except Exception:
            epics = set()
        db.close()
        settings = orch_settings()
        def blocked(r):
            on = waits.get(r[0].upper(), set()) | {m.upper() for m in re.findall(r"blocked by ((?:[A-Z]\.)?[A-Z][A-Z0-9]*-T\d+)", r[3] or "", re.I)}
            return any(b != r[0].upper() and b in open_ids and not (b in epics and b in approved) for b in on)
        # A ticket `orchestrator next --claim` already handed to a subagent is being worked: it isn't left (M.ORCH-T188).
        claimed = {t.upper() for t in orch_assignments()}
        # A claim gone stale is back in the queue, and `orchestrator next` hands it out again: it's work. Only the
        # running daemon's list counts (it rewrites it each minute): one left by a daemon that stopped may name a
        # ticket claimed afresh since.
        # What `orchestrator next` itself holds back isn't work to push on to either: /allocate paused, quiet hours,
        # a skipped repo, a ticket another live session or subagent is working, a stale claim whose agent still runs.
        if settings.get("Allocate") is False:
            return []
        skip = {(x or "").lower() for x in settings.get("AllocateSkip") or []}
        holds = orch_state("allocate-holds", 180)
        if not isinstance(holds, dict):
            holds = {}
        if holds.get("Quiet"):
            return []
        held = {(w.get("TicketId") or "").upper() for w in holds.get("Worked") or []
                if not (w.get("Filed") and w.get("AgentId") is None and sid and w.get("SessionId") == sid)}
        held |= {(i or "").upper() for i in holds.get("LivePilot") or []}
        try:
            stale = orch_state("stale-tickets", 180)
            if stale is not None:
                claimed -= {(i or "").upper() for i in stale or []} - held
        except Exception:
            pass
        claimed |= held
        named = {r.lower() for r in repos}
        return [r[0] for r in rows if any(fnmatch.fnmatchcase((r[2] or "").lower(), n) for n in named) and (r[2] or "").lower() not in skip and
                ((r[1] or "").lower() == "fix" or r[0].upper() in approved) and r[0].upper() not in claimed and r[0].upper() not in epics and not blocked(r)]
    except Exception:
        return None

def story_file_repos(repos):
    # Whether a repo named (or matched by a wildcard) keeps its tickets in its own docs/USER_STORIES.md, not the
    # ticket database: workable() can't see those (only their fixes can be worked: approval lives in the database
    # alone, M.ORCH-T761), so `orchestrator next`, which reads them, is asked instead (M.ORCH-T445). None when it couldn't
    # tell (out of its share of the budget, M.ORCH-T1045): next is then asked anyway.
    try:
        import fnmatch, sqlite3
        if cheap_left() < 1:
            return None
        try:
            db = tickets_db(timeout=max(0.5, min(5.0, cheap_left() - 1)))
            try:
                held = {(r or "").lower() for (r,) in db.execute("SELECT DISTINCT repo FROM tickets").fetchall()}
            finally:
                db.close()
        except Exception:
            held = set()
        named = {r.lower() for r in repos}
        # The scan stops once its share of the budget is spent (M.ORCH-T1005, M.ORCH-T1045): undecided, next is asked.
        for d in WS.iterdir():
            if cheap_left() < 0:
                return None
            if (d.is_dir() and d.name.lower() not in held and any(fnmatch.fnmatchcase(d.name.lower(), n) for n in named) and
                    (d / "docs" / "USER_STORIES.md").is_file()):
                return True
        return False
    except Exception:
        return None

def no_subagent_room(limits, pid):
    # The pace's subagent allowance is used up (all CLIs together), so `orchestrator next` would hand out nothing:
    # pushing a stop back would only loop (M.ORCH-T188). An unthrottled CLI isn't held to it, as `next` isn't.
    try:
        allowed = limits.get("subagent_allowance")
        if allowed is None or (pid and (DIR / ("unthrottled-" + str(pid))).exists()):
            return False
        # Cooling off (M.ORCH-T1253): a new subagent would be aborted within seconds, and `orchestrator next` hands out nothing.
        if limits.get("cool_off_percent") is not None and orch_settings().get("AgentAbort") is not False:
            return True
        sub = SUBAGENT_MARKS / "subagents"
        marks = list(sub.iterdir()) if sub.exists() else []
        def mark_ns(m):
            # Gone while counted (its stop came): not counted, rather than the whole check giving up (M.ORCH-T366).
            try:
                return m.stat().st_mtime_ns
            except OSError:
                return -1
        if limits.get("subagents_running") is None:
            running = len(marks)
        elif limits.get("subagents_seen_through_ns") is not None:
            # Only marks newer than the newest the daemon's count saw (M.ORCH-T320), as the pace gate counts.
            seen = int(limits["subagents_seen_through_ns"])
            running = int(limits["subagents_running"]) + sum(1 for m in marks if mark_ns(m) > seen)
        else:
            at = datetime.fromisoformat(limits["timestamp"].replace("Z", "+00:00")).timestamp()
            running = int(limits["subagents_running"]) + sum(1 for m in marks if mark_ns(m) / 1e9 > at)
        return running >= int(allowed)
    except Exception:
        return False

def next_hands_out(repos, pid):
    # What `orchestrator next` itself would hand this CLI now (a dry run: nothing is claimed), so a stop is pushed back
    # only for tickets it will get. The files workable() reads trail it: a ticket another live session filed a moment
    # ago is held by next at once, but by the daemon's holds only after its next tick, and every stop until then was
    # sent back for a ticket next refused (M.ORCH-T385). None when next can't be asked (not installed, failed, too slow):
    # then workable()'s own count stands. Its timeout is 30s, under the 60s hook timeout (M.ORCH-T901: next took 17s on a busy
    # machine, past the old 6s, so the cheap count always stood and nagged).
    try:
        import shutil, subprocess
        exe = os.environ.get("MINDATTIC_ORCHESTRATOR") or shutil.which("orchestrator") or r"C:\Apps\MindAttic.Orchestrator\Cli\orchestrator.exe"
        if not Path(exe).exists():
            return None
        env = dict(os.environ)
        if pid:
            env["MINDATTIC_CLI_PID"] = str(pid)  # this CLI, so what it filed itself stays its own (M.ORCH-T328)
        # At most 30s, and never past the hook's budget (M.ORCH-T1005): too little left and the cheap count stands.
        wait = min(30, time_left() - 2)
        if wait < 3:
            return None
        r = subprocess.run([exe, "next", "--repos", ",".join(repos)], capture_output=True, text=True, encoding="utf-8",
                           errors="ignore", timeout=wait, env=env, stdin=subprocess.DEVNULL)
        ids = re.findall(r"^=== (\S+) \(", r.stdout or "", re.M)
        return ids if r.returncode == 0 and (ids or "Nothing handed out" in (r.stdout or "")) else None
    except Exception:
        return None

def keep_going(repos, ids, sid, why, insisted, provider="Claude"):
    repo = ", ".join(repos)
    # Logs it to keep-going.jsonl (the daemon reports it); the reason to give the agent, or None when it's let stop.
    try:
        DIR.mkdir(parents=True, exist_ok=True)
        with open(DIR / "keep-going.jsonl", "a", encoding="utf-8") as log:
            log.write(json.dumps({"at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "repo": repo, "session": sid,
                                  "provider": provider, "why": why, "open": len(ids), "action": "let stop" if insisted else "kept going"}) + "\n")
    except Exception:
        pass
    if insisted:
        return None
    return ("Don't stop: /allocate is on in this CLI for " + repo + ", and " + str(len(ids)) + " workable ticket" +
            ("" if len(ids) == 1 else "s") + " remain (" + ", ".join(ids[:6]) + ("..." if len(ids) > 6 else "") + "). "
            "Run `orchestrator next --repos \"" + ",".join(repos) + "\" --claim` and hand each ticket it prints to a subagent with the "
            "prompt it prints, on the model it names (several at once, in one message), then repeat. End your turn only when it hands out nothing, "
            "or you're blocked on a decision only the user can make, and then say plainly what it is.")

def subagents_working(pid):
    # How many of this CLI's subagents are still running: their marks (written at SubagentStart with the CLI's pid,
    # deleted at SubagentStop), less one older than a stop that never came (the CLI was killed mid-run).
    n = 0
    try:
        sub = SUBAGENT_MARKS / "subagents"
        for m in (list(sub.iterdir()) if sub.exists() else []):
            try:
                if m.read_text().strip() == str(pid) and time.time() - m.stat().st_mtime < 21600:
                    n += 1
            except Exception:
                pass  # gone while counted: its stop came
    except Exception:
        pass
    return n

def orchestrator_status():
    # rl-status.json while the orchestrator keeps it fresh; {} when it's stale or someone else's. Read as the pace gate
    # reads it, retried while the daemon is replacing it: once, a Stop then saw no status at all (M.ORCH-T363).
    try:
        s = rl_status()
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00"))).total_seconds()
        fresh = age <= 180 and not before_switch(s["timestamp"], True)
        return lapsed(s) if s.get("source") == "MindAttic.Orchestrator" and fresh else {}
    except Exception:
        return {}

def poke():
    # A turn (or a subagent) just ended, so its reply's tokens are in its transcript: the daemon recounts now
    # instead of on its next tick, so even a reply with no tool calls is in the pace within a second or two. Said on the
    # daemon's inbox at once (M.ORCH-T872); the file stays for a daemon from before it.
    publish_status("poke", {"source": "context-gate"})
    try:
        DIR.mkdir(parents=True, exist_ok=True)
        (DIR / "refresh.now").write_text(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    except Exception:
        pass

def iso_epoch(text):
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def limit_held(limits, data, now):
    # {"until", "window", "at"} when this turn ended held by a window: at its stop (the orchestrator's, fresh or latched,
    # or Claude's own line); None otherwise. The
    # daemon types a resume into the CLI (or asks you to) once that window has reset (M.ORCH-T256: a CLI that stopped
    # at 94% sat idle past the reset until its author noticed).
    until = window = None
    if limits.get("stop"):
        until, window = iso_epoch(limits.get("stop_until")), limits.get("stop_window")
    if until is None:
        l = latched("orchestrator")
        if l:
            until, window = float(l["until"]), window or l.get("window")
    if until is None:
        own = claude_stop()
        if own:
            until, window = own[1], own[2]
    if until is None or until <= time.time():
        return None
    return {"until": until, "window": window or "5-hour", "at": now}

# Typed at the window's stop, these still go through: they're how you steer the orchestrator itself.
# /goal goes through at the stop only to clear one: a new goal there would run turn after turn its refused calls can't finish.
CONTROL = re.compile(r"/(allocate|crossrepo|pacing)\b|/goal\s*(?:(?:clear|off|stop|reset|none|cancel)\s*)?$", re.I)

def goal_finished(transcript, goal):
    # A /goal ends on its own once its condition holds: the session's last entry is then the stop summary naming it
    # (an unmet goal keeps the turn going, so more follows). The summary lands after this hook's own Stop, so it's
    # checked later: on the next prompt here, and by the orchestrator's cycler (M.ORCH-T109).
    try:
        lines = Path(transcript).read_text(encoding="utf-8", errors="ignore").splitlines()[-60:]
    except Exception:
        return False
    for line in reversed(lines):
        try:
            m = json.loads(line)
        except Exception:
            continue
        if m.get("type") in ("assistant", "user", "system"):
            return m.get("subtype") == "stop_hook_summary" and any(h.get("promptText") == goal for h in m.get("hookInfos") or [])
    return False

# Hooks fire together (parallel tool calls, a Stop racing a SubagentStop). A read or replace Windows refuses while
# another hook has the file open is retried: read as empty, the next save would wipe the session's goal and pid.
# A session's state (M.ORCH-T528): its session_states row in the orchestrator's database, still exported as its
# <session>.state.json, which the Launcher's ClaudeRestartGate and the orchestrator's session readers read; whichever of
# the two was written later.
def load(path):
    value = exported_mark(path.name[:-len(".state.json")], path, table="session_states", key="session_id")
    return value if isinstance(value, dict) else {}

def save(path, value):
    write_exported_mark(path.name[:-len(".state.json")], path, value, table="session_states", key="session_id")

def cli_pid():
    try:
        import ctypes, os
        from ctypes import wintypes
        class Entry(ctypes.Structure):
            _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                        ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                        ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                        ("szExeFile", ctypes.c_char * 260)]
        k = ctypes.windll.kernel32
        k.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        snap = k.CreateToolhelp32Snapshot(2, 0)
        procs, e = {}, Entry()
        e.dwSize = ctypes.sizeof(Entry)
        ok = k.Process32First(snap, ctypes.byref(e))
        while ok:
            procs[e.th32ProcessID] = (e.th32ParentProcessID, e.szExeFile.decode(errors="ignore").lower())
            ok = k.Process32Next(snap, ctypes.byref(e))
        k.CloseHandle(snap)
        pid = os.getpid()
        for _ in range(8):
            pid = procs.get(pid, (0, ""))[0]
            if not pid:
                return None
            if procs.get(pid, (0, ""))[1].startswith("claude.exe"):  # or claude.exe.old.N, once the updater renames it
                return pid
    except Exception:
        pass
    return None

def _profile_dir():
    d = os.environ.get("CLAUDE_CONFIG_DIR")
    if not d:
        return None
    try:
        p = Path(d).expanduser().resolve()
        return None if p == (Path.home() / ".claude").resolve() else p
    except Exception:
        return None
PROFILE_DIR = _profile_dir()
CLAUDE_HOME = PROFILE_DIR or (Path.home() / ".claude")
CLAUDE_JSON = (PROFILE_DIR / ".claude.json") if PROFILE_DIR else (Path.home() / ".claude.json")
SUBAGENT_MARKS = (PROFILE_DIR / "session-context") if PROFILE_DIR else (Path.home() / ".claude" / "session-context")
STOP_PERCENT = 99
LATCH = Path.home() / ".claude" / "session-context" / "stop-latch.json"
ACCOUNT = Path.home() / ".claude" / "session-context" / "account.json"
HISTORY_KEPT = 691200
def read_json(path):
    # A file being replaced can't be opened for a moment on Windows: that's a retry, not a missing file.
    for _ in range(20):
        try:
            return json.loads(path.read_text())
        except PermissionError:
            time.sleep(0.05)
    raise PermissionError(str(path))
RL_STATUS = CLAUDE_HOME / "rl-status.json"
def rl_status():
    # The orchestrator's pace status (M.ORCH-T526): its rl-status row in the database (needs orch_rows), or
    # rl-status.json, the same status exported for readers outside the orchestrator (and all a daemon from before the
    # move writes), whichever was written later. A database held by a write isn't waited on long: the file stands in.
    # Raises when there's neither. A CLI on its own login (M.ORCH-T559) reads only its account's file: the row is the
    # global login's pace.
    found = []
    rows = None if PROFILE_DIR else orch_rows("SELECT value FROM state WHERE name = ?", ("rl-status",), timeout=1)
    if rows:
        try:
            s = json.loads(rows[0][0])
            if isinstance(s, dict):
                found.append(s)
        except Exception:
            pass
    try:
        s = read_json(RL_STATUS)
        if isinstance(s, dict):
            found.append(s)
    except Exception:
        if not found:
            raise
    if not found:
        raise ValueError("no status")
    return max(found, key=lambda s: str(s.get("timestamp") or ""))
def write_json(path, value):
    tmp = path.with_name(path.name + "." + str(os.getpid()) + ".tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(value))
        for _ in range(20):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                time.sleep(0.05)
    except Exception:
        pass
    try:
        tmp.unlink()
    except Exception:
        pass
def claude_config():
    try:
        config = json.loads(CLAUDE_JSON.read_text(encoding="utf-8", errors="ignore"))
        return config if isinstance(config, dict) else {}
    except Exception:
        return {}
def config_account(config):
    # Keyed as ClaudeAccount.Current: a Claude login by account and organization, an API key as "api-key"; None signed out.
    text = lambda o, k: o.get(k) if isinstance(o, dict) and isinstance(o.get(k), str) and o.get(k) else None
    oauth = config.get("oauthAccount")
    if text(oauth, "accountUuid"):
        return text(oauth, "accountUuid") + ("/" + text(oauth, "organizationUuid") if text(oauth, "organizationUuid") else "")
    if text(config, "primaryApiKey"):
        return "api-key"
    responses = config.get("customApiKeyResponses")
    approved = responses.get("approved") if isinstance(responses, dict) else None
    return "api-key" if isinstance(approved, list) and approved else None
_account = []
def account():
    # (the account signed in, or the last one while signed out; the epochs [(from, to)] it was signed in; the record).
    # A move to another account closes the last span and opens one for it; the daemon keeps the same record, so whichever
    # sees a switch first dates it for both. ("", [], {}) when no account was ever seen.
    if _account:
        return _account[0]
    result = ("", [], {})
    if PROFILE_DIR:
        # A CLI on its own login (M.ORCH-T559) is that one account for its whole life: it has no switches, and the
        # shared record is the global login's, so it's never written from here.
        signed = config_account(claude_config()) or ""
        _account.append((signed, [(0.0, None)] if signed else [], {}))
        return _account[0]
    try:
        signed = config_account(claude_config())
        try:
            seen = exported_mark("account", ACCOUNT) or {}  # M.ORCH-T528
        except Exception:
            seen = {}
        spans = [dict(x) for x in seen.get("spans") or [] if isinstance(x, dict) and x.get("account") and x.get("from") is not None]
        if not spans and seen.get("account") and seen.get("since"):
            spans = [{"account": seen["account"], "from": float(seen["since"]), "to": None}]  # recorded before spans were kept
        current = spans[-1]["account"] if spans else None
        changed = False
        if signed and current and "/" not in current and signed.startswith(current + "/"):
            # Recorded before the organization was part of the key: the same sign-in, so keep its dates.
            for x in spans:
                if x["account"] == current:
                    x["account"] = signed
            current, changed = signed, True
        if signed and signed != current:
            now = time.time()
            if spans:
                spans[-1]["to"] = now
            spans.append({"account": signed, "from": now, "to": None})
            current, changed = signed, True
        # A closed span ages out on every read, not only at the next switch, or one /login counts as a switch for good.
        kept = [x for x in spans if x.get("to") is None or time.time() - float(x["to"]) <= HISTORY_KEPT]
        if kept and len(kept) != len(spans):
            spans, changed = kept, True
        if changed:
            seen.update(account=current, since=spans[-1]["from"], spans=spans)
            write_exported_mark("account", ACCOUNT, seen)
        if current:
            result = (current, [(float(x["from"]), None if x.get("to") is None else float(x["to"])) for x in spans if x["account"] == current], seen)
    except Exception:
        pass
    _account.append(result)
    return result
def account_tag():
    # The current account, for a gate event (M.ORCH-T774); None rather than raising, so a call on the stop path (not
    # every caller of log_gate_event wraps it) can never fail a refusal just for want of a tag.
    try:
        return account()[0] or None
    except Exception:
        return None
def switched_at():
    # When the sign-in last moved to the current account (epoch; 0 when no account was ever seen).
    spans = account()[1]
    return spans[-1][0] if spans else 0.0
def before_switch(stamp, to_the_second=False):
    # Whether an ISO time (a report's or a status file's) is from before the sign-in moved to the current account; never
    # before the first account seen (its first sight isn't a move from anything). rl-status.json's timestamp is cut to
    # the second, so the status the daemon writes in the second of the switch isn't taken for an older one (M.ORCH-T325).
    current, _, seen = account()
    since = switched_at()
    if not since or all(x.get("account") == current for x in seen.get("spans") or []):
        return False
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp() < (int(since) if to_the_second else since)
    except Exception:
        return True
def owns(usage):
    # Whether a claude-usage.json reading is the current account's (ClaudeAccount.Owns). Every open CLI's statusline
    # restamps its own last reply, so after a /login the others keep writing the old account's percent as new. Once
    # another account has been signed in, only a reading the daemon's meter probe tagged with this account, or one whose
    # windows were already confirmed for it, counts.
    current, _, seen = account()
    if usage.get("account"):
        return usage["account"] == current
    if not current or all(x.get("account") == current for x in seen.get("spans") or []):
        return True
    confirmed = seen.get("confirmed") if isinstance(seen.get("confirmed"), dict) else {}
    mine = confirmed.get(current) if isinstance(confirmed.get(current), dict) else None
    if not mine:
        return False
    limits = usage.get("rate_limits") or {}
    reset = lambda w: float(w["resets_at"]) if isinstance(w, dict) and w.get("resets_at") is not None else None
    same = lambda a, b: a is not None and b is not None and abs(float(a) - float(b)) < 90
    five, week = reset(limits.get("five_hour")), reset(limits.get("seven_day"))
    if same(five, mine.get("five_hour")) and (week is None or mine.get("seven_day") is None or same(week, mine["seven_day"])):
        return True
    return same(week, mine.get("seven_day")) and not any(same(week, (c or {}).get("seven_day")) for a, c in confirmed.items() if a != current and isinstance(c, dict))
def latched(by):
    # The stop latched by "claude", "claude-week" or "orchestrator" for the current account, for a window that hasn't
    # reset; None otherwise. Going back to an account brings its stop back while its window runs. The latches are the
    # orchestrator database's stop-latch state row (M.ORCH-T528), with stop-latch.json as hook_mark reads it.
    try:
        every = hook_mark("stop-latch", LATCH)
        l = every.get(by + "@" + account()[0])
        if l is None:
            # Latched before latches were kept per account: the current account's if dated from its current span.
            l = every.get(by)
            if l and (l.get("account") or float(l.get("epoch") or 0) != switched_at()):
                l = None
            elif l:
                # Moved to the account's key, so it still holds once this account is left and come back to.
                def move(every):
                    old = every.pop(by, None)
                    if old is None:
                        return None
                    every[by + "@" + account()[0]] = dict(old, account=account()[0])
                    return every
                change_hook_mark("stop-latch", LATCH, move)
        if l and float(l["until"]) > time.time():
            return l
    except Exception:
        pass
    return None
def latch(by, until, **fields):
    # Records (or with until=None, clears) a stop seen for the current account's window, so it holds until the reset
    # whatever comes next. Latches whose window has reset are dropped. One write transaction on the stop-latch row.
    def change(every):
        key = by + "@" + account()[0]
        old = every.get(key)
        legacy = every.get(by)
        if legacy and not legacy.get("account") and float(legacy.get("epoch") or 0) == switched_at():
            old = old or legacy
            every.pop(by)
        else:
            legacy = None
        if until is None:
            if old is None:
                return None
            every.pop(key, None)
        else:
            entry = dict(fields, until=float(until), account=account()[0], epoch=switched_at())
            if old and old.get("until") == entry["until"] and float(old.get("percent") or 0) > float(entry.get("percent") or 0):
                entry["percent"] = old["percent"]
            if old == entry and not legacy:
                return None
            every[key] = entry
        now = time.time()
        return {k: v for k, v in every.items() if isinstance(v, dict) and float(v.get("until") or 0) > now}
    try:
        change_hook_mark("stop-latch", LATCH, change)
    except Exception:
        pass
def claude_usage():
    # Claude's own report: the statusline's claude-usage.json, or the orchestrator's meter probe reading in its
    # database (M.ORCH-T528: the probe never replaces the statusline's file), whichever is later. Raises when neither.
    found = []
    rows = None if PROFILE_DIR else orch_rows("SELECT value FROM state WHERE name = ?", ("claude-usage",), timeout=1)
    if rows:
        try:
            found.append(json.loads(rows[0][0]))
        except Exception:
            pass
    try:
        found.append(read_json(CLAUDE_HOME / "claude-usage.json"))
    except Exception:
        if not found:
            raise
    def at(u):
        try:
            return datetime.fromisoformat(str(u.get("at")).replace("Z", "+00:00")).timestamp()
        except Exception:
            return 0.0
    return max(found, key=at)
WEEK_STOP_DEFAULT = 90
_week_stop = []
def week_stop_percent():
    # The account's weekly stop line (M.ORCH-T609): 100 minus the weekly reserve on the Settings page, read live (never
    # baked in here), so a changed reserve applies within a daemon tick. The line the daemon wrote into this login's
    # status (rl-status.json, or the global login's row) first, then the settings (a daemon from before the line, or none
    # yet), then the default (90%).
    if _week_stop:
        return _week_stop[0]
    line = None
    try:
        v = rl_status().get("weekly_stop_percent")
        if isinstance(v, (int, float)) and not isinstance(v, bool) and 50 <= v <= 100:
            line = float(v)
    except Exception:
        pass
    if line is None:
        try:
            # Weekly-aware pacing's target is this same line (M.ORCH-T680), so on or off the week stops here.
            reserve = orch_settings().get("WeeklyReservePercent")
            if isinstance(reserve, (int, float)) and not isinstance(reserve, bool):
                line = 100.0 - min(max(float(reserve), 0.0), 50.0)
        except Exception:
            pass
    _week_stop.append(WEEK_STOP_DEFAULT if line is None else line)
    return _week_stop[0]
_five_stop = []
def five_hour_stop_percent():
    # The login's own 5-hour cutoff (org limit --5h, 96% by default) as the daemon last wrote it into this login's
    # status, read even when that status is stale, so a daemon that's down doesn't let the login run to STOP_PERCENT;
    # STOP_PERCENT only when no status names one (bughunt 2026-10-27).
    if _five_stop:
        return _five_stop[0]
    line = None
    try:
        v = rl_status().get("five_hour_stop_percent")
        if isinstance(v, (int, float)) and not isinstance(v, bool) and 1 <= v <= 100:
            line = float(v)
    except Exception:
        pass
    _five_stop.append(STOP_PERCENT if line is None else line)
    return _five_stop[0]
def claude_stop():
    # (percent, reset epoch, window) when Claude itself reports a window at the stop line, now or earlier in the same
    # window (an idle session's later, lower report doesn't lift it); None otherwise. The week counts as much as the
    # 5 hours: a daemon that's down mustn't let a week at its stop line run into a wall that locks you out for days.
    # The 5 hours stop at five_hour_stop_percent() (the login's cutoff), the week at week_stop_percent() (the weekly
    # reserve, M.ORCH-T609).
    windows = (("five_hour", "claude", "5-hour"), ("seven_day", "claude-week", "weekly"))
    line = lambda key: week_stop_percent() if key == "seven_day" else five_hour_stop_percent()
    try:
        usage = claude_usage()
        limits = usage["rate_limits"] if owns(usage) and (usage.get("account") or not before_switch(usage.get("at"))) else {}
        for key, by, name in windows:
            w = limits.get(key)
            if w and float(w["used_percentage"]) >= line(key) and float(w["resets_at"]) > time.time():
                latch(by, float(w["resets_at"]), percent=float(w["used_percentage"]))
                return float(w["used_percentage"]), float(w["resets_at"]), name
    except Exception:
        pass
    for key, by, name in windows:
        l = latched(by)
        # A weekly latch below the line as it is now (the reserve lowered since) no longer holds.
        if l and float(l.get("percent") or line(key)) >= line(key):
            return float(l.get("percent") or line(key)), float(l["until"]), name
    return None
def flag(value):
    return bool(value) and str(value).strip().lower() not in ("0", "false", "no", "off")
KEY_SET_ASIDE = Path.home() / ".claude" / "session-context" / "api-key-set-aside.json"
def key_mark(key):
    # The record of a set-aside key names it by a hash of the 20 characters Claude Code keeps, never the key.
    import hashlib
    return hashlib.sha256(key[-20:].encode("utf-8")).hexdigest()[:16]
def process_started(pid):
    # When a process started (epoch), or None when that can't be told.
    try:
        import ctypes
        from ctypes import wintypes
        k = ctypes.windll.kernel32
        k.OpenProcess.restype = wintypes.HANDLE
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        h = k.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return None
        try:
            t = [wintypes.FILETIME() for _ in range(4)]
            if not k.GetProcessTimes(h, *[ctypes.byref(x) for x in t]):
                return None
            return ((t[0].dwHighDateTime << 32) | t[0].dwLowDateTime) / 1e7 - 11644473600
        finally:
            k.CloseHandle(h)
    except Exception:
        return None
def still_on_set_aside_key(key):
    # The key was set aside while this CLI already ran on it (M.ORCH-T434): Claude Code settled on the key at its start,
    # so it's what this CLI bills until it's closed and reopened.
    try:
        at = hook_mark("api-key-set-aside", KEY_SET_ASIDE).get(key_mark(key))
        if at is None:
            return False
        pid = os.environ.get("MINDATTIC_CLI_PID") or cli_pid()
        started = process_started(pid) if pid else None
        return started is not None and started < float(at)
    except Exception:
        return False
BILLING = Path.home() / ".claude" / "session-context" / "billing.json"
def billing_mode():
    # The billing mode the orchestrator's switch set (M.ORCH-T436): {"mode": "team"|"api", "since", "login", ...}; {} when
    # no switch was ever made, and the last sign-in alone decides, as before.
    try:
        mode = exported_mark("billing", BILLING) or {}  # M.ORCH-T528
        return mode if isinstance(mode, dict) and mode.get("mode") in ("team", "api") else {}
    except Exception:
        return {}
def approved_since_start():
    # The switch to the API key approved the key after this CLI started: Claude Code settled on the login at its start, so
    # that's what it bills until it's restarted.
    try:
        at = billing_mode().get("approved_at")
        if at is None:
            return False
        pid = os.environ.get("MINDATTIC_CLI_PID") or cli_pid()
        started = process_started(pid) if pid else None
        return started is not None and started < float(at)
    except Exception:
        return False
def auth_sources(cwd=None):
    # (environment, settings files): this CLI's own environment over the settings' env blocks, and the settings read.
    settings = []
    places = [CLAUDE_HOME / "settings.json", Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "ClaudeCode" / "managed-settings.json"]
    if cwd:
        places += [Path(cwd) / ".claude" / "settings.json", Path(cwd) / ".claude" / "settings.local.json"]
    for place in places:
        try:
            found = json.loads(place.read_text(encoding="utf-8", errors="ignore"))
            if isinstance(found, dict):
                settings.append(found)
        except Exception:
            pass
    env = {}
    for found in settings:
        if isinstance(found.get("env"), dict):
            env.update({k: str(v) for k, v in found["env"].items()})
    env.update(os.environ)
    return env, settings
CLOUDS = (("CLAUDE_CODE_USE_BEDROCK", "Amazon Bedrock"), ("CLAUDE_CODE_USE_VERTEX", "Google Vertex AI"),
          ("CLAUDE_CODE_USE_FOUNDRY", "Microsoft Foundry"), ("CLAUDE_CODE_USE_ANTHROPIC_AWS", "Claude Platform on AWS"),
          ("CLAUDE_CODE_USE_MANTLE", None))
def billing(cwd=None):
    # (auth, source): what this CLI is billed through, by Claude Code's own precedence (code.claude.com/docs/en/iam,
    # "Authentication precedence"): a cloud provider, then ANTHROPIC_AUTH_TOKEN (a gateway), ANTHROPIC_API_KEY,
    # apiKeyHelper, CLAUDE_CODE_OAUTH_TOKEN, an Anthropic profile, then the /login in ~/.claude.json. Hooks run inside
    # claude.exe and see its environment, settings' env blocks included; the settings files are read too. Outside
    # claude.exe (no CLAUDECODE: Codex, Gemini, Kimi) it's "subscription", paced as ever. CLAUDE_CODE_OAUTH_TOKEN is a
    # subscription whose account can't be told from the token: it's paced as the config's account. source says how:
    # the cloud's variable, "env-p" (-p's key), "env" (an approved key), "env-set-aside" (one set aside since this CLI
    # started on it), "login", "token", "helper", the profile, or None.
    if os.environ.get("CLAUDECODE") != "1":
        return "subscription", None
    env, settings = auth_sources(cwd)
    for variable, _ in CLOUDS:
        if flag(env.get(variable)):
            return "cloud", variable
    if env.get("ANTHROPIC_AUTH_TOKEN"):
        return "gateway", None
    config = claude_config()
    key = env.get("ANTHROPIC_API_KEY")
    if key:
        # -p (and the SDK) always uses it; interactively only once approved (Claude Code remembers the key's last 20
        # characters). A rejected key, or one still waiting for its answer, leaves the login in charge, except in a CLI
        # that started on it before it was set aside; an approved one leaves it too in a CLI that started before the
        # billing switch approved it (M.ORCH-T436).
        responses = config.get("customApiKeyResponses") if isinstance(config.get("customApiKeyResponses"), dict) else {}
        if str(os.environ.get("CLAUDE_CODE_ENTRYPOINT") or "").startswith("sdk"):
            return "api-key", "env-p"
        listed = lambda k: responses.get(k) if isinstance(responses.get(k), list) else []
        if key[-20:] in listed("approved") and not approved_since_start():
            return "api-key", "env"
        if key[-20:] in listed("rejected") and still_on_set_aside_key(key):
            return "api-key", "env-set-aside"
    if any(found.get("apiKeyHelper") for found in settings):
        return "helper", None
    if env.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return "subscription", "token"
    if env.get("ANTHROPIC_PROFILE") or (env.get("ANTHROPIC_FEDERATION_RULE_ID") and env.get("ANTHROPIC_ORGANIZATION_ID")):
        return "profile", env.get("ANTHROPIC_PROFILE")
    # A Console login (primaryApiKey, with its oauthAccount) bills the API, not a subscription.
    console = isinstance(config.get("primaryApiKey"), str) and config.get("primaryApiKey")
    return ("api-key" if console or config_account(config) == "api-key" else "subscription"), "login"
def session_auth(cwd=None):
    return billing(cwd)[0]
def reset_text(epoch):
    # The clock alone today; with the weekday on any other day, even under 24 hours off (M.ORCH-T407).
    at = datetime.fromtimestamp(epoch)
    return at.strftime("%a %I:%M %p" if at.date() != datetime.now().date() else "%I:%M %p").replace(" 0", " ").lstrip("0")
def claude_stop_note(stop, running=False):
    # running: the daemon's status is fresh (it just hasn't stopped yet), so the note doesn't say it's down.
    window = stop[2] if len(stop) > 2 else "5-hour"
    return ("Claude reports " + str(int(stop[0])) + "% of the " + window + " window used" +
            ("" if running else " and MindAttic.Orchestrator isn't running to pace it") + ", "
            "so tool calls are refused until it resets at " + reset_text(stop[1]) + ". End your turn now.")
ORCHESTRATOR_STOP = "The 5-hour window is at its target: tool calls are refused until it resets. End your turn now."
def orchestrator_stop(s):
    # The orchestrator's stop note, from its fresh rl-status.json s ({} when stale or unreadable) or latched from an
    # earlier one until the window resets, so a daemon that stalls at the stop can't lift it; None when not stopped.
    # A fresh file without the stop is the orchestrator lifting it, and ends the latch.
    if s:
        if not s.get("stop"):
            latch("orchestrator", None)
            return None
        note = s.get("stop_note") or ORCHESTRATOR_STOP
        try:
            until = datetime.fromisoformat(str(s["stop_until"]).replace("Z", "+00:00")).timestamp()
        except Exception:
            old = latched("orchestrator")
            until = float(old["until"]) if old else time.time() + 600
        latch("orchestrator", until, note=note, window=s.get("stop_window"), reset_time=s.get("reset_time"))
        return note
    l = latched("orchestrator")
    return (l.get("note") or ORCHESTRATOR_STOP) if l else None
def lapsed(s):
    # A status worked out before its window reset holds nothing in the new one, though it's still fresh for up to a tick:
    # past stop_until its stop, past window_reset its holds and subagent allowance (M.ORCH-T387).
    def passed(key):
        try:
            return datetime.fromisoformat(str(s[key]).replace("Z", "+00:00")).timestamp() <= time.time()
        except Exception:
            return False
    if s.get("stop") and passed("stop_until"):
        s = {k: v for k, v in s.items() if k not in ("stop", "stop_note", "stop_until", "stop_window")}
    if passed("window_reset"):
        s = {k: v for k, v in s.items() if k not in ("pace_delay_seconds", "pace_note", "subagent_allowance", "subagent_note")}
    return s
def daemon_down():
    # Seconds since the orchestrator last wrote rl-status.json, once that's past what the gates trust; else None.
    try:
        s = rl_status()
        if s.get("source") != "MindAttic.Orchestrator":
            return None
        age = time.time() - datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00")).timestamp()
        return age if age > 180 else None
    except Exception:
        return None

def top_level_value(text, name):
    # (start, end, value) of a top-level key's value in a JSON object's text (the last, as JSON.parse keeps); None if absent.
    dec, ws = json.JSONDecoder(), re.compile(r"[ \t\r\n]*")
    i = ws.match(text, 0).end()
    if text[i:i + 1] != "{":
        return None
    i = ws.match(text, i + 1).end()
    found = None
    while i < len(text) and text[i] != "}":
        key, i = dec.raw_decode(text, i)
        i = ws.match(text, i).end()
        if text[i:i + 1] != ":":
            return None
        i = ws.match(text, i + 1).end()
        value, end = dec.raw_decode(text, i)
        if key == name:
            found = (i, end, value)
        i = ws.match(text, end).end()
        if text[i:i + 1] == ",":
            i = ws.match(text, i + 1).end()
    return found
def dumped_like(value, text, start, end):
    # value as JSON laid out as the text it replaces was: Claude Code's two-space indent at that depth, its line endings.
    old = text[start:end]
    if "\n" not in old:
        return json.dumps(value, ensure_ascii=False, separators=(", ", ": ") if ": " in old else (",", ":"))
    newline = "\r\n" if "\r\n" in old else "\n"
    line = text[text.rfind("\n", 0, start) + 1:start]
    indent = line[:len(line) - len(line.lstrip(" \t"))]
    inner = re.search(r"\n([ \t]*)\S", old)
    step = inner.group(1)[len(indent):] if inner and len(inner.group(1)) > len(indent) else "  "
    lines = json.dumps(value, ensure_ascii=False, indent=step).split("\n")
    return lines[0] + "".join(newline + indent + l for l in lines[1:])
def set_aside_key(key):
    # Moves the key's last 20 characters from customApiKeyResponses.approved to .rejected in ~/.claude.json; True when it
    # did. That's Claude Code's own file, large and rewritten often: only that field's text changes, the rest is kept byte
    # for byte, and it's put in place whole, re-read just before so a write Claude Code made meanwhile is never lost.
    path, tail = CLAUDE_JSON, key[-20:]
    for _ in range(5):
        raw = None
        for _ in range(20):
            try:
                raw = path.read_bytes()
                break
            except PermissionError:
                time.sleep(0.05)
        if raw is None:
            return False
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw[3 if bom else 0:].decode("utf-8")
        span = top_level_value(text, "customApiKeyResponses")
        if not span or not isinstance(span[2], dict) or not isinstance(span[2].get("approved"), list) or tail not in span[2]["approved"]:
            return False
        value = dict(span[2])
        rejected = value.get("rejected") if isinstance(value.get("rejected"), list) else []
        value["approved"] = [x for x in value["approved"] if x != tail]
        value["rejected"] = rejected + ([] if tail in rejected else [tail])
        out = text[:span[0]] + dumped_like(value, text, span[0], span[1]) + text[span[1]:]
        json.loads(out)
        tmp = path.with_name(path.name + "." + str(os.getpid()) + ".tmp")
        try:
            tmp.write_bytes((b"\xef\xbb\xbf" if bom else b"") + out.encode("utf-8"))
            for _ in range(20):
                try:
                    if path.read_bytes() != raw:
                        break  # Claude Code wrote it meanwhile: start over from its new text
                    os.replace(tmp, path)
                    return True
                except PermissionError:
                    time.sleep(0.05)
            else:
                return False
        finally:
            try:
                tmp.unlink()
            except Exception:
                pass
    return False
def plan_name(oauth):
    # The plan the config names (organizationType "claude_team": Claude Team); None when it names none.
    kind = oauth.get("organizationType") if isinstance(oauth.get("organizationType"), str) else ""
    return "Claude " + " ".join(w.capitalize() for w in kind[len("claude_"):].split("_") if w) if kind.startswith("claude_") and len(kind) > len("claude_") else None
def billing_check(cwd=None):
    # (auth, line, warn) for a CLI starting: one [Billing] line naming what it bills. A claude.ai login sets an approved
    # ANTHROPIC_API_KEY aside first; a CLI already running on it is warned to close and reopen. With the billing switch
    # on the API key (M.ORCH-T436) the key is what was chosen: it's left approved, and a CLI on the login is warned
    # instead; it stays until an explicit switch back to Claude Team.
    config = claude_config()
    text = lambda o, k: o.get(k) if isinstance(o, dict) and isinstance(o.get(k), str) and o.get(k) else None
    oauth = config.get("oauthAccount") if isinstance(config.get("oauthAccount"), dict) else {}
    claude_ai = bool(text(oauth, "accountUuid")) and not text(config, "primaryApiKey")
    mode = billing_mode()
    # A /login to another account does not switch the API key back (M.ORCH-T676): only an explicit switch does.
    api_mode = mode.get("mode") == "api"
    auth, source = billing(cwd)
    env, _ = auth_sources(cwd)
    who = (text(oauth, "emailAddress") or text(oauth, "accountUuid") or "") + (" (" + text(oauth, "organizationName") + ")" if text(oauth, "organizationName") else "")
    plan = plan_name(oauth) if claude_ai else None
    login = (plan or "the claude.ai login") + ": " + who
    key = env.get("ANTHROPIC_API_KEY") or ""
    keyed = "the API key in ANTHROPIC_API_KEY (…" + key[-4:] + ")"
    if auth == "api-key" and source in ("env", "env-p", "env-set-aside") and claude_ai and not api_mode:
        setaside = source == "env-set-aside"
        if source in ("env", "env-p"):
            responses = config.get("customApiKeyResponses") if isinstance(config.get("customApiKeyResponses"), dict) else {}
            if isinstance(responses.get("approved"), list) and key[-20:] in responses["approved"]:
                try:
                    # Dated first, so this CLI (started before it) reads as still on the key the moment the file changes.
                    # The orchestrator database's api-key-set-aside row (M.ORCH-T528), else the file as before.
                    at = time.time()
                    change_hook_mark("api-key-set-aside", KEY_SET_ASIDE, lambda marks: dict(marks, **{key_mark(key): at}))
                except Exception:
                    pass
                try:
                    setaside = set_aside_key(key)
                except Exception:
                    setaside = False
            elif source == "env-p":
                setaside = True  # nothing approved to set aside: only -p uses it
        line = "[Billing] Warning: this CLI bills " + keyed + ", not " + login + ", which is signed in."
        if source == "env-p":
            line += (" -p always uses ANTHROPIC_API_KEY when it's set: remove it from the environment that starts this CLI so it bills " +
                     (plan or "the claude.ai login") + ".")
        elif setaside:
            line += " The key has now been set aside: close and reopen this CLI so it bills " + (plan or "the claude.ai login") + "."
        else:
            line += (" The key couldn't be set aside in ~/.claude.json: turn off \"Use custom API key\" in /config, then close and "
                     "reopen this CLI so it bills " + (plan or "the claude.ai login") + ".")
        return auth, line, True
    if auth == "cloud":
        name = dict(CLOUDS).get(source)
        line = "[Billing] This CLI bills " + (name + " (" + source + ")" if name else "the cloud provider " + str(source) + " selects") + "."
    elif auth == "gateway":
        url = env.get("ANTHROPIC_BASE_URL")
        line = "[Billing] This CLI bills the LLM gateway " + ("at " + url + " " if url else "") + "through ANTHROPIC_AUTH_TOKEN."
    elif auth == "helper":
        line = "[Billing] This CLI bills the API key from apiKeyHelper."
    elif auth == "profile":
        line = "[Billing] This CLI bills the Anthropic profile " + (source + "." if source else "set by the federation variables.")
    elif auth == "api-key" and source in ("env", "env-p", "env-set-aside"):
        line = "[Billing] This CLI bills " + keyed + "."
        if api_mode:
            line += (" Billing is set to the API key, for emergencies only: 'orchestrator billing team' (or the dashboard's toggle)"
                     " switches every CLI back to Claude Team.")
    elif auth == "api-key":
        line = ("[Billing] This CLI bills the Anthropic Console API: " + who + "." if text(config, "primaryApiKey") and who
                else "[Billing] This CLI bills the Anthropic Console API." if text(config, "primaryApiKey") else "[Billing] This CLI bills an approved Anthropic API key.")
    elif source == "token":
        line = "[Billing] This CLI bills the Claude subscription in CLAUDE_CODE_OAUTH_TOKEN."
    elif claude_ai and api_mode:
        line = ("[Billing] Warning: billing is set to the API key, but this CLI bills " + login + ". A Launcher tab restarts it"
                " at its next idle point; outside the Launcher, close it and reopen it with ANTHROPIC_API_KEY set to the Vault key.")
        return auth, line, True
    elif claude_ai:
        line = "[Billing] This CLI bills " + login + "."
    else:
        line = "[Billing] This CLI isn't signed in to anything it can bill: run /login."
    return auth, line, False

EXEMPT_DEFAULT = ["/pacing", "/deploy", "/run", "/allocate", "/commit", "/quicksave", "/quickload"]
def exempt_commands():
    try:
        names = orch_settings().get("ExemptCommands")
    except Exception:
        names = None
    if not isinstance(names, list):
        names = EXEMPT_DEFAULT
    # /throttle and /unthrottle are gone: a list still naming them means /pacing, which replaced them (M.ORCH-T483).
    names = {str(n).strip().lstrip("/").lower() for n in names if str(n).strip().lstrip("/")}
    return {"pacing" if n in ("throttle", "unthrottle") else n for n in names}
def exempt_prompt(text):
    # The exempt command a typed prompt starts with ("/deploy now" -> "/deploy"), or None.
    m = re.match(r"\s*/([^\s/]+)(?:\s|$)", text or "")
    return "/" + m.group(1).lower() if m and m.group(1).lower() in exempt_commands() else None
def exempt_skill(name):
    return bool(name) and str(name).strip().lstrip("/").lower() in exempt_commands()

def my_pid():
    return os.environ.get("MINDATTIC_CLI_PID") or cli_pid()

def claims_still_held(text, assigned):
    # The claims nudge (AllocateWaker.ClaimsPrompt) without the tickets no longer assigned; "" when none is left.
    try:
        head, sep, rest = text.partition(" min: ")
        body, dot, tail = rest.partition(". Start a subagent")
        if not sep or not dot:
            return text
        if not assigned:
            return text  # the list couldn't be read (or is empty): the nudge stands rather than being lost
        def held(c):
            m = re.match(r"\s*((?:[A-Z]\.)?[A-Z][A-Z0-9]*-T\d+)", c, re.I)
            return m is None or m.group(1).upper() in assigned
        keep = [c for c in body.split("; ") if held(c)]
        if not keep:
            return ""
        return head + sep + "; ".join(keep) + dot + tail
    except Exception:
        return text

def take_nudges(paced=True):
    # What the orchestrator wants this CLI to do next (idle claims to start, work to claim, a resume after a limit, tickets
    # handed back after a move: M.ORCH-T864), left as nudge-<pid>-<kind>.txt files. They reach the model as hook context
    # (a prompt, a tool call, or a Stop that sends the turn on), never typed into the input box. Each is taken once; one
    # older than two of the wakers' cooldowns is stale and dropped, and none is delivered while the window's stop holds:
    # held, it's left where it is for a later hook (M.ORCH-T1004: they were deleted unread, so an unpaced CLI's, or one
    # whose CONTROL or exempt prompt ran at the stop, lost its /allocate claims and resume for good). Only a paced CLI is
    # held: one billed elsewhere (an API key) isn't held by the subscription's stop, so its nudges go through (M.ORCH-T1037).
    out = []
    try:
        pid = my_pid()
        if not pid or not str(pid).isdigit():
            return out
        files = sorted(CLI_MARKS_DIR.glob("nudge-" + str(pid) + "-*.txt"))
        if not files:
            return out
        held = False
        if paced:
            s = orchestrator_status()
            held = bool(s.get("stop")) or orchestrator_stop(s) is not None
        for nf in files:
            try:
                stale = time.time() - nf.stat().st_mtime >= 20 * 60
            except Exception:
                continue  # gone while listed: another hook took it
            if held and not stale:
                continue
            try:
                if not stale:
                    text = nf.read_text(encoding="utf-8", errors="replace").strip()
                    # A nudge to start subagents says nothing while the pace has no room for one (M.ORCH-T1253), and a claims
                    # nudge drops each ticket the orchestrator no longer has assigned (it was released or closed since it was
                    # written: `orchestrator release` says "isn't assigned"), and all of it when none is left.
                    if text and ("-claims" in nf.name or "-work" in nf.name):
                        if no_subagent_room(orchestrator_status(), pid):
                            text = ""
                        elif "-claims" in nf.name:
                            text = claims_still_held(text, set(t.upper() for t in orch_assignments()))
                    if text:
                        out.append(text)
            except Exception:
                pass
            try:
                nf.unlink()
            except Exception:
                pass
    except Exception:
        pass
    return out

try:
    # UTF-8 as Claude Code writes it, not the ANSI code page Python reads a pipe in on Windows (M.ORCH-T392).
    data = json.loads(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
sid, event = data.get("session_id"), data.get("hook_event_name")
# Codex (its Stop hook) and Gemini (AfterAgent) run this too, named on the command line: nothing here applies to
# them (their sessions aren't Claude's to cycle, and only a Claude CLI that typed /allocate is kept going).
provider = sys.argv[1].capitalize() if len(sys.argv) > 1 else "Claude"
if provider != "Claude":
    sys.exit(0)  # /allocate runs in a Claude CLI; a Codex or Gemini CLI is never pushed onto tickets
# Disk self-cleanup (M.ORCH-T1449): one free-space read at most once a minute; under the --disk-cleanup-gb line it
# starts `orchestrator disk-cleanup --quiet` detached, which deletes agent-made temp only (one run at a time).
def disk_check():
    try:
        stamp = SESSION_MARKS / "disk-check.stamp"
        now = time.time()
        try:
            if now - stamp.stat().st_mtime < 60:
                return
        except Exception:
            pass
        try:
            stamp.parent.mkdir(parents=True, exist_ok=True)
            stamp.write_text(str(now))
        except Exception:
            pass
        import shutil, tempfile, subprocess
        line = float(orch_settings().get("DiskCleanupGb", 30) or 0)
        if line <= 0 or shutil.disk_usage(tempfile.gettempdir()).free / 1073741824 >= line:
            return
        subprocess.Popen(["orchestrator", "disk-cleanup", "--quiet"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=0x00000008 | 0x00000200 | 0x08000000)
    except Exception:
        pass
disk_check()
# Every running subagent has a mark, so the pace gate can hold new ones past the allowance.
if event in ("SubagentStart", "SubagentStop"):
    if event == "SubagentStop":
        poke()
    if data.get("agent_id"):
        sub = SUBAGENT_MARKS / "subagents"
        sub.mkdir(parents=True, exist_ok=True)
        mark = sub / re.sub(r"[^A-Za-z0-9_.-]", "_", str(data["agent_id"]))
        if event == "SubagentStart":
            # A CLI billed to an API key, a gateway or a cloud provider takes no slot and spends none of the
            # subscription's windows: its subagents mustn't fill the subscription's allowance either.
            if session_auth(data.get("cwd")) != "subscription":
                sys.exit(0)
            # The CLI as the pace gate names it (MINDATTIC_CLI_PID first), or its own subagents count as another CLI's.
            mark.write_text(str(my_pid() or ""))
            # The mark now counts it, so the slot the pace gate kept for its call is let go: this CLI's oldest. Never
            # another CLI's: a subagent that took no slot (a CLI with /pacing off, an exempt turn) would free a place
            # still held for that CLI's pending call; a slot left over expires.
            release_oldest_slot(my_pid() or 0, SUBAGENT_MARKS)
        elif mark.exists():
            mark.unlink()
    sys.exit(0)
# A background shell (M.ORCH-T1528): a Bash or PowerShell call run in the background goes on after the turn ends, so it is marked
# (its task id, this CLI, when) and the dashboard counts the CLI busy while that CLI has a shell started about then still running.
# A shell stopped by hand loses its mark here; one that ended on its own is pruned by the dashboard. Never fails the hook.
if event == "PostToolUse":
    try:
        tool = str(data.get("tool_name") or "")
        tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        background = DIR / "background"
        if tool in ("Bash", "PowerShell") and tool_input.get("run_in_background") in (True, "true"):
            response = data.get("tool_response")
            task = next((response.get(k) for k in ("backgroundTaskId", "background_task_id", "task_id", "shell_id")
                         if isinstance(response, dict) and response.get(k)), None)
            if not task:
                import uuid
                task = "bg-" + uuid.uuid4().hex
            pid = my_pid()
            background.mkdir(parents=True, exist_ok=True)
            (background / re.sub(r"[^A-Za-z0-9_.-]", "_", str(task))).write_text(json.dumps({
                "cli": int(pid) if str(pid or "").isdigit() else None, "session_id": sid,
                "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "what": str(tool_input.get("description") or tool_input.get("command") or "")[:300]}))
        elif tool in ("KillShell", "KillBash", "TaskStop"):
            task = tool_input.get("shell_id") or tool_input.get("task_id") or tool_input.get("bash_id")
            mark = background / re.sub(r"[^A-Za-z0-9_.-]", "_", str(task or ""))
            if task and mark.is_file():
                mark.unlink()
    except Exception:
        pass
if event == "Stop":
    poke()
# Blocked on you (M.ORCH-T790): a permission prompt (a subagent's holds its parent's turn too) or an AskUserQuestion is
# the CLI genuinely waiting on your answer, not just idle; the dashboard flags its person's tab until the mark goes
# (its next tool result, prompt or stop, or a transcript line written since).
if sid and (event == "Notification" or (event == "PreToolUse" and data.get("tool_name") == "AskUserQuestion")):
    kind = str(data.get("notification_type") or "")
    if event == "PreToolUse" or kind in ("permission_prompt", "elicitation_dialog") or (not kind and "permission" in str(data.get("message") or "").lower()):
        try:
            DIR.mkdir(parents=True, exist_ok=True)
            state_file = DIR / (sid + ".state.json")
            state = load(state_file)
            state["asking"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            state.pop("deciding", None)  # the turn is going on, so no Stop hook is deciding it (M.ORCH-T1048)
            if data.get("transcript_path") and not state.get("transcript") and not data.get("agent_id"):
                state["transcript"] = data["transcript_path"]
            save(state_file, state)
        except Exception:
            pass
    sys.exit(0)
# A tool that ran (a subagent's too) is the prompt answered: the CLI is going again.
if sid and event == "PostToolUse" and data.get("agent_id"):
    try:
        state_file = DIR / (sid + ".state.json")
        state = load(state_file)
        if state.pop("asking", None) is not None:
            save(state_file, state)
    except Exception:
        pass
if not sid or data.get("agent_id"):
    sys.exit(0)  # subagents finish inside their parent's turn
if event == "SessionStart":
    # Every CLI is told at its start what it bills (M.ORCH-T434), as Prose checks its hub first; recorded in the session's
    # state for the daemon and the dashboard. Nothing here may hold up or fail the start: on any error it says nothing.
    try:
        auth, line, warn = billing_check(data.get("cwd"))
    except Exception:
        sys.exit(0)
    try:
        DIR.mkdir(parents=True, exist_ok=True)
        state_file = DIR / (sid + ".state.json")
        state = load(state_file)
        state.update(auth=auth, config_dir=str(PROFILE_DIR or ""), billing=line, billing_warn=warn, billing_account=config_account(claude_config()) or "",
                     pid=state.get("pid") or cli_pid(), cwd=state.get("cwd") or data.get("cwd"))
        save(state_file, state)
    except Exception:
        pass
    try:
        full = "\n" + "\n".join([line] + orchestrator_start_lines(my_pid()))
    except Exception:
        full = "\n" + line
    print(json.dumps({"systemMessage": full, "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": full}}))
    sys.exit(0)
# Recorded in the session's state, so the daemon leaves a CLI billed elsewhere out of the subscription's budget; and
# nothing the subscription's windows decide holds it here.
auth = session_auth(data.get("cwd"))
paced = auth == "subscription"
if event == "UserPromptSubmit" and paced:
    # At the window's stop a typed message is answered at once by this, not by the model: nothing is spent, so
    # the limit is never passed even by your own prompts. The orchestrator's control commands still go through.
    limits = orchestrator_status()
    if orchestrator_stop(limits) and not limits.get("stop"):
        # Latched from before the daemon stalled (M.ORCH-T196): with its window and reset, so a weekly stop says so.
        l = latched("orchestrator") or {}
        limits = dict(limits, stop=True, stop_window=limits.get("stop_window") or l.get("window"),
                      reset_time=limits.get("reset_time") or l.get("reset_time"))
    own = None if limits.get("stop") else claude_stop()
    if own:
        limits = dict(limits, stop=True, percent_used=own[0], reset_time=reset_text(own[1]), stop_window=own[2])
    # So do the exempt commands (M.ORCH-T198): their turns skip every Orchestrator gate.
    if limits.get("stop") and not CONTROL.match((data.get("prompt") or "").strip()) and not exempt_prompt(data.get("prompt")):
        log_gate_event(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "prompt-answered", 0, None, limits.get("percent_used"), account_tag())
        print(json.dumps({"decision": "block", "reason": "Not sent, so no tokens were spent: the " + str(limits.get("stop_window") or "5-hour") + " window is at its target "
            "(MindAttic.Orchestrator never lets it pass the limit). Typing works again when it resets at " +
            str(limits.get("reset_time") or "the end of the window") + ". /allocate, /pacing and /goal clear still go through."}))
        sys.exit(0)
DIR.mkdir(parents=True, exist_ok=True)
state_file = DIR / (sid + ".state.json")
state = load(state_file)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if event == "Stop":
    state.pop("exempt", None)  # an exempt command's turn ends here, and with it the exemption (M.ORCH-T198)
    # A turn that ends isn't holding on a prompt any more; one that ends because a /crossrepo or /allocate it needed was
    # refused as the model's to start (the pace gate's needs_typed) is waiting on you to type it (M.ORCH-T790).
    state.pop("asking", None)
    needs_typed = state.pop("needs_typed", None)
    # The orchestrator keeps development going without you: a turn that ends asking whether to go on, or that
    # closed a ticket and stopped, while its repo still has open tickets is told to carry on. One that stops
    # again straight after without doing anything is let go (something there really needs you). Each is logged
    # to keep-going.jsonl, which the daemon reports.
    insisted = state.get("nudged") and not state.get("worked")
    why = None
    limits = orchestrator_status()
    # At the window's target nothing more may run, so a stop is never pushed back to work: the orchestrator's stop,
    # latched or fresh, or Claude's own percent at the line with the daemon down, as a typed prompt is held to.
    stopped = paced and (bool(limits.get("stop")) or orchestrator_stop(limits) is not None or claude_stop() is not None)
    # /allocate off winds this CLI down (M.ORCH-T572): once none of its subagents is still working (they've landed and
    # closed), a turn that ends without its quicksave is told to make it, once.
    if winding_down(my_pid()) and not state.get("quicksave_told") and subagents_working(my_pid()) == 0:
        state["quicksave_told"] = True
        save(state_file, state)
        print(json.dumps({"decision": "block", "reason": wind_down_told(repo_of(data.get("cwd") or "") or Path(str(data.get("cwd") or ".")).name)}))
        sys.exit(0)
    # Saved as still busy, deciding since now, before anything slow is asked (M.ORCH-T1036): saved idle here (M.ORCH-T1005),
    # an /allocate CLI about to be sent on read idle for up to the whole budget, so a deploy's busy gate could pass and cut it
    # or a restart gate restart it mid-handoff. It is saved idle below only when the turn really ends; a hook killed at its
    # timeout leaves this mark, which the busy gate takes as the turn ended once that timeout has passed.
    try:
        deciding = dict(state)
        deciding.update(state="busy", deciding=now, pid=cli_pid(), cwd=data.get("cwd"), auth=auth, config_dir=str(PROFILE_DIR or ""))
        save(state_file, deciding)
    except Exception:
        pass
    # Only a CLI that typed /allocate is kept going, on its own repos, while they have workable tickets.
    repos = allocate_repos(my_pid())
    if repos and KEEP_GOING and not stopped and not state.get("goal"):
        why = "allocate"
    eligible = bool(why) and not no_subagent_room(limits, my_pid())
    ids = []
    if eligible:
        # Only what next would hand out: the count is the cheap first look, next has the last word. A repo on its own
        # USER_STORIES.md has tickets the count can't see, so next is asked for it even when the count is empty, and so it
        # is when a look couldn't tell. When next can't be read (not installed, failed, unparsed) the cheap count stands, as
        # before; the nagging of M.ORCH-T901 was next timing out at 6s on a busy machine (17s there), fixed by its 30s
        # timeout. The looks run inside what's left once next's slice is kept back (M.ORCH-T1045), so next always gets it.
        try:
            cheap = workable(repos, sid)
            ask = cheap is None or bool(cheap)
            if not ask:
                found = story_file_repos(repos)
                ask = found is None or bool(found)
            ids = list(cheap or [])
            if ask:
                handed = next_hands_out(repos, my_pid())
                if handed is not None:
                    ids = handed
        except Exception:
            pass
    reason = keep_going(repos, ids, sid, why, insisted) if ids else None
    # A turn ending with a nudge waiting is sent on with it, as a prompt queued in its box used to run (M.ORCH-T864).
    nudges = [] if stopped or time_left() < 2 else take_nudges(paced)
    if nudges:
        reason = ((reason + " ") if reason else "") + " ".join(nudges)
    if reason:
        state.update(nudged=True, worked=False)
        state.pop("closed", None)
        state.pop("deciding", None)
        save(state_file, state)
        print(json.dumps({"decision": "block", "reason": reason}))
        sys.exit(0)
    for k in ("nudged", "worked", "closed", "deciding"):
        state.pop(k, None)
    state.update(state="idle", at=now, pid=cli_pid(), cwd=data.get("cwd"), auth=auth, config_dir=str(PROFILE_DIR or ""))
    if needs_typed:
        state["asking"] = now
    # Held by a window (its stop): the daemon wakes it once that window
    # resets. Any other end of a turn isn't waiting on anything.
    held = limit_held(limits, data, now) if paced and stopped else None
    if held:
        state["limit_stop"] = held
    else:
        state.pop("limit_stop", None)
    if stopped and state.get("goal"):
        # /goal's own Stop hook sends the turn back while its condition isn't met, and at the stop every tool call is
        # refused, so it never is: each round would spend a turn past the line. continue:false outranks its block.
        save(state_file, state)
        # The stop's own window: a weekly wall says so, as the refusal of a typed prompt does.
        own = None if limits.get("stop_window") else claude_stop()
        window = limits.get("stop_window") or (latched("orchestrator") or {}).get("window") or (own[2] if own else None) or "5-hour"
        print(json.dumps({"continue": False, "stopReason": "The " + str(window) + " window is at its target, so /goal can't go on before it "
            "resets; the goal stays set (/goal clear drops it)."}))
        sys.exit(0)
elif event == "UserPromptSubmit":
    # A new prompt (yours, or the daemon's resume after the reset) is the CLI going on: it's no longer waiting on a window.
    # And whatever it was holding on for you is answered (M.ORCH-T790).
    for k in ("nudged", "worked", "closed", "limit_stop", "quicksave_told", "asking", "needs_typed", "deciding"):
        state.pop(k, None)
    if state.get("goal") and goal_finished(state.get("transcript"), state["goal"]):
        state.pop("goal", None)
    if data.get("transcript_path"):
        state["transcript"] = data["transcript_path"]
    # The session id beside the transcript: a crashed CLI is found by it and resumed with `claude --resume <id>` (M.ORCH-T843).
    if sid:
        state["session_id"] = str(sid)
    # The CLI's process id from its first prompt on: `orchestrator next` finds the calling CLI's own session by it, and
    # a CLI whose every stop is pushed back (an /allocate run) never reaches the Stop that used to record it.
    state.update(state="busy", at=now, warned=False, cwd=data.get("cwd"), pid=cli_pid(), auth=auth, config_dir=str(PROFILE_DIR or ""))
    # A turn typed as an exempt command (/deploy, /run, ...) skips every pace gate until it stops (M.ORCH-T198).
    exempt = exempt_prompt(data.get("prompt"))
    if exempt:
        state["exempt"] = exempt
    else:
        state.pop("exempt", None)
    typed = (data.get("prompt") or "").strip()
    prompt = typed.lower()
    # Whether this prompt asks for cross-repo work or /allocate: the pace gate lets the model start either through the
    # Skill tool only then, never on its own (M.ORCH-T435). Each prompt replaces the last one's note.
    asked = asked_for(typed)
    if asked:
        state["asked"] = asked
    else:
        state.pop("asked", None)
    # /allocate (set_allocate): THIS CLI works those repos' tickets through its own subagents until /allocate off here.
    # /allocate replaced /autopilot and its alias /work (M.ORCH-T560).
    command = "/allocate" if re.match(r"/allocate\b", prompt) else None
    if command:
        why = set_allocate(my_pid(), typed[len(command):].strip(), data.get("cwd") or "")
        if why:
            print(json.dumps({"decision": "block", "reason": why}))
            sys.exit(0)
    # /goal <condition> runs turn after turn until its condition holds; cycling would end it, so the session is
    # marked and left to Claude's own compaction until /goal clear (M.ORCH-T93).
    if re.match(r"/goal\b", prompt):
        args = typed[len("/goal"):].strip()
        # Claude Code clears a goal on any of these; a bare /goal only shows its status, and leaves it running.
        # Only the word alone: "/goal clear all lint warnings" sets a new goal in Claude Code, as it does here.
        if re.fullmatch(r"(clear|off|stop|reset|none|cancel)", args, re.I):
            state.pop("goal", None)
        elif args:
            state["goal"] = args
    # /crossrepo <A,B|all> lets this CLI work other repos too (the explicit exception to M.ORCH-T95); /crossrepo off ends it.
    if prompt.startswith("/crossrepo"):
        set_crossrepo(my_pid(), typed[len("/crossrepo"):].strip())
    # /pacing off runs THIS CLI (its process, so subagents and /clear included) without pace holds until it closes or
    # /pacing on; on is every new CLI's default. A bare /pacing says which, answered here unsent (M.ORCH-T483).
    # The stop at the window's target and the weekly stop hold either way.
    if re.match(r"/pacing\b", prompt):
        pid = my_pid()
        arg = prompt[len("/pacing"):].strip()
        mark = DIR / ("unthrottled-" + str(pid)) if pid else None
        if mark is not None and arg == "off":
            mark.write_text(now)
        elif mark is not None and arg == "on":
            if mark.exists():
                mark.unlink()
        else:
            if mark is None:
                why = "Pacing: this CLI's process couldn't be found, so its pacing can't be read or changed."
            elif mark.exists():
                why = ("Pacing is off in this CLI: no pace holds until it closes or you type /pacing on. "
                       "The stop at the window's target and the weekly stop still apply.")
            else:
                why = "Pacing is on in this CLI (the default): its tool calls are held to the pace. /pacing off lifts the holds until it closes."
            if arg:
                why = "/pacing takes on or off; nothing changed. " + why
            print(json.dumps({"decision": "block", "reason": why}))
            sys.exit(0)
    # Each turn starts knowing how many subagents the pace allows right now, and whether the window is at its stop.
    s = orchestrator_status()
    notes = [n for n in (s.get("subagent_note"), s.get("stop_note")) if n]
    if CROSSREPO_NOTE[0]:
        notes.append(CROSSREPO_NOTE[0])
    if ALLOCATE_NOTE[0]:
        notes.append(ALLOCATE_NOTE[0])
    notes.extend(take_nudges(paced))
    # Safety net for the ticket-per-request rule (MAT-T58, M.ORCH-T843): a genuinely typed prompt (not a slash command, not
    # a system or task notification, which Claude Code delivers as <tag>...) in a MindAttic repo says to file its ticket first.
    try:
        if typed and not typed.startswith(("/", "<")) and repo_of(data.get("cwd") or "") and not re.search(r"[A-Z][A-Za-z.]*-T\d+", typed):
            notes.append("If this is a new task with no ticket yet, file its ticket first (tickets ticket new) before any work.")
    except Exception:
        pass
    # The images pasted into it, kept for good and to be linked from its ticket (M.ORCH-T1117).
    images = save_images(typed, sid, data.get("cwd"))
    if images:
        notes.append(images)
    out ={"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": " ".join(notes)}} if notes else {}
    # A CLI that started before its SessionStart hook was registered is checked on its first prompt instead, and told
    # only when it's billing the key rather than the claude.ai login (M.ORCH-T434).
    # After a /login to another account the line from its start names the old one: the first prompt since says the new
    # line, once (M.ORCH-T486). A state from before the account was recorded beside the line just records it.
    signed = None
    try:
        signed = config_account(claude_config()) or ""
    except Exception:
        pass
    if "billing" not in state:
        try:
            _, line, warn = billing_check(data.get("cwd"))
            state.update(billing=line, billing_warn=warn, billing_account=signed)
            if warn:
                out["systemMessage"] = line
                told = out.setdefault("hookSpecificOutput", {"hookEventName": "UserPromptSubmit", "additionalContext": ""})
                told["additionalContext"] = (told["additionalContext"] + " " + line).strip()
        except Exception:
            pass
    elif signed is not None and state.get("billing_account") is None:
        state["billing_account"] = signed
    elif signed is not None and state.get("billing_account") != signed:
        try:
            auth, line, warn = billing_check(data.get("cwd"))
            was = state.get("billing")
            state.update(auth=auth, config_dir=str(PROFILE_DIR or ""), billing=line, billing_warn=warn, billing_account=signed)
            if line != was:
                out["systemMessage"] = line
                told = out.setdefault("hookSpecificOutput", {"hookEventName": "UserPromptSubmit", "additionalContext": ""})
                told["additionalContext"] = (told["additionalContext"] + " " + line).strip()
        except Exception:
            pass
    # A dead or stalled daemon is said to you, on every prompt, until it's back (M.ORCH-T167): nothing is paced
    # meanwhile except Claude's own 99% stop.
    down = daemon_down()
    if down is not None:
        out["systemMessage"] = ((out["systemMessage"] + " ") if out.get("systemMessage") else "") + ("MindAttic.Orchestrator hasn't updated the pace for " + str(int(down // 60)) + " min: its daemon "
            "isn't running, so agents aren't being paced (only Claude's own " + str(int(five_hour_stop_percent())) + "% 5-hour and " + str(int(week_stop_percent())) + "% weekly stops still hold). "
            "Start it: C:\\Apps\\MindAttic.Orchestrator\\MindAttic.Orchestrator.Desktop.exe")
    if out:
        print(json.dumps(out))
elif event == "PostToolUse":
    # Its tool ran, so whatever it asked you was answered (M.ORCH-T790).
    touched = state.pop("asking", None) is not None
    # A tool ran, so the turn went on: a deciding mark left by a Stop hook cut off at its timeout goes (M.ORCH-T1048).
    if state.pop("deciding", None) is not None:
        touched = True
    # The quicksave /allocate off winds down to: this CLI is wound down (M.ORCH-T572).
    try:
        if QUICKSAVE.search(str((data.get("tool_input") or {}).get("command") or "")):
            wound_down(my_pid())
    except Exception:
        pass
    # Running `orchestrator next` only asks for work: when it hands out nothing, stopping again is insisting (M.ORCH-T188).
    asked = re.search(r"\borchestrator(?:\.exe)?['\"]?\s+next\b", str((data.get("tool_input") or {}).get("command") or ""))
    if state.get("nudged") and not state.get("worked") and not asked:
        state["worked"] = touched = True  # it carried on after being told to
    # A ticket closed this turn: stopping right after it, with more open, is a stop keep-going catches.
    closed = re.search(r"\b(?:tickets|workflow)(?:\.exe)?['\"]?\s+ticket\s+close\s+['\"]?((?:[A-Z]\.)?[A-Z][A-Z0-9]*-T\d+)",
                       str((data.get("tool_input") or {}).get("command") or ""))
    if closed and closed.group(1) not in state.get("closed", []):
        state["closed"] = state.get("closed", []) + [closed.group(1)]
        touched = True
    if touched:
        try:
            save(state_file, state)
        except Exception:
            pass
    # A busy turn (an /allocate run never submits a prompt) takes its nudges here, as the old typed prompt waited in its box.
    said = take_nudges(paced)
    # No context warning any more: nothing quicksaves, clears or reloads a session for it (2026-10-16), so a turn
    # is never told to stop for its context; Claude's own compaction handles a full one.
    if not said:
        sys.exit(0)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": " ".join(said)}}))
else:
    sys.exit(0)
# Every Claude CLI runs this hook, so its last save never raises (M.ORCH-T1048).
try:
    save(state_file, state)
except Exception:
    pass