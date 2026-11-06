---
name: capture
description: Screenshot the app hosting this CLI (the Orchestrator tab, or the terminal when run solo) and copy the image to the clipboard.
argument-hint: ""
claude-only: false
claude-allowed-tools: Bash, PowerShell
---
Backed by `MindAttic.Capture`'s agent (`capture shot --self --clipboard`, M.CAPT-T77). `--self`
resolves the window to capture itself: `APP_EXE` (set by MindAttic.Orchestrator's launcher and
inherited by every tab it hosts, including through a TermHost with no window of its own) wins
first, so a CLI running as an Orchestrator tab captures the Orchestrator window; otherwise it walks
up this process's ancestors for the nearest one that owns a window - the terminal itself when the
CLI runs solo.

## 1. Find `capture.exe`

In order:
1. `capture` on PATH (only present if `MindAttic.Capture\tools\install.ps1 -AddToPath` was used).
2. `%LOCALAPPDATA%\MindAttic\Capture\bin\capture.exe` (the normal installed location).
3. Neither exists: the repo hasn't been deployed here yet. Run
   `powershell -File D:\Projects\MindAttic\MindAttic.Capture\run.ps1` once (installs `capture.exe` and
   `capture-tray.exe`), then retry step 1-2. If that repo isn't checked out either, say so and stop - don't
   build an ad hoc copy.

## 2. Capture

```
capture shot --self --clipboard
```

Image format defaults to PNG. No `--out` override: let it land in the normal `R:\MindAttic\Capture\...`
tree (or the `%USERPROFILE%\Videos\MindAttic` fallback) like every other capture.

## 3. Report

One line: the saved file path, and that it's on the clipboard, ready to paste. On failure (e.g. "No
ancestor process of this CLI owns a window to capture"), show the error as-is - don't retry with a
different target silently, since the whole point is capturing *this* CLI's own host, not a guess.
