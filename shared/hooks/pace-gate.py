#!/usr/bin/env python3
# MindAttic.Orchestrator's pace gate (written by the orchestrator; edits are overwritten).
# Holds each tool call for rl-status.json's pace_delay_seconds so agents slow down instead of
# hitting the usage limit. Re-reads the file while waiting: a lifted hold ends at once.
import json, os, sys, time
from datetime import datetime
from pathlib import Path

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

STALE =180
# MINDATTIC_MAX_HOLD shortens the longest hold so tests can run the held-then-refused paths in seconds.
try:
    MAX_HOLD = float(os.environ.get("MINDATTIC_MAX_HOLD") or 300)
except ValueError:
    MAX_HOLD = 300

def status():
    try:
        s = rl_status()
        if s.get("source") != "MindAttic.Orchestrator" or before_switch(s["timestamp"], True):
            return {}
        at = datetime.fromisoformat(s["timestamp"].replace("Z", ""))
        return lapsed(s) if (datetime.utcnow() - at).total_seconds() <= STALE else {}
    except Exception:
        return {}

def delay():
    # The pace's hold. While the daemon is stalled or down (its file stale), the last pace it wrote still holds
    # until the window it was worked out for resets (M.ORCH-T205: the daemon stalled for 4 minutes under heavy
    # load at 88% and every call ran unheld until 96%); past that reset nothing is known, so nothing is held.
    try:
        s = status()
        if s:
            return float(s.get("pace_delay_seconds", 0))
        s = rl_status()
        if s.get("source") != "MindAttic.Orchestrator" or not s.get("window_reset") or before_switch(s.get("timestamp"), True):
            return 0
        until = datetime.fromisoformat(str(s["window_reset"]).replace("Z", "+00:00")).timestamp()
        return float(s.get("pace_delay_seconds", 0)) if time.time() < until else 0
    except Exception:
        return 0

# Every hold of a second or more and every refusal at the stop goes to the pace ledger's event log (M.ORCH-T166),
# so a window that went over can be traced to the calls around it.
def gate_log(decision, held):
    try:
        log_gate_event(datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), decision, round(held, 1), tool, status().get("percent_used"), account_tag())
    except Exception:
        pass

try:
    # UTF-8 as Claude Code writes it, not the ANSI code page Python reads a pipe in on Windows (M.ORCH-T392).
    data = json.loads(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
except Exception:
    data = {}
tool = data.get("tool_name")

# A repo's window works only that repo (M.ORCH-T95): its own folder and worktrees, and its own tickets. Another
# repo's files and tickets belong to that repo's window, /allocate, or the General (workspace-root) session.
import fnmatch, os, re, sqlite3
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

def ticket_repo(ticket_id):
    try:
        db = tickets_db()
        row = db.execute("SELECT repo FROM tickets WHERE id = ? COLLATE NOCASE", (ticket_id,)).fetchone()
        db.close()
        return row[0] if row else None
    except Exception:
        return None

def refuse(why):
    print(json.dumps(dict(hookSpecificOutput=dict(hookEventName="PreToolUse", permissionDecision="deny", permissionDecisionReason=why))))
    raise SystemExit(0)

# The orchestrator's last-resort cool-off (M.ORCH-T786): a subagent it aborted to pull its login's 5-hour trend back under
# the pace line has every tool call refused from here on, so it stops between calls (never mid-write or mid-commit, as a
# call already running finishes) and its uncommitted work stays as it is. Its claim is already released
# and its ticket put first in the queue by the orchestrator.
if data.get("agent_id"):
    aborted = abort = None
    try:
        aborted = SUBAGENT_MARKS / "subagent-aborts" / re.sub(r"[^A-Za-z0-9_.-]", "_", str(data["agent_id"]))
        abort = json.loads(aborted.read_text(encoding="utf-8")) if aborted.exists() else None
    except Exception:
        try:
            abort = {} if aborted is not None and aborted.exists() else None  # a mark caught mid-write still aborts
        except Exception:
            abort = None
    if abort is not None:
        ticket = (abort.get("ticket") if isinstance(abort, dict) else None) or "your ticket"
        why = (abort.get("why") if isinstance(abort, dict) else None) or "this login's 5-hour window is on course past its pace line"
        refuse(f"ABORTED by the orchestrator to cool off this login: {why}. Stop now: make no more tool calls (each one is refused) "
               f"and end your turn with a short report saying you were aborted, what you finished, and what's left uncommitted. "
               f"Don't commit, push, close or release anything: your uncommitted work is kept as it is, and "
               f"the orchestrator already released {ticket}'s claim and put it first in the queue for the next round, so the "
               f"CLI that started you shouldn't restart it now.")

# /crossrepo and /allocate called through the Skill tool (M.ORCH-T435): the model starts them when the user asks in words
# ("use crossrepo for X"), and the guard below refused every edit for want of the mark a typed command writes. They're
# the user's choice, never the model's: recorded exactly as typed only when the user's latest prompt asked for it (the
# context gate notes that), refused otherwise. Switching off is always safe, so it always goes through.
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
if tool == "Skill":
    called = str((data.get("tool_input") or {}).get("skill") or "").strip().lstrip("/").lower().split(":")[-1]
    if called in ("crossrepo", "allocate"):
        given = str((data.get("tool_input") or {}).get("args") or "").strip()
        off = bool(re.match(r"off\b", given, re.I)) or (called == "crossrepo" and not given)
        if not off and called not in (session_state(data.get("session_id")).get("asked") or []):
            # The turn now ends asking you to type it: the context gate's Stop marks the CLI blocked on you (M.ORCH-T790).
            try:
                sid = re.sub(r"[^A-Za-z0-9_.-]", "_", str(data.get("session_id") or ""))
                if sid:
                    marked = dict(session_state(sid), needs_typed="/" + called)
                    write_exported_mark(sid, SESSION_MARKS / (sid + ".state.json"), marked, table="session_states", key="session_id")
            except Exception:
                pass
            refuse(f"/{called} is the user's to switch on, never yours: their latest prompt didn't ask for it, so nothing was "
                   f"recorded. Ask the user to type " + ("/crossrepo <repos>" if called == "crossrepo" else "/allocate") + " themselves.")
        pid = os.environ.get("MINDATTIC_CLI_PID") or cli_pid()
        why = set_allocate(pid, given, data.get("cwd") or "") if called == "allocate" else set_crossrepo(pid, given)
        if why:
            refuse(why)
        if called == "allocate" and ALLOCATE_NOTE[0]:
            # -target (M.ORCH-T599): the model's reply names the CLIs it changed.
            told = dict(hookEventName="PreToolUse", additionalContext=ALLOCATE_NOTE[0])
            print(json.dumps(dict(hookSpecificOutput=told)))
        raise SystemExit(0)

# The one exception is explicit, per CLI and until it closes: /crossrepo <A,B|all> (the context gate writes the mark).
def allowed_here():
    # /crossrepo's repos, and the repos /allocate is working in this CLI ("*" for all): its subagents edit and close there.
    pid = os.environ.get("MINDATTIC_CLI_PID") or cli_pid()
    found = set()
    for kind in ("crossrepo", "allocate"):
        try:
            found |= {r.strip().lower() for r in (cli_mark(kind, pid) or "").split(",") if r.strip()}
        except Exception:
            pass
        # M.ORCH-T1258: the /crossrepo list bounds the work. /allocate -repo=Unity.* widened it to every Unity repo, so
        # when /crossrepo named repos, only those are excepted; /allocate's own list adds nothing beyond them.
        if kind == "crossrepo" and found:
            return {"all" if r == "*" else r for r in found}
    return {"all" if r == "*" else r for r in found}

here = repo_of(data.get("cwd") or "")
if here:
    args = data.get("tool_input") or {}
    excepted = None
    def other(r):
        global excepted
        if not r or same_repo(r, here):
            return False
        if excepted is None:
            excepted = allowed_here()
        if "all" in excepted:
            return False
        # A name may be a wildcard (/allocate -repo=GTFO.*): every repo it matches is excepted, by either
        # name it's known by (a rename doesn't drop it from what was already named, M.ORCH-T565).
        names = {r.lower(), canonical_repo(r).lower()}
        return not any(fnmatch.fnmatchcase(n, p) for n in names for p in excepted)
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        target = args.get("file_path") or args.get("notebook_path") or ""
        if other(repo_of(target)):
            refuse(f"This window is for {here}; {target} belongs to {repo_of(target)}. Work {repo_of(target)} in its own window "
                   f"(or /allocate, or the General session), or file a ticket for it: tickets ticket new --repo {repo_of(target)} ...")
    if tool in ("Bash", "PowerShell"):
        command = str(args.get("command") or "")
        # Only a segment that IS a ticket command (tickets, or the legacy workflow shim) counts: the words inside a message or a string don't.
        for segment in re.split(r"[;\n|]|&&", command):
            # Any case, as Windows runs it and the ticket lookup matches it (M.ORCH-T468).
            called = re.match(r"\s*(?:&\s*)?['\"]?(?:tickets|workflow)(?:\.exe)?['\"]?\s+ticket\s+(close|correct)\b\s*(.*)", segment, re.I)
            if not called:
                continue  # filing a new ticket in another repo is how work is handed to it, so `new` is never refused
            action = called.group(2)
            named = re.search(r"--repo[\s=]+['\"]?([^\s'\"]+)", action)
            owners = [named.group(1)] if named else []
            # The ticket a close/correct acts on is its first argument; IDs in --summary or --ref are just text.
            first = re.match(r"['\"]?((?:[A-Z]\.)?[A-Z][A-Z0-9]*-T\d+)\b", action.strip(), re.I)
            owners += [ticket_repo(first.group(1))] if first else []
            for owner in owners:
                if other(owner):
                    refuse(f"This window is for {here}; that ticket belongs to {owner}. Only {here}'s tickets are worked here: "
                           f"leave {owner}'s to its own window, /allocate or the General session.")
        # Only a write that `git -C` itself runs in the other repo: reading it is fine, and a word in a message, a file
        # name or this repo's own git on the same line isn't that repo's change.
        for segment in re.split(r"[;\n|]|&&", command):
            for target in re.findall(r"\bgit\s+-C\s+['\"]?([^'\"\s]+)['\"]?(?:\s+-c\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+"
                                 r"(?:commit|push|pull|add|rm|mv|reset|restore|checkout|switch|merge|rebase|cherry-pick|revert|am|apply|clean|tag|branch|worktree|stash(?!\s+(?:list|show)\b))\b", segment):
                if other(repo_of(target)):
                    refuse(f"This window is for {here}; git changes in {repo_of(target)} belong to that repo's window.")

# Every repo lands on main (the master repos were renamed 2026-10-16): a push to master would only recreate a stray
# branch on GitHub that triggers nothing (found live: an agent told to push main to a master repo made a stray main).
if tool in ("Bash", "PowerShell"):
    for segment in re.split(r"[;\n|]|&&", str((data.get("tool_input") or {}).get("command") or "")):
        # push as git's own subcommand (after its global options), never the word inside a commit message
        if re.match(r"\s*(?:&\s*)?['\"]?git(?:\.exe)?['\"]?(?:\s+(?:-C\s+(?:\"[^\"]*\"|'[^']*'|\S+)|-c\s+\S+|--?[\w-]+(?:=\S+)?))*\s+push\b", segment) and re.search(r"(?:\s|:|\+|refs/heads/|['\"])master(?![\w./-])", segment) and not re.search(r"--delete\b", segment):
            refuse("Every MindAttic repo's main line is main now (renamed from master 2026-10-16); pushing master would "
                   "recreate a stray branch. Push main instead: git push origin HEAD:main.")

# A search of a whole drive never finishes in time and, orphaned when its agent stops, leaks handles until
# Windows can't draw (found live: two `find /` held 660k handles and froze the desktop). Refuse it up front.
import re
cmd = str((data.get("tool_input") or {}).get("command") or "")
ROOT_SEARCH = (r"(?:^|[;&|(\n])\s*(?:\"[^\"]*[\\/]|'[^']*[\\/]|[^\s\"';&|]*[\\/])?(find|fd|rg|grep|ls|dir|Get-ChildItem|gci|where)(?:\.exe)?[\"']?"
               r"(?=\s)[^|;&\n]*?\s[\"']?(/|/[a-zA-Z]|[A-Za-z]:[\\/]?|~|\$HOME|\$env:USERPROFILE)[\"']?(?=\s|$|[;&|)])")
# A heredoc's or here-string's body is data (a script, a file's text), not commands: `open(DIR / x)` in a Python
# heredoc read as `dir /` (M.ORCH-T168). Each line of what's left starts a command, so `cd x` then `find /` is caught.
def commands_only(c):
    c = re.sub(r"<<-?\s*([\"']?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?=\n|$)", "", c, flags=re.S)
    c = re.sub(r"@([\"'])\s*\n.*?\n\1@", "", c, flags=re.S)
    # What cmd /c or powershell -c runs is a command too: `cmd /c dir C:\ /s` walks the drive all the same (M.ORCH-T362).
    return re.sub(r"\b(?:cmd(?:\.exe)?\s+/[ck]|(?:powershell|pwsh)(?:\.exe)?(?:\s+-(?!c\b|command\b)\w+(?:\s+(?!-)\S+)?)*\s+-c(?:ommand)?)\s+[\"']?",
                  "\n", c, flags=re.I)
def arguments(segment):
    return [t[1:-1] if len(t) > 1 and t[0] == t[-1] and t[0] in "\"'" else t for t in re.findall(r"\"[^\"]*\"|'[^']*'|\S+", segment)][1:]
def root_search(c, powershell):
    c = commands_only(c)
    # Each command naming a root is judged on its own: `ls && find / ...` is a search, `find . ; ls /` isn't.
    for m in re.finditer(ROOT_SEARCH, c, re.I):
        name = m.group(1).lower()
        segment = re.split(r"[;&|\n]", c[m.start(1):], maxsplit=1)[0]
        if name == "where":
            # where /r <dir> walks <dir>: only a root after /r is a whole-drive search (M.ORCH-T362).
            if re.search(r"\s/r\s+[\"']?(?:[A-Za-z]:[\\/]?|/|~)[\"']?(?=\s|$)", segment, re.I):
                return True
            continue
        # Only a path argument naming a root counts, never a switch or a search pattern (M.ORCH-T364): in PowerShell
        # find is find.exe (/i is its case switch, and it reads only the files it's given), cmd's dir takes /s and
        # /b, and grep's, rg's and fd's first argument is what they look for.
        if powershell and name == "find":
            continue
        args = arguments(segment)
        paths = [a for a in args if not a.startswith("-") and not (name == "dir" and re.fullmatch(r"/[A-Za-z?]", a))]
        if name in ("grep", "rg", "fd") and not any(a in ("-e", "-f", "--regexp", "--file") or a.startswith(("--regexp=", "--file=")) for a in args):
            paths = paths[1:]
        unix = not powershell and name in ("find", "fd", "rg", "grep", "ls")
        def is_root(a):
            return bool(re.fullmatch(r"/|[A-Za-z]:[\\/]?|~|\$HOME|\$env:USERPROFILE", a, re.I) or (unix and re.fullmatch(r"/[A-Za-z]", a)))
        # `dir /s C:\x.exe` looks for x.exe in every folder of the drive.
        def drive_pattern(a):
            return name == "dir" and bool(re.fullmatch(r"[A-Za-z]:[\\/][^\\/]*[.*?][^\\/]*", a))
        if not any(is_root(a) or drive_pattern(a) for a in paths):
            continue
        if name not in ("ls", "dir", "get-childitem", "gci"):
            return True
        # Listing a root is harmless; only a recursive listing walks the whole drive. PowerShell's parameters ignore
        # case (-recurse, -r), but bash's `ls -r` only reverses the order.
        if powershell or name in ("get-childitem", "gci"):
            if re.search(r"\s-r(?:e(?:c(?:u(?:r(?:s(?:e)?)?)?)?)?)?\b|\s/s\b", segment, re.I):
                return True
        elif re.search(r"(\s-\w*R\w*\b|\s/s\b)", segment):
            return True
    return False
if tool in ("Bash", "PowerShell") and root_search(cmd, tool == "PowerShell"):
    print(json.dumps(dict(hookSpecificOutput=dict(hookEventName="PreToolUse", permissionDecision="deny",
        permissionDecisionReason="Searching a whole drive or the filesystem root is blocked: it never finishes and leaks handles until "
        "Windows freezes. Search the specific folder instead (a repo under D:\\Projects\\MindAttic, or a known install folder), "
        "or use the Glob/Grep tools with a path."))))
    raise SystemExit(0)

# The quicksave of a CLI /allocate off is winding down always goes through, at the window's stop too: winding down is often
# for the account that's run out, and the CLI's work would be lost to the switch (M.ORCH-T572).
if tool in ("Bash", "PowerShell") and QUICKSAVE.search(cmd) and winding_down(os.environ.get("MINDATTIC_CLI_PID") or cli_pid()):
    gate_log("exempt", 0)
    raise SystemExit(0)

# A CLI billed to an API key, a gateway or a cloud provider spends none of the subscription's windows: no stop, latch,
# pace hold or subagent allowance is its to obey.
if session_auth(data.get("cwd")) != "subscription":
    raise SystemExit(0)

# Never past the limit, whatever else is set (/pacing off included): at the window's target a call is held as long
# as a hook may wait, in case the reset or a lower count lifts it, then refused rather than let through.
start = time.monotonic()
slot = None  # the subagent slot this call holds: its subagent_slots row id, or its file (M.ORCH-T527)
def touch_slot():
    # Still held, not abandoned: other gates drop a slot past its life.
    try:
        if isinstance(slot, int):
            slot_sql(None, "UPDATE subagent_slots SET touched_at = ? WHERE id = ?", (time.time(), slot))
        elif slot is not None:
            os.utime(slot)
    except Exception:
        pass
def release():
    # A subagent slot whose call never runs is given back at once, not left to expire.
    try:
        if isinstance(slot, int):
            slot_sql(None, "DELETE FROM subagent_slots WHERE id = ?", (slot,))
        elif slot is not None:
            slot.unlink()
    except Exception:
        pass
# The orchestrator's stop, or Claude's own percent at the line: a dead daemon can't switch the stop off (M.ORCH-T167),
# and neither a stalled one nor an idle session's lower report lifts a stop already seen (latched, M.ORCH-T196).
def stop_note():
    s = status()
    note = orchestrator_stop(s)
    if note:
        return note
    own = claude_stop()
    return claude_stop_note(own, running=bool(s)) if own else None
def hold_at_stop():
    # Checked before every other hold and through each of them, so a call held for the pace delay or a subagent slot
    # when the stop comes on is held on and refused, never let through once its wait ends (M.ORCH-T196: in the
    # minutes after the 99% stop, calls already held each went through when their own wait ran out).
    if stop_note() is None:
        return
    while time.monotonic() - start < MAX_HOLD and stop_note() is not None:
        touch_slot()  # still held: other gates drop a slot past its life, and the call would go through uncounted
        time.sleep(5)
    note = stop_note()
    if note is not None:
        release()
        gate_log("refused", time.monotonic() - start)
        refuse(note)
hold_at_stop()

# Exempt commands (M.ORCH-T198): a turn typed as one of them (the context gate marks its session state) and a Skill
# call naming one skip every pacing gate below: no pace delay, no subagent hold. Never the stop, held above first
# (bughunt 2026-10-27: an exempt /allocate turn, its subagents sharing the session, ran a ticket round past the stop).
# Each is logged as "exempt" and the daemon is told to recount, so the spend still lands in the pace at once.
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
def exempt_turn():
    # The session's state as the context gate saved it: its session_states row or its exported file, whichever was
    # written later (M.ORCH-T543: the file alone stayed exempt when a Stop's write of it failed).
    return bool(session_state(data.get("session_id")).get("exempt"))
if exempt_turn() or (tool == "Skill" and exempt_skill((data.get("tool_input") or {}).get("skill"))):
    gate_log("exempt", 0)
    # Said on the daemon's inbox at once (M.ORCH-T872); the file stays for a daemon from before it.
    publish_status("poke", {"source": "pace-gate", "why": "exempt"})
    try:
        (Path.home() / ".claude" / "session-context" / "refresh.now").write_text(datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    except Exception:
        pass
    raise SystemExit(0)

# /pacing off exempts one CLI (its process, so subagents and /clear included) from holds until it closes or /pacing on (M.ORCH-T483).
MARKS = Path.home() / ".claude" / "session-context"
if MARKS.exists() and any(MARKS.glob("unthrottled-*")):
    pid = os.environ.get("MINDATTIC_CLI_PID") or cli_pid()
    if pid is not None and (MARKS / ("unthrottled-" + str(pid))).exists():
        raise SystemExit(0)

# A new subagent waits while the allowance the pace works out is used up (all CLIs together); the wait counts toward
# the same MAX_HOLD, and past it the call is refused, never let through over the allowance (M.ORCH-T201: letting it
# start anyway put 7 subagents on an allowance of 1, and a longer hold can't slow them: the cap stays under the
# 5-minute prompt-cache TTL subagents use).
# Agent calls sent in one message run this together, before any SubagentStart has marked one, so the check
# and the slot it lets through are one step under a lock (M.ORCH-T197: ~20 got past an allowance of 1-2): one write
# transaction on the orchestrator's database (M.ORCH-T527), or, while that's held or not there, the old .lock file
# with the slot kept as a file. Every gate counts both the rows and the files, so neither kind is missed.
# The slot counts until the context gate's SubagentStart turns it into the subagent's mark, or it expires.
if tool in ("Agent", "Task"):
    # Each Claude login's subagents are its own (M.ORCH-T559): a CLI on its own login counts, slots and waits in its
    # account's folder (SUBAGENT_MARKS), held to that account's allowance.
    SUB = SUBAGENT_MARKS / "subagents"
    SLOTS = SUBAGENT_MARKS / "subagent-slots"
    LOCK = SUBAGENT_MARKS / "subagent-slots.lock"
    TX = None  # the deciding transaction, while one is open
    def mark_ns(m):
        # A mark whose subagent stops (or the daemon prunes) while it's counted is gone, not a reason to stop
        # counting: then the allowance didn't hold at all (M.ORCH-T366).
        try:
            return m.stat().st_mtime_ns
        except OSError:
            return -1
    def running(s):
        # The daemon's count leaves out marks whose stop never came; only marks newer than its count are added to it.
        marks = list(SUB.iterdir()) if SUB.exists() else []
        if s.get("subagents_running") is None:
            return len(marks)
        # Newer than the newest mark the count saw, to the file time's own precision (M.ORCH-T320: against the
        # whole-second timestamp, up to a minute old, marks it had counted were counted again); an older daemon
        # writes only the timestamp.
        if s.get("subagents_seen_through_ns") is not None:
            seen = int(s["subagents_seen_through_ns"])
            return int(s["subagents_running"]) + sum(1 for m in marks if mark_ns(m) > seen)
        at = datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00")).timestamp()
        return int(s["subagents_running"]) + sum(1 for m in marks if mark_ns(m) / 1e9 > at)
    def held_slots():
        # Slots let through but not started yet, as the CLI each is for: the table's rows and the files a gate kept
        # while the database was held; one whose start never came (the call was refused) is dropped.
        held = []
        for f in (SLOTS.iterdir() if SLOTS.exists() else []):
            try:
                if time.time() - f.stat().st_mtime > 120:
                    f.unlink()
                else:
                    held.append(f.name.split("-")[0])
            except Exception:
                pass
        cutoff = time.time() - 120
        if TX is not None:
            TX.execute("DELETE FROM subagent_slots WHERE touched_at < ?", (cutoff,))
            held += [str(r[0]) for r in TX.execute("SELECT cli FROM subagent_slots")]
        elif not PROFILE_DIR:
            held += [str(r[0]) for r in orch_rows("SELECT cli FROM subagent_slots WHERE touched_at >= ?", (cutoff,), timeout=1) or []]
        return held
    def slots():
        return len(held_slots())
    # Each CLI's fair share of the allowance (M.ORCH-T495: one repo's /allocate took all 8 places at once while the
    # other CLIs got none). The rule is SubagentShare's: every active CLI (this one, each with subagents running or
    # starting, each with an Agent call waiting here) has allowance / active (at least one), and may go past it only into
    # places no other CLI is waiting for. A waiting call marks its CLI as wanting, so the next place that frees goes to
    # a CLI under its share, never back to the one over it; a CLI that wants nothing more lends what it isn't using.
    ME = str(os.environ.get("MINDATTIC_CLI_PID") or cli_pid() or 0)
    WANTS = SUBAGENT_MARKS / "subagent-wants"
    WANT = WANTS / (ME + "-" + str(os.getpid()))
    def want(on):
        # A row of subagent_wants when the database takes it, else the old file; every gate reads both.
        try:
            if on:
                if slot_sql(TX, "INSERT OR REPLACE INTO subagent_wants (cli, gate_pid, touched_at) VALUES (?, ?, ?)", (ME, os.getpid(), time.time())):
                    return
                WANTS.mkdir(parents=True, exist_ok=True)
                WANT.write_text("")
            else:
                slot_sql(TX, "DELETE FROM subagent_wants WHERE cli = ? AND gate_pid = ?", (ME, os.getpid()))
                if WANT.exists():
                    WANT.unlink()
        except Exception:
            pass
    def wanting():
        pids = set()
        for f in (WANTS.iterdir() if WANTS.exists() else []):
            try:
                if time.time() - f.stat().st_mtime > 20:
                    f.unlink()
                else:
                    pids.add(f.name.split("-")[0])
            except Exception:
                pass
        cutoff = time.time() - 20
        if TX is not None:
            TX.execute("DELETE FROM subagent_wants WHERE touched_at < ?", (cutoff,))
            pids.update(str(r[0]) for r in TX.execute("SELECT cli FROM subagent_wants"))
        elif not PROFILE_DIR:
            pids.update(str(r[0]) for r in orch_rows("SELECT cli FROM subagent_wants WHERE touched_at >= ?", (cutoff,), timeout=1) or [])
        pids.discard(ME)
        return pids
    def by_cli(s):
        # Running or starting, by CLI: the daemon's count of each (marks newer than it, each naming its CLI, are added)
        # and the slots let through (named for their CLI). Without the daemon's count by CLI, every mark is counted.
        counts = {}
        seen = s.get("subagents_by_cli") if s.get("subagents_running") is not None else None
        if isinstance(seen, dict):
            for k, v in seen.items():
                counts[str(k)] = counts.get(str(k), 0) + int(v)
            if s.get("subagents_seen_through_ns") is not None:
                after = int(s["subagents_seen_through_ns"])
                newer = lambda m: mark_ns(m) > after
            else:
                after = datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00")).timestamp()
                newer = lambda m: mark_ns(m) / 1e9 > after
        else:
            newer = lambda m: True
        for m in (list(SUB.iterdir()) if SUB.exists() else []):
            try:
                if newer(m):
                    pid = m.read_text().strip()
                    counts[pid] = counts.get(pid, 0) + 1
            except Exception:
                pass
        for pid in held_slots():
            counts[pid] = counts.get(pid, 0) + 1
        return counts
    def fair_limit(s, allowed, free):
        # (running or starting here, how many this CLI may have, active CLIs, whether it's warming up, whether it's
        # another CLI's turn)
        counts = by_cli(s)
        wants = wanting()
        active = {p for p, n in counts.items() if n > 0 and p} | wants | {ME}
        share = max(1, int(allowed) // max(1, len(active)))
        held = sum(n for p, n in counts.items() if p != ME and p not in wants) + sum(max(counts.get(p, 0), share) for p in wants)
        limit = max(share, int(allowed) - held)
        # Warming up (M.ORCH-T558): a CLI's /allocate has at most one subagent the minute it turned on and one more
        # each minute after, so CLIs opened just after it claim theirs before it fills every place. A CLI without
        # /allocate on (subagents started by hand) has no warm-up.
        TX_SINCE[0] = TX
        try:
            since = cli_mark_since("allocate")
        finally:
            TX_SINCE[0] = None
        def warm(p):
            at = since.get(p)
            return 1 + int(max(0.0, time.time() - at) // 60) if at is not None else None
        w = warm(ME)
        warming = w is not None and w < limit
        if warming:
            limit = w
        # A freed place goes to the waiting CLI furthest under its share (its warm-up counted), not whichever asks
        # first: this one waits while the CLIs ahead of it would take every free place.
        def under(p):
            cap = share if warm(p) is None else min(share, warm(p))
            return cap - counts.get(p, 0)
        mine_under = under(ME)
        ahead = [p for p in wants if under(p) > 0 and (under(p) > mine_under or (under(p) == mine_under and str(p) < str(ME)))]
        return counts.get(ME, 0), limit, len(active), warming, len(ahead) >= free
    def locked():
        # One pace gate at a time decides; a lock left by a killed gate is broken after a few seconds.
        SUBAGENT_MARKS.mkdir(parents=True, exist_ok=True)
        give_up = time.monotonic() + max(0.05, min(15, MAX_HOLD - (time.monotonic() - start)))  # never past MAX_HOLD
        while time.monotonic() < give_up:
            try:
                os.close(os.open(str(LOCK), os.O_CREAT | os.O_EXCL | os.O_WRONLY))
                return True
            except FileExistsError:
                try:
                    if time.time() - LOCK.stat().st_mtime > 10:
                        LOCK.unlink()
                except Exception:
                    pass
            except Exception:
                return False
            time.sleep(0.05)
        return False
    def unlock():
        try:
            LOCK.unlink()
        except Exception:
            pass
    def take_file():
        try:
            SLOTS.mkdir(parents=True, exist_ok=True)
            path = SLOTS / (ME + "-" + str(time.time_ns()) + "-" + str(os.getpid()))
            path.write_text("")
            return path
        except Exception:
            return None
    def take():
        if TX is not None:
            try:
                return TX.execute("INSERT INTO subagent_slots (cli, gate_pid, taken_ns, touched_at) VALUES (?, ?, ?, ?)",
                                  (ME, os.getpid(), time.time_ns(), time.time())).lastrowid
            except Exception:
                pass
        return take_file()
    mine = limit = clis = None
    warming = turn = False
    busy = allowed = 0
    while True:
        TX = slot_db()
        has_lock = TX is None and locked()
        # Neither the db nor the lock: counting and taking a slot now would race the other gates (M.ORCH-T197), so
        # this round only waits and tries again, until MAX_HOLD refuses it.
        blind = TX is None and not has_lock
        try:
            s = status()
            allowed = s.get("subagent_allowance")
            try:
                busy = running(s) + slots() if allowed is not None else 0
                go = allowed is None or (not blind and busy < allowed)
                limit = None
                warming = turn = False
                if go:
                    mine, limit, clis, warming, turn = fair_limit(s, allowed, int(allowed) - busy)
                    go = mine < limit and not turn
            except Exception:
                go = allowed is None or not blind
            if go:
                slot = take()
                want(False)
                break
            want(True)  # waiting: the next place that frees is kept for a CLI under its share
        finally:
            if TX is not None:
                tx, TX = TX, None
                if not slot_done(tx) and isinstance(slot, int):
                    slot = take_file()  # its row didn't go in: the place is kept as a file instead
            if has_lock:
                unlock()
        if time.monotonic() - start >= MAX_HOLD:
            want(False)
            gate_log("refused", time.monotonic() - start)
            if limit is not None and warming and mine >= limit:
                refuse("This CLI's /allocate is warming up (" + str(mine) + " running or starting, at most " + str(limit) +
                       " yet: one more each minute since it turned on, so CLIs opened just after it get theirs too), so this "
                       "subagent wasn't started. Don't start it now: work on in this turn, or end it, and try again in a minute.")
            if limit is not None and turn and mine < limit:
                refuse("Another CLI further under its fair share of the subagent allowance is waiting for the free places (" +
                       str(mine) + " running or starting here, " + str(allowed) + " allowed across the " + str(clis) + " CLIs that use "
                       "or want them), so this subagent wasn't started. Don't start it now: work on in this turn, or end it, and "
                       "try again in a minute.")
            if limit is not None:
                refuse("This CLI has its fair share of the subagent allowance (" + str(mine) + " running or starting, " + str(limit) +
                       " its share of the " + str(allowed) + " allowed across the " + str(clis) + " CLIs that use or want them), so "
                       "this subagent wasn't started: the free places are kept for the other CLIs. Don't start it now: work on in this "
                       "turn, or end it, and try again after one of this CLI's subagents finishes.")
            refuse("The subagent allowance is full (" + str(busy) + " running or starting, " + str(allowed) + " allowed across every CLI), "
                   "so this subagent wasn't started. Don't start it now: work on in this turn, or end it, and try again after one "
                   "of the running subagents finishes and a slot frees.")
        time.sleep(5)
        try:
            hold_at_stop()
        except BaseException:
            want(False)
            raise
try:
    while True:
        hold_at_stop()
        waited = time.monotonic() - start
        left = min(delay(), MAX_HOLD) - waited
        if left <= 0:
            break
        touch_slot()  # still held, not abandoned: other gates drop a slot past its life
        time.sleep(min(left, 5))
    hold_at_stop()  # the last word before the call runs
except BaseException:
    release()  # killed, failed or refused while held: the call doesn't run
    raise
touch_slot()  # its life starts when the call is let through, not when the slot was taken
if time.monotonic() - start >= 1:
    gate_log("held", time.monotonic() - start)