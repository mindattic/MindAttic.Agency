#!/usr/bin/env python3
# MindAttic test gate (MAT-T121): GOLDEN RULE enforcement - verification is build-only; test suites and soaks run
# only when the user's own latest prompt asked for them (/test, /tests, /run tests, "run the tests").
#
# Wired by install-hooks.ps1 for every CLI (Claude, Codex, Kimi, agy) on three events:
#   UserPromptSubmit  records, per session, whether the prompt the user just typed asks for tests (each new prompt
#                     replaces the last, so permission lasts exactly one user turn).
#   SubagentStart     snapshots the parent turn's permission for that subagent (by agent_id), so a subagent started
#                     by a /test turn keeps it even after the user types something else, and one started by any
#                     other turn never gains it.
#   PreToolUse        refuses a shell call whose command runs a test runner or soak (test-gate-patterns.json, plus
#                     the repo's own .agent/test-gate-patterns.json) unless that permission is on. A subagent's tool
#                     call carries its parent's session_id, so it reads the parent's permission when it has no
#                     snapshot of its own.
#
# Fails open: any error in this script allows the call (exit 0, no output). It must never brick a CLI.
# Usage: python test-gate.py [provider [event]]   (hook JSON on stdin; provider claude|codex|kimi|agy picks the deny
# shape, agy needs the event named since its payload doesn't carry one)
import json, os, re, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PATTERNS_FILE = HERE / "test-gate-patterns.json"
STATE_DIR = Path(os.environ.get("MINDATTIC_TEST_GATE_DIR") or (Path.home() / ".claude" / "session-context" / "test-gate"))
MAX_AGE = 12 * 3600          # a permission older than this is stale even if no new prompt replaced it
KEEP_FILES = 3 * 24 * 3600   # state files untouched this long are swept

REFUSAL = ("GOLDEN RULE (MAT-T121): test suites and soaks run only when the user asks. This command runs {name}, "
           "and the user's latest prompt didn't ask for tests (/test, /tests, /run tests, or \"run the tests\"). "
           "Verify by building only (dotnet build, npm run build, cargo build, tsc, ...), commit, and move on to the "
           "next piece of work; the user runs the suite once, last, with /test. Owner: \"you can't sit around idle "
           "for half an hour to run entire test suites... this needs to be a GOLDEN RULE that everything follows.\"")

# ---- what the user asked for -------------------------------------------------------------------------------------

NEGATION = re.compile(r"\b(?:don'?t|do\s+not|never|no\s+need\s+to|not|without|skip|stop|avoid|instead\s+of)\b[\w\s,'-]{0,24}$", re.I)
ASK_PHRASES = [
    # "run tests", "run the tests", "run all the tests", "run the unit tests", "run the full test suite", "rerun tests"
    re.compile(r"\b(?:re-?)?run\s+(?:the\s+|all\s+(?:of\s+)?(?:the\s+)?|my\s+|our\s+)?(?:full\s+|whole\s+|entire\s+|unit\s+|core\s+)*"
               r"(?:tests?|test\s+suites?|suites?)\b", re.I),
    # "run the soak", "run a balance soak", "run the balance sim"
    re.compile(r"\b(?:re-?)?run\s+(?:the\s+|a\s+|an\s+)?(?:\w+\s+)?(?:soaks?|balance\s+(?:runs?|sims?|simulations?|soaks?|reports?))\b", re.I),
]

def asks_for_tests(prompt):
    """Whether a typed prompt explicitly asks for tests: a /test or /tests (or /run tests) command, or a plain
    "run (the) tests" request that isn't negated ("don't run the tests"). Quoted and backticked text is ignored, so a
    prompt quoting the rule ("`/run tests` runs the suite") doesn't grant it."""
    text = str(prompt or "")
    head = text.lstrip()
    # The command itself, typed or as Claude Code expands it.
    if re.match(r"/(?:run\s+)?tests?(?:\s|$)", head, re.I):
        return True
    if re.search(r"<command-name>\s*/?(?:tests?)\s*</command-name>", text, re.I):
        return True
    if re.search(r"<command-name>\s*/?run\s*</command-name>.*?<command-args>\s*tests?\s*</command-args>", text, re.I | re.S):
        return True
    # A spoken request, outside quotes and code.
    plain = re.sub(r"```.*?```|`[^`\n]*`|\"[^\"\n]*\"|<[^>\n]+>", " ", text, flags=re.S)
    for rx in ASK_PHRASES:
        for m in rx.finditer(plain):
            if not NEGATION.search(plain[max(0, m.start() - 40):m.start()]):
                return True
    return False

# ---- what a command runs -------------------------------------------------------------------------------------------

def load_patterns(cwd):
    out = []
    files = [PATTERNS_FILE]
    root = repo_root(cwd)
    if root:
        files.append(root / ".agent" / "test-gate-patterns.json")
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        for p in data.get("patterns") or []:
            try:
                out.append((p.get("name") or p["regex"], re.compile(p["regex"], re.I), p.get("at", "command")))
            except Exception:
                continue  # one bad pattern never disables the rest
    return out

def repo_root(cwd):
    try:
        p = Path(cwd).resolve() if cwd else None
        while p and p != p.parent:
            if (p / ".git").exists():
                return p
            p = p.parent
    except Exception:
        pass
    return None

WRAPPERS = [
    r"[\"'`(){}]+",                                         # quotes, subshells, script blocks
    r"&\s*",                                                # PowerShell call operator
    r"\.\s+(?=\S)",                                         # dot-sourcing
    r"(?:call|time|exec|nohup|start(?:\s+/\w+)*)\s+",
    r"env(?:\s+-\S+)*\s+",
    r"[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|\S*)\s+",  # VAR=x cmd
    r"\$env:[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:\"[^\"]*\"|'[^']*'|\S*)\s*",
    r"cmd(?:\.exe)?\s+/[ckCK]\s+",
    r"(?:powershell|pwsh)(?:\.exe)?(?:\s+-(?:NoProfile|nop|NoLogo|NonInteractive|noni|NoExit|Sta|Mta)\b"
    r"|\s+-(?:ExecutionPolicy|ep|ex|WindowStyle|w|WorkingDirectory|wd|OutputFormat|of|InputFormat|if|Version|v)\s+\S+)*"
    r"(?:\s+-(?:c|command|file|f)\b)?\s+(?=[^\s-])",
    r"(?:python[\d.]*|py|node|ruby|perl)(?:\.exe)?(?:\s+-(?!m\b)[A-Za-z]+\b)*\s+(?=[^\s-])",  # interpreter running a script
    r"(?:ba|z|da)?sh(?:\.exe)?(?:\s+-\w*c\w*|\s+-[a-z]+)*\s+(?=[\"'])",
    r"(?:ba|z|da)?sh(?:\.exe)?\s+(?=\S+\.sh\b)",
    r"(?:npx|pnpx|bunx)(?:\.cmd)?(?:\s+-\S+)*\s+",
    r"(?:yarn\s+dlx|pnpm\s+(?:exec|dlx)|npm\s+exec(?:\s+--)?|uv\s+run|poetry\s+run|pipenv\s+run|hatch\s+run|dotnet\s+tool\s+run)\s+",
]
WRAPPER_RX = re.compile(r"\s*(?:" + "|".join(WRAPPERS) + r")", re.I)

def strip_bodies(command):
    # Heredoc and here-string bodies are data (a file's text, a commit message), not commands.
    c = re.sub(r"<<-?\s*([\"']?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?=\n|$)", "\n", command, flags=re.S)
    return re.sub(r"@([\"'])\s*\n.*?\n\1@", "\n", c, flags=re.S)

def segments(command):
    """Each command a shell call runs, wrappers stripped and the program's leading path dropped, so patterns can
    match at the start: 'cd x && "C:/Program Files/dotnet/dotnet.exe" test' yields 'cd x' and 'dotnet.exe" test'."""
    for raw in re.split(r"[;\n|]|&&|\$\(|\b(?:then|do|else)\b", strip_bodies(command)):
        seg = raw
        for _ in range(12):
            m = WRAPPER_RX.match(seg)
            if not m or m.end() == 0:
                break
            seg = seg[m.end():]
        seg = seg.strip()
        if not seg:
            continue
        # Drop the program's directory: C:\x\dotnet.exe -> dotnet.exe, ./tools/test.ps1 -> test.ps1, even quoted with spaces.
        m = re.match(r"(?:[A-Za-z]:)?(?:[^\s\\/\"']*[\\/]|[^\\/\"'\n]*[\\/](?=[^\"'\n]*[\"']))+", seg)
        if m and (m.end() < len(seg)):
            seg = seg[m.end():]
        yield seg

def runs_tests(command, patterns):
    """The name of the first test/soak pattern the command runs, or None."""
    for seg in segments(str(command or "")):
        for name, rx, at in patterns:
            if (rx.search(seg) if at == "anywhere" else rx.match(seg)):
                return name
    return None

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

# ---- permission state ----------------------------------------------------------------------------------------------

def safe(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(name or ""))[:120]

def state_path(kind, key):
    return STATE_DIR / f"{kind}-{safe(key)}.json"

def read_state(kind, key):
    if not key:
        return None
    try:
        return json.loads(state_path(kind, key).read_text(encoding="utf-8"))
    except Exception:
        return None

def write_state(kind, key, value):
    if not key:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = state_path(kind, key)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(value), encoding="utf-8")
    os.replace(tmp, p)

def sweep():
    try:
        cutoff = time.time() - KEEP_FILES
        for f in STATE_DIR.glob("*.json"):
            if f.stat().st_mtime < cutoff:
                f.unlink()
    except Exception:
        pass

def permitted(sid, agent_id, now=None):
    """Whether this tool call may run tests: the subagent's own snapshot of its parent turn when it has one, else
    the session's latest typed prompt (a subagent's call carries its parent's session_id)."""
    now = now or time.time()
    s = read_state("agent", agent_id) if agent_id else None
    if s is None:
        s = read_state("session", sid)
    return bool(s and s.get("allowed") and now - float(s.get("at") or 0) <= MAX_AGE)

# ---- hook entry ----------------------------------------------------------------------------------------------------
# Claude, Codex and Kimi send Claude's snake_case payload (hook_event_name, session_id, agent_id, tool_input.command)
# and read hookSpecificOutput.permissionDecision. agy sends camelCase (conversationId, toolCall.args.CommandLine),
# names no event in it (install-hooks.ps1 passes the event as argv[2]) and reads {"decision": "deny", "reason"}.

def first_str(*values):
    for v in values:
        if isinstance(v, str) and v.strip():
            return v
    return None

def handle(data, provider="claude", event_arg=None):
    """Returns the JSON to print (a deny), or None to allow / say nothing."""
    event = data.get("hook_event_name") or data.get("hookEventName") or event_arg or ""
    sid = first_str(data.get("session_id"), data.get("sessionId"), data.get("conversationId"))
    agent_id = first_str(data.get("agent_id"), data.get("agentId"))
    if event in ("UserPromptSubmit", "PreInvocation"):
        prompt = first_str(data.get("prompt"), data.get("user_prompt"), data.get("userPrompt"), data.get("userMessage"))
        if prompt is None and event == "PreInvocation":
            return None  # agy fires this per model call; only one carrying the user's prompt sets the permission
        write_state("session", sid, {"allowed": asks_for_tests(prompt or ""), "at": time.time()})
        sweep()
        return None
    if event == "SubagentStart":
        parent = read_state("session", sid) or {"allowed": False, "at": time.time()}
        write_state("agent", agent_id, {"allowed": bool(parent.get("allowed")), "at": parent.get("at") or time.time()})
        return None
    if event == "PreToolUse":
        call = data.get("toolCall") if isinstance(data.get("toolCall"), dict) else {}
        args = call.get("args") if isinstance(call.get("args"), dict) else {}
        command = command_of(data.get("tool_input")) or first_str(args.get("CommandLine"), args.get("command"), args.get("cmd"))
        if not command:
            return None
        name = runs_tests(command, load_patterns(first_str(data.get("cwd"), data.get("workspaceRoot"), os.getcwd())))
        if not name or permitted(sid, agent_id):
            return None
        reason = REFUSAL.format(name=name)
        if provider == "agy":
            return {"decision": "deny", "reason": reason}
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                       "permissionDecisionReason": reason}}
    return None

def main():
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        data = json.loads(raw) if raw.strip() else {}
        provider = (sys.argv[1] if len(sys.argv) > 1 else "claude").lower()
        event_arg = sys.argv[2] if len(sys.argv) > 2 else None
        out = handle(data, provider, event_arg) if isinstance(data, dict) else None
    except Exception:
        return 0  # fail open
    if out:
        try:
            sys.stdout.write(json.dumps(out))
            sys.stdout.flush()
        except Exception:
            pass
    return 0

if __name__ == "__main__":
    sys.exit(main())
