#!/usr/bin/env python3
# MindAttic commit gate (M.ORCH-T1530): agents sharing one checkout on main must not commit, unstage or close each
# other's unfinished work. Unity.GridGame 2026-11-08: two commits swept in another ticket's uncommitted JSON, one
# committed another agent's in-progress tool plus 33 half-processed portraits and closed that agent's ticket.
#
# Two halves, one script:
#
#   CLI hook (PreToolUse / PostToolUse / SubagentStart / SubagentStop / SessionEnd; wired by install-hooks.ps1)
#     - tracks, per repo, which agent (session + subagent id) modified which path, and for which ticket: Edit/Write/
#       MultiEdit/NotebookEdit record their file on the call; a shell call records the dirty files whose mtime falls
#       inside its run (git status before nothing, after once: ~0.2 s).
#     - learns each agent's ticket from what it runs: `tickets ticket working|close <ID>` and `git commit ... (<ID>)`
#       (sure), the Agent/Task prompt that spawned it (likely), `tickets ticket show|note <ID>` (a guess).
#     - refuses `tickets ticket close <ID>` from a session that doesn't hold the ticket's claim (ticket_work), or while
#       another live agent of this session works that ticket and this one works another; MINDATTIC_FORCE_CLOSE=1 in
#       the command overrides (only when the user said to close it).
#     - warns (never refuses) before an edit to a file another live ticket has uncommitted changes in.
#     - leaves a marker naming the agent behind each `git commit` so the git hook below knows who is committing.
#
#   git hook (`commit-gate.py git-commit-msg <msgfile>`, called by shared/hooks/commit-msg after the ticket check)
#     - sees exactly the paths being committed (GIT_INDEX_FILE: .git/index for a bare commit, next-index-*.lock for
#       `git commit -- <paths>`, index.lock for -a) and refuses the commit when one of them holds uncommitted changes
#       another agent made for a different, still-live ticket (open, and claimed or its agent seen lately).
#     - refuses a bare / -a commit that would take another live session's modified file, whatever its ticket: name
#       your paths (`git commit -m "..." -- <paths>`).
#     - warns on a bare commit while other agents are live in the checkout, and on a committed file that still has
#       unstaged hunks another agent touched (a mis-splice waiting to happen).
#     - on success, clears the tracking of the committed paths.
#
# Overrides: MINDATTIC_SHARED_OK=<path>[,<path>...] or =all on the git commit lets those paths through (genuinely shared
# files); shared/hooks/commit-gate-shared.json and a repo's .agent/commit-gate-shared.json list paths that always pass
# (docs/USER_STORIES.md, the ticket and orchestrator databases). MINDATTIC_COMMIT_GATE=off turns the whole gate off.
#
# Fails open: any error allows the call or the commit. With no other live agent in the checkout nothing is ever
# refused, so a solo user is never blocked.
# Usage: python commit-gate.py [claude|codex|kimi|agy [event]]   (hook JSON on stdin)
#        python commit-gate.py git-commit-msg <msgfile>             (from the commit-msg hook; exit 3 = refuse)
import fnmatch, hashlib, json, os, re, sqlite3, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("MINDATTIC_COMMIT_GATE_DIR") or (Path.home() / ".claude" / "session-context" / "commit-gate"))
WS = Path(os.environ.get("MINDATTIC_WORKSPACE") or HERE.parent.parent.parent)
TICKETS_DB = (os.environ.get("MINDATTIC_TICKETS_DB") or os.environ.get("MINDATTIC_WORKFLOW_DB")
              or str(WS / "MindAttic.Tickets" / "data" / "Tickets.db"))
SHARED_FILE = HERE / "commit-gate-shared.json"
LIVE_SECS = float(os.environ.get("MINDATTIC_COMMIT_GATE_LIVE_SECS") or 3 * 3600)  # an agent unseen this long isn't live
MARKER_SECS = 600            # a git commit's "who is committing" marker is good this long
KEEP_SECS = 3 * 24 * 3600    # state untouched this long is swept
LOG_MAX = 2 * 1024 * 1024    # a repo's touch log is compacted past this
REFUSE_EXIT = 3              # commit-msg refuses only on this code; a crash (1) or anything else lets the commit through

ID = r"[A-Z][A-Z0-9]*(?:\.[A-Z0-9][A-Z0-9]*)*-T[0-9]+"
ID_RX = re.compile(r"\b(" + ID + r")\b")
SURE, LIKELY, GUESS = 3, 2, 1

def now():
    return time.time()

def safe(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(name or ""))[:120]

def first_str(*values):
    for v in values:
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None

# ---- paths and repos -----------------------------------------------------------------------------------------------

def native(path):
    # Git Bash's /d/Projects/... is D:/Projects/...
    return re.sub(r"^/([a-zA-Z])(?=/|$)", r"\1:", str(path or "").strip().strip("\"'"))

def repo_root(path):
    try:
        p = Path(native(path)).resolve()
        if p.is_file() or not p.exists():
            p = p.parent
        while p and p != p.parent:
            if (p / ".git").exists():
                return p
            p = p.parent
    except Exception:
        pass
    return None

def repo_key(root):
    s = str(root).replace("\\", "/").rstrip("/").lower()
    return safe(Path(s).name) + "-" + hashlib.md5(s.encode("utf-8")).hexdigest()[:8]

def rel_in(root, path):
    try:
        return Path(native(path)).resolve().relative_to(Path(root).resolve()).as_posix()
    except Exception:
        return None

def git(root, *args, timeout=5, env=None):
    r = subprocess.run(["git", "-C", str(root)] + list(args), capture_output=True, timeout=timeout, env=env)
    if r.returncode != 0:
        raise RuntimeError("git " + " ".join(args) + " failed")
    return r.stdout.decode("utf-8", errors="replace")

def zlist(text):
    return [p for p in text.split("\0") if p]

# ---- state ---------------------------------------------------------------------------------------------------------

def read_json(p, default=None):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception:
        return default

def write_json(p, value):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(p) + "." + str(os.getpid()) + ".tmp")
    tmp.write_text(json.dumps(value), encoding="utf-8")
    os.replace(tmp, p)

def actor_key(sid, agent):
    return f"{sid or '?'}/{agent or 'main'}"

def actor_path(sid, agent):
    return STATE_DIR / f"actor-{safe(sid)}--{safe(agent or 'main')}.json"

def load_actor(sid, agent):
    return read_json(actor_path(sid, agent), None) or {"sid": sid, "agent": agent, "ticket": None, "strength": 0}

def save_actor(a):
    a["seen"] = now()
    write_json(actor_path(a.get("sid"), a.get("agent")), a)

def all_actors():
    out = {}
    try:
        for f in STATE_DIR.glob("actor-*.json"):
            a = read_json(f)
            if isinstance(a, dict):
                out[actor_key(a.get("sid"), a.get("agent"))] = a
    except Exception:
        pass
    return out

def actor_live(a, t=None):
    return bool(a) and not a.get("ended") and (t or now()) - float(a.get("seen") or 0) <= LIVE_SECS

def log_path(root):
    return STATE_DIR / f"touch-{repo_key(root)}.jsonl"

def append_events(root, events):
    if not events:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = log_path(root)
    data = "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in events)
    with open(p, "a", encoding="utf-8") as f:
        f.write(data)
    try:
        if p.stat().st_size > LOG_MAX:
            compact(p)
    except Exception:
        pass

def compact(p):
    cutoff = now() - KEEP_SECS
    keep = [e for e in read_events_file(p) if float(e.get("at") or 0) >= cutoff]
    tmp = Path(str(p) + "." + str(os.getpid()) + ".tmp")
    tmp.write_text("".join(json.dumps(e, separators=(",", ":")) + "\n" for e in keep), encoding="utf-8")
    os.replace(tmp, p)

def read_events_file(p):
    out = []
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                    if isinstance(e, dict):
                        out.append(e)
                except Exception:
                    continue
    except Exception:
        pass
    return out

def touches(root):
    """{path: [touch events after that path's last clear]}"""
    by = {}
    for e in read_events_file(log_path(root)):
        p = e.get("p")
        if not p:
            continue
        if e.get("k") == "clear":
            by[p] = [x for x in by.get(p, []) if float(x.get("at") or 0) > float(e.get("at") or 0)]
        elif e.get("k") == "touch":
            by.setdefault(p, []).append(e)
    return by

def sweep():
    try:
        cutoff = now() - KEEP_SECS
        for f in STATE_DIR.glob("*"):
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink()
    except Exception:
        pass

# ---- tickets -------------------------------------------------------------------------------------------------------

_tdb = {}
def ticket_row(tid):
    """(status, claim_session, claim_login) for a ticket; None when it can't be read."""
    if not tid:
        return None
    if tid in _tdb:
        return _tdb[tid]
    row = None
    try:
        db = sqlite3.connect(Path(os.path.abspath(TICKETS_DB)).as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            t = db.execute("SELECT status FROM tickets WHERE id = ? COLLATE NOCASE", (tid,)).fetchone()
            w = None
            try:
                w = db.execute("SELECT session, login FROM ticket_work WHERE ticket_id = ? COLLATE NOCASE", (tid,)).fetchone()
            except Exception:
                pass
            if t:
                row = (t[0], (w[0] if w else None) or None, (w[1] if w else None) or None)
        finally:
            db.close()
    except Exception:
        row = None
    _tdb[tid] = row
    return row

def ticket_open(tid):
    r = ticket_row(tid)
    return r is None or r[0] == "open"   # unknown counts as open: fail toward protecting the other agent's work

def ticket_live(tid, actors):
    """An open ticket that is claimed (ticket_work) or that a live agent works."""
    r = ticket_row(tid)
    if r is not None and r[0] != "open":
        return False
    if r is not None and (r[1] or r[2]):
        return True
    return any(a.get("ticket") == tid and actor_live(a) for a in actors.values())

def learn_ticket(a, tid, strength):
    """Sets an agent's ticket when the new evidence is at least as strong, or its current ticket is closed."""
    if not tid:
        return False
    cur = a.get("ticket")
    if cur == tid:
        if strength > int(a.get("strength") or 0):
            a["strength"] = strength
            return True
        return False
    if not cur or strength >= int(a.get("strength") or 0) or not ticket_open(cur):
        a["ticket"], a["strength"] = tid, strength
        return True
    return False

# ---- shared allow-list ---------------------------------------------------------------------------------------------

def shared_globs(root):
    globs = []
    for f in (SHARED_FILE, Path(root) / ".agent" / "commit-gate-shared.json"):
        data = read_json(f, {}) or {}
        globs += [g for g in (data.get("shared") or []) if isinstance(g, str)]
    return globs

def is_shared(path, globs, ok):
    if ok == "all" or path in ok:
        return True
    return any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(Path(path).name, g) for g in globs)

def override_paths():
    v = (os.environ.get("MINDATTIC_SHARED_OK") or "").strip()
    if v.lower() in ("1", "all", "true", "yes", "*"):
        return "all"
    return {p.strip().replace("\\", "/").lstrip("./") for p in v.split(",") if p.strip()}

# ---- reading a shell command ---------------------------------------------------------------------------------------

def command_of(tool_input):
    if not isinstance(tool_input, dict):
        return None
    for key in ("command", "cmd", "script"):
        v = tool_input.get(key)
        if isinstance(v, list):
            v = " ".join(str(x) for x in v)
        if isinstance(v, str) and v.strip():
            return v
    return None

def strip_bodies(command):
    c = re.sub(r"<<-?\s*([\"']?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?=\n|$)", "\n", command, flags=re.S)
    return re.sub(r"@([\"'])\s*\n.*?\n\1@", "\n", c, flags=re.S)

def segments(command):
    return [s.strip() for s in re.split(r"[;\n|]|&&|\|\|", strip_bodies(command)) if s.strip()]

TICKETS_CMD = r"(?:^|[\s&\"'(/\\])(?:tickets|workflow)(?:\.exe)?[\"']?\s+ticket\s+"
CLOSE_RX = re.compile(TICKETS_CMD + r"close\s+(" + ID + r")", re.I)
SURE_RX = re.compile(TICKETS_CMD + r"(?:working|close)\s+(" + ID + r")", re.I)
GUESS_RX = re.compile(TICKETS_CMD + r"(?:show|note)\s+(" + ID + r")", re.I)
GIT_COMMIT_RX = re.compile(r"(?:^|[\s&\"'(])git(?:\.exe)?[\"']?(?:\s+(?:-C\s+(?:\"[^\"]*\"|'[^']*'|\S+)|-c\s+\S+|--\S+))*\s+commit\b", re.I)
SUBJECT_ID_RX = re.compile(r"\((" + ID + r")\)")
FORCE_CLOSE_RX = re.compile(r"MINDATTIC_FORCE_CLOSE\s*=\s*['\"]?(?:1|true|yes)\b", re.I)

def dirs_named(command, cwd):
    """The folders a command works in: cwd, each `cd <dir>`, each `git -C <dir>`, each `Set-Location <dir>`."""
    out = [cwd] if cwd else []
    for m in re.finditer(r"(?:^|[;&|\n]\s*|\s)(?:cd|pushd|Set-Location|sl)\s+(?:-LiteralPath\s+|-Path\s+|/d\s+)?(\"[^\"]+\"|'[^']+'|[^\s;&|]+)", command, re.I):
        out.append(m.group(1))
    for m in re.finditer(r"\bgit(?:\.exe)?[\"']?\s+-C\s+(\"[^\"]+\"|'[^']+'|\S+)", command, re.I):
        out.append(m.group(1))
    return [native(d) for d in out]

def repos_named(command, cwd):
    roots, seen = [], set()
    base = Path(native(cwd)) if cwd else None
    for d in dirs_named(command, cwd):
        try:
            p = Path(d)
            if not p.is_absolute() and base is not None:
                p = base / p
            r = repo_root(p)
        except Exception:
            r = None
        if r is not None and str(r).lower() not in seen:
            seen.add(str(r).lower())
            roots.append(r)
    return roots[:4]

# ---- CLI hook ------------------------------------------------------------------------------------------------------

def deny(provider, event, reason):
    if provider == "agy":
        return {"decision": "deny", "reason": reason}
    return {"hookSpecificOutput": {"hookEventName": event or "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}

def note(provider, event, text):
    if provider == "agy":
        return None
    return {"hookSpecificOutput": {"hookEventName": event or "PreToolUse", "additionalContext": text}}

def describe(a):
    if not a:
        return "another agent"
    who = f"session {a.get('sid') or '?'}"
    if a.get("agent"):
        who += f", subagent {a.get('agent')}"
    return who

def foreign_live(root, path, me, my_ticket, actors, t=None):
    """The live other-ticket touches on one path: [(actor, ticket)], ticket None when unknown."""
    out = []
    for e in touches(root).get(path, []):
        k = actor_key(e.get("s"), e.get("a"))
        if k == me:
            continue
        a = actors.get(k)
        tid = e.get("t") or (a or {}).get("ticket")
        if tid and tid == my_ticket:
            continue
        if tid and ticket_live(tid, actors):
            out.append((a or {"sid": e.get("s"), "agent": e.get("a")}, tid))
        elif not tid and actor_live(a, t):
            out.append((a, None))
    return out

def close_guard(command, sid, agent, me_actor, actors):
    if FORCE_CLOSE_RX.search(command):
        return None
    for seg in segments(command):
        m = CLOSE_RX.search(seg)
        if not m:
            continue
        tid = m.group(1).upper()
        row = ticket_row(tid)
        if row is not None and row[0] != "open":
            continue
        claim_sid = row[1] if row else None
        if claim_sid and sid and claim_sid != sid:
            return (f"COMMIT GATE (M.ORCH-T1530): {tid} is claimed by session {claim_sid}"
                    + (f" ({row[2]})" if row and row[2] else "") + f", not this one ({sid}). Only the session holding a "
                    "ticket's claim closes it; closing it here would end another agent's work out from under it. Close your "
                    "own ticket instead. If the user told you to close this one anyway, rerun the command with "
                    "MINDATTIC_FORCE_CLOSE=1 in front of it (Bash: MINDATTIC_FORCE_CLOSE=1 tickets ticket close ...; "
                    "PowerShell: $env:MINDATTIC_FORCE_CLOSE=1; tickets ticket close ...).")
        mine = me_actor.get("ticket")
        if mine == tid:
            continue
        others = [a for k, a in actors.items() if k != actor_key(sid, agent) and a.get("ticket") == tid
                  and int(a.get("strength") or 0) >= LIKELY and actor_live(a)]
        if others and mine and int(me_actor.get("strength") or 0) >= LIKELY:
            return (f"COMMIT GATE (M.ORCH-T1530): {tid} is being worked by {describe(others[0])}, and this agent works "
                    f"{mine}. Close your own ticket ({mine}); {tid} is closed by the agent working it. If the user told you "
                    "to close it anyway, rerun with MINDATTIC_FORCE_CLOSE=1 in front of the command.")
    return None

def record_touch(root, rel, sid, agent, a):
    tid = a.get("ticket") if int(a.get("strength") or 0) >= SURE else None
    append_events(root, [{"k": "touch", "p": rel, "s": sid, "a": agent, "t": tid, "at": now()}])

def bash_mark(data):
    tu = first_str(data.get("tool_use_id"), data.get("toolUseId"))
    if tu:
        return STATE_DIR / f"bash-{safe(tu)}.json"
    return None

READ_ONLY_FIRST = re.compile(r"^(?:git|tickets|workflow|orchestrator|ls|dir|cat|type|head|tail|grep|rg|find|echo|pwd|"
                             r"Get-ChildItem|Get-Content|Select-String|Test-Path|Write-Output|Write-Host|wc|which|where)(?:\.exe)?\b", re.I)

def read_only(command):
    """A call that only reads (or only runs git/tickets): no need to look for files it wrote."""
    segs = [s for s in segments(command) if not re.match(r"^(?:cd|pushd|popd|Set-Location)\b", s, re.I)]
    return bool(segs) and all(READ_ONLY_FIRST.match(s) for s in segs)

def attribute_shell(data, sid, agent, a, actors):
    mark = bash_mark(data)
    m = read_json(mark, None) if mark else None
    if mark:
        try:
            mark.unlink()
        except Exception:
            pass
    if not m:
        return
    command, start, end = m.get("command") or "", float(m.get("start") or 0), now()
    if read_only(command):
        return
    others = []
    try:
        for f in STATE_DIR.glob("bash-*.json"):
            o = read_json(f)
            # A mark older than half an hour is a call whose PostToolUse never came (interrupted): not running now.
            if o and actor_key(o.get("sid"), o.get("agent")) != actor_key(sid, agent) and end - float(o.get("start") or 0) <= 1800:
                others.append(float(o.get("start") or 0))
    except Exception:
        pass
    for root in [Path(r) for r in (m.get("repos") or [])]:
        try:
            dirty = zlist(git(root, "status", "--porcelain=v1", "-z", "-unormal", timeout=4))
        except Exception:
            continue
        log = touches(root)
        events, i = [], 0
        while i < len(dirty):
            entry = dirty[i]
            i += 1
            code, rel = entry[:2], entry[3:]
            if code[0] in "RC" and i < len(dirty):
                i += 1   # rename/copy: the next field is the old path
            if not rel or rel.endswith("/"):
                continue
            try:
                mt = (root / rel).stat().st_mtime
            except Exception:
                continue   # deleted: no mtime to place it by
            if not (start - 2 <= mt <= end + 2):
                continue
            if any(s <= mt + 2 for s in others):
                continue   # another agent's shell call ran then too: can't tell whose it is
            if any(actor_key(e.get("s"), e.get("a")) != actor_key(sid, agent) and abs(float(e.get("at") or 0) - mt) <= 3
                   for e in log.get(rel, [])):
                continue   # another agent edited it just then
            tid = a.get("ticket") if int(a.get("strength") or 0) >= SURE else None
            events.append({"k": "touch", "p": rel, "s": sid, "a": agent, "t": tid, "at": mt, "via": "shell"})
        append_events(root, events[:2000])

def handle(data, provider="claude", event_arg=None):
    if (os.environ.get("MINDATTIC_COMMIT_GATE") or "").lower() in ("off", "0", "false", "no"):
        return None
    event = data.get("hook_event_name") or data.get("hookEventName") or event_arg or ""
    sid = first_str(data.get("session_id"), data.get("sessionId"), data.get("conversationId"))
    agent = first_str(data.get("agent_id"), data.get("agentId"))
    if not sid:
        return None
    if event == "SubagentStart":
        a = load_actor(sid, agent)
        pend = read_json(STATE_DIR / f"spawn-{safe(sid)}.json", []) or []
        pend = [p for p in pend if now() - float(p.get("at") or 0) <= 300]
        if pend:
            learn_ticket(a, pend.pop(0).get("ticket"), LIKELY)
            write_json(STATE_DIR / f"spawn-{safe(sid)}.json", pend)
        save_actor(a)
        return None
    if event in ("SubagentStop", "SessionEnd"):
        if event == "SessionEnd":
            for f in STATE_DIR.glob(f"actor-{safe(sid)}--*.json"):
                x = read_json(f)
                if isinstance(x, dict):
                    x["ended"] = now()
                    write_json(f, x)
        else:
            a = load_actor(sid, agent)
            a["ended"] = now()
            write_json(actor_path(sid, agent), a)
        sweep()
        return None
    tool = data.get("tool_name") or ""
    tin = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    cwd = first_str(data.get("cwd"), data.get("workspaceRoot"), os.getcwd())
    a = load_actor(sid, agent)
    me = actor_key(sid, agent)

    if event == "PostToolUse":
        if tool in ("Bash", "PowerShell", "shell", "run_shell_command"):
            attribute_shell(data, sid, agent, a, all_actors())
        return None
    if event != "PreToolUse":
        return None

    out = None
    if tool in ("Agent", "Task"):
        text = " ".join(str(tin.get(k) or "") for k in ("description", "prompt"))
        ids = list(dict.fromkeys(m.group(1) for m in ID_RX.finditer(text)))
        if ids:
            p = STATE_DIR / f"spawn-{safe(sid)}.json"
            pend = [x for x in (read_json(p, []) or []) if now() - float(x.get("at") or 0) <= 300]
            pend.append({"ticket": ids[0], "at": now()})
            write_json(p, pend)
        save_actor(a)
        return None

    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write_file", "replace"):
        fp = first_str(tin.get("file_path"), tin.get("notebook_path"), tin.get("path"), tin.get("absolute_path"))
        root = repo_root(fp) if fp else None
        rel = rel_in(root, fp) if root else None
        save_actor(a)
        if root and rel:
            actors = all_actors()
            others = foreign_live(root, rel, me, a.get("ticket"), actors)
            record_touch(root, rel, sid, agent, a)
            if others:
                o, tid = others[0]
                out = note(provider, event,
                           f"COMMIT GATE (M.ORCH-T1530): {rel} already has uncommitted changes "
                           + (f"for {tid} " if tid else "") + f"from {describe(o)}. Another agent is mid-work in this "
                           "file: don't commit its changes with your ticket, and don't stage, unstage, revert or reformat "
                           "them. If your ticket truly needs this file, keep your edit minimal and commit only your own "
                           "hunks; the commit gate refuses a commit carrying another live ticket's work.")
        return out

    command = command_of(tin)
    if not command:
        save_actor(a)
        return None
    actors = all_actors()
    reason = close_guard(command, sid, agent, a, actors)
    if reason:
        save_actor(a)
        return deny(provider, event, reason)
    for m in SURE_RX.finditer(strip_bodies(command)):
        learn_ticket(a, m.group(1).upper(), SURE)
    for m in GUESS_RX.finditer(strip_bodies(command)):
        learn_ticket(a, m.group(1).upper(), GUESS)
    repos = repos_named(command, cwd)
    if GIT_COMMIT_RX.search(strip_bodies(command)):
        sm = SUBJECT_ID_RX.search(command)
        tid = sm.group(1).upper() if sm else None
        learn_ticket(a, tid, SURE)
        p = STATE_DIR / f"commit-{safe(sid)}.json"
        marks = [x for x in (read_json(p, []) or []) if now() - float(x.get("at") or 0) <= MARKER_SECS]
        marks.append({"agent": agent, "ticket": tid, "repos": [str(r) for r in repos], "at": now()})
        write_json(p, marks[-20:])
    save_actor(a)
    mark = bash_mark(data)
    if mark and repos:
        write_json(mark, {"sid": sid, "agent": agent, "start": now(), "command": command[:4000],
                          "repos": [str(r) for r in repos]})
    return None

# ---- git hook ------------------------------------------------------------------------------------------------------

def commit_msg(msgfile):
    if (os.environ.get("MINDATTIC_COMMIT_GATE") or "").lower() in ("off", "0", "false", "no"):
        return 0
    try:
        lines = [l.rstrip("\r\n") for l in Path(msgfile).read_text(encoding="utf-8", errors="replace").splitlines()]
    except Exception:
        return 0
    subject = next((l for l in lines if l.strip() and not l.startswith("#")), "")
    if re.match(r"(?:Merge |fixup! |squash! |amend! )", subject):
        return 0
    m = re.search(r"\((" + ID + r")\)\"?\s*$", subject)
    ticket = m.group(1).upper() if m else None
    root = Path(git(os.getcwd(), "rev-parse", "--show-toplevel").strip())
    try:
        committed = zlist(git(root, "diff", "--cached", "--name-only", "-z", "HEAD"))
    except Exception:
        return 0   # first commit, or no HEAD: nothing to protect yet
    idx = os.environ.get("GIT_INDEX_FILE") or ".git/index"
    bare = Path(idx).name in ("index", "index.lock")
    sid = first_str(os.environ.get("CLAUDE_CODE_SESSION_ID"), os.environ.get("CODEX_SESSION_ID"))
    agent = None
    if sid:
        marks = [x for x in (read_json(STATE_DIR / f"commit-{safe(sid)}.json", []) or [])
                 if now() - float(x.get("at") or 0) <= MARKER_SECS and (not ticket or x.get("ticket") in (ticket, None))
                 and (not x.get("repos") or any(str(root).lower() == str(Path(r)).lower() for r in x["repos"]))]
        if marks:
            agent = marks[-1].get("agent")
    me = actor_key(sid, agent) if sid else None
    actors = all_actors()
    globs, ok = shared_globs(root), override_paths()
    log = touches(root)

    refuse, soft = [], []   # (path, actor, ticket)
    for path in committed:
        if is_shared(path, globs, ok):
            continue
        for e in log.get(path, []):
            k = actor_key(e.get("s"), e.get("a"))
            if me and k == me:
                continue
            a = actors.get(k) or {"sid": e.get("s"), "agent": e.get("a")}
            tid = e.get("t") or a.get("ticket")
            if tid and ticket and tid == ticket:
                continue
            if tid and ticket_live(tid, actors):
                # Same session, subagent unknown: it may be this agent's own earlier work under another ticket.
                if not me or e.get("s") != sid or agent:
                    refuse.append((path, a, tid))
                else:
                    soft.append((path, a, tid))
            elif not tid and actor_live(actors.get(k)) and e.get("s") != sid:
                soft.append((path, a, None))
    if bare:
        refuse += [x for x in soft if x[1].get("sid") != sid]
        soft = [x for x in soft if x[1].get("sid") == sid]

    def lines_of(items):
        seen, out = set(), []
        for path, a, tid in items:
            if path in seen:
                continue
            seen.add(path)
            out.append(f"  {path}  <- " + (f"{tid}, " if tid else "") + describe(a))
        return out[:12] + ([f"  ... and {len(seen) - 12} more"] if len(seen) > 12 else [])

    if refuse:
        tids = sorted({t for _, _, t in refuse if t})
        msg = ["", "COMMIT GATE (M.ORCH-T1530): commit refused. It would take uncommitted work another live agent made"
               + (f" for {', '.join(tids)}" if tids else "") + (f", not for {ticket}" if ticket else "") + ":"]
        msg += lines_of(refuse)
        if bare:
            msg += ["This is a bare commit of the whole index (or -a). In a shared checkout commit by path:",
                    "  git commit -m \"<subject> (<ID>)\" -- <your paths>"]
        msg += ["Leave those files alone (don't stage, unstage, revert or stash them); their agent commits them.",
                "If a file is genuinely shared and both tickets need it, rerun with MINDATTIC_SHARED_OK=<path>[,<path>]",
                "(Bash: MINDATTIC_SHARED_OK=docs/x.json git commit ...; PowerShell: $env:MINDATTIC_SHARED_OK='docs/x.json'; git commit ...).", ""]
        sys.stderr.write("\n".join(msg) + "\n")
        return REFUSE_EXIT

    warn = []
    if soft:
        warn += ["COMMIT GATE (M.ORCH-T1530) warning: these files also have changes from another agent whose ticket is unknown:"]
        warn += lines_of(soft)
    if bare:
        others = {actor_key(e.get("s"), e.get("a")) for evs in log.values() for e in evs}
        others = [k for k in others if k != me and actor_live(actors.get(k))]
        if others:
            warn += [f"COMMIT GATE (M.ORCH-T1530) warning: bare commit in a checkout {len(others)} other live agent(s) work in.",
                     "Commit by path next time: git commit -m \"<subject> (<ID>)\" -- <paths>"]
    try:
        unstaged = set(zlist(git(root, "diff", "--name-only", "-z")))
    except Exception:
        unstaged = set()
    partial = []
    for path in committed:
        if path in unstaged:
            for e in log.get(path, []):
                if actor_key(e.get("s"), e.get("a")) != me:
                    partial.append((path, actors.get(actor_key(e.get("s"), e.get("a"))) or {"sid": e.get("s"), "agent": e.get("a")},
                                    e.get("t")))
    if partial:
        warn += ["COMMIT GATE (M.ORCH-T1530) WARNING: staged files that still have unstaged hunks another agent touched.",
                 "Check the staged hunks are only yours and that they compile on their own (a mis-splice breaks main):"]
        warn += lines_of(partial)
    if warn:
        sys.stderr.write("\n".join(warn) + "\n")

    try:
        t = now()
        append_events(root, [{"k": "clear", "p": p, "s": sid, "a": agent, "t": ticket, "at": t} for p in committed])
    except Exception:
        pass
    return 0

def main():
    if len(sys.argv) > 2 and sys.argv[1] == "git-commit-msg":
        try:
            return commit_msg(sys.argv[2])
        except Exception:
            return 0   # fail open
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        data = json.loads(raw) if raw.strip() else {}
        provider = (sys.argv[1] if len(sys.argv) > 1 else "claude").lower()
        event_arg = sys.argv[2] if len(sys.argv) > 2 else None
        out = handle(data, provider, event_arg) if isinstance(data, dict) else None
    except Exception:
        return 0   # fail open
    if out:
        try:
            sys.stdout.write(json.dumps(out))
            sys.stdout.flush()
        except Exception:
            pass
    return 0

if __name__ == "__main__":
    sys.exit(main())
