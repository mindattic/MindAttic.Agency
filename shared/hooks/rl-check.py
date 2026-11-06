#!/usr/bin/env python3
"""
Rate limit status banner — reads from ~/.claude/rl-status.json
Shows cached status at session startup. Updated by the rate-limit-monitor skill.
"""
import json
import sys
from pathlib import Path
from datetime import datetime

STATUS_FILE = Path.home() / ".claude" / "rl-status.json"

def color(text, code):
    return f"\033[{code}m{text}\033[0m"

def main():
    # Hook stdout is a pipe, which Windows Python encodes as cp1252; the bar characters need UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    if not STATUS_FILE.exists():
        print(color("  [RATE LIMIT] No status cached yet. Will track after first session.", "33"))
        return

    try:
        with open(STATUS_FILE) as f:
            s = json.load(f)
    except Exception:
        print(color("  [RATE LIMIT] Could not read status cache.", "33"))
        return

    pct = s.get("percent_used", 0)
    reset = s.get("reset_time", "unknown")
    tokens_left = s.get("tokens_remaining", "?")
    cached_at = s.get("timestamp", "")
    
    # Calculate age
    age_str = ""
    mins = None
    if cached_at:
        try:
            age = datetime.utcnow() - datetime.fromisoformat(cached_at.replace("Z",""))
            mins = int(age.total_seconds() / 60)
            age_str = f"  cached {mins}m ago"
        except Exception:
            pass

    # Choose color
    if pct >= 96:
        c = "31"  # red
        icon = "[!!]"
    elif pct >= 90:
        c = "91"  # bright red
        icon = "[!!]"
    elif pct >= 80:
        c = "33"  # yellow
        icon = "[ !]"
    else:
        c = "32"  # green
        icon = "[ .]"

    bar_filled = int(pct / 5)
    bar = "█" * bar_filled + "░" * (20 - bar_filled)

    pct_text = s.get("percent_text") or f"{pct:.1f}%"
    print("")
    print(color(f"  {icon} RATE LIMIT  {bar}  {pct_text} used  |  Reset: {reset}  |  ~{tokens_left} tokens left{age_str}", c))
    print("")

    if pct >= 96:
        print(color("  *** AT LIMIT — do not run tasks until reset ***", "31"))
        print("")

    # MindAttic.Orchestrator's pacer: set while usage is outrunning what fits before the reset.
    # It refreshes every minute while running; an older note is stale advice, so skip it.
    note = s.get("pace_note")
    if note and s.get("pace", "open") != "open" and mins is not None and mins <= 10:
        print(color(f"  [PACE: {s['pace'].upper()}] {note}", "33"))
        print("")

if __name__ == "__main__":
    main()
