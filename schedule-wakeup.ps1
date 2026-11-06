[CmdletBinding(DefaultParameterSetName = 'Delay')]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('claude', 'codex', 'kimi', 'agy')]
  [string]$Cli,

  [Parameter(Mandatory)]
  [string]$WorkDir,

  [Parameter(Mandatory)]
  [string]$Prompt,

  [Parameter(ParameterSetName = 'Delay')]
  [int]$DelaySeconds = 0,

  [Parameter(ParameterSetName = 'Delay')]
  [int]$DelayMinutes = 0,

  [Parameter(Mandatory, ParameterSetName = 'At')]
  [string]$At,

  [string]$TaskName,

  [string]$LogDir,

  [string[]]$ExtraCliArgs = @(),

  [string[]]$EnvOverrides = @(),

  [string]$Cancel
)

<#
.SYNOPSIS
MAT-T103 item 1 - a generic, provider-agnostic "resume this CLI later without the user typing
continue" mechanism, built on Windows Task Scheduler instead of a Claude-SDK-only primitive.

.DESCRIPTION
Claude Code's own ScheduleWakeup tool is really just "re-invoke this CLI non-interactively with a
prompt at a future time." schtasks can do exactly that for ANY CLI this workspace runs - Claude,
Codex, Kimi, or agy - because every one of them ships a non-interactive print/exec mode:
  claude -p "<prompt>"      (cwd = the working directory; Claude reads it directly)
  codex exec -C "<dir>" "<prompt>"
  kimi -p "<prompt>"        (cwd set before invocation; kimi has no separate -C/--cwd flag)
  agy -p "<prompt>"         (cwd set before invocation; agy has no separate -C/--cwd flag)
Confirmed from each CLI's own `--help`/`exec --help` output (MAT-T103), not guessed.

This script:
  1. Computes a fire time from -DelaySeconds/-DelayMinutes or an absolute -At time.
  2. Base64-encodes the prompt (sidesteps all schtasks/cmd quoting limits - the prompt can contain
     quotes, newlines, anything) and writes a small one-shot wrapper .ps1 under
     $env:LOCALAPPDATA\MindAttic\ScheduledWakeups\ that: cd's to -WorkDir, decodes the prompt,
     invokes the target CLI non-interactively, redirects all output to a log file (default:
     a "wakeup-logs" folder created ALONGSIDE -WorkDir, i.e. its sibling, so logs never pollute a
     git-tracked repo checkout), deletes its own scheduled task (`schtasks /delete`), then deletes
     itself - nothing lingers but the log.
  3. Registers that wrapper as a ONE-SHOT scheduled task (`schtasks /create /sc once`).

.PARAMETER Cli
  Which CLI to re-invoke: claude, codex, kimi, or agy.

.PARAMETER WorkDir
  The working directory the CLI should run in (e.g. the repo checkout it was working in).

.PARAMETER Prompt
  The resume instruction / prompt text the CLI re-invocation receives.

.PARAMETER DelaySeconds / DelayMinutes
  Relative delay from now. Combine freely (e.g. -DelayMinutes 90 -DelaySeconds 30).

.PARAMETER At
  Absolute fire time instead of a delay, anything [datetime]::Parse accepts (e.g.
  "2026-11-07 06:00" or "9:30pm").

.PARAMETER TaskName
  Scheduled task name. Default: MindAtticWakeup-<Cli>-<yyyyMMddHHmmssfff>.

.PARAMETER LogDir
  Where the wrapper writes its log file. Default: a "wakeup-logs" folder created as a SIBLING of
  -WorkDir (so it never lands inside a git repo).

.PARAMETER ExtraCliArgs
  Extra flags appended to the CLI invocation verbatim (e.g. -ExtraCliArgs '--model','opus').
  Nothing is added by default - in particular this script never silently adds a
  permission-bypass flag; the caller decides whether the resumed CLI needs one.

.PARAMETER EnvOverrides
  Optional "KEY=VALUE" pairs set as process env vars in the wrapper before the CLI runs (e.g. to
  point an isolated-CODEX_HOME test rig at a scratch directory instead of a live, concurrently-used
  one - the same safe-testing convention MAT-T94/95/100 used for Codex).

.PARAMETER Cancel
  Instead of scheduling anything, deletes the named scheduled task (cleanup helper for a wakeup
  that's no longer needed). All other parameters are ignored when -Cancel is used.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File schedule-wakeup.ps1 `
    -Cli codex -WorkDir D:\Projects\MindAttic\MindAttic.Agency -DelayMinutes 2 `
    -Prompt "Resume MAT-T103: the pace window should be clear now, continue item 2."

.EXAMPLE
  # Isolated test rig: point the resumed Codex invocation at a scratch CODEX_HOME instead of the
  # real, possibly-concurrently-used one.
  powershell -NoProfile -ExecutionPolicy Bypass -File schedule-wakeup.ps1 -Cli codex `
    -WorkDir C:\scratch\codex-wakeup-test -DelayMinutes 2 -Prompt "Say hello." `
    -EnvOverrides 'CODEX_HOME=C:\scratch\codex-wakeup-test\codexhome' `
    -ExtraCliArgs '--dangerously-bypass-approvals-and-sandbox', '--skip-git-repo-check'
#>

$ErrorActionPreference = 'Stop'

if ($Cancel) {
  Write-Output "Cancelling scheduled task '$Cancel' ..."
  schtasks /delete /tn $Cancel /f
  if ($LASTEXITCODE -ne 0) { throw "schtasks /delete failed for '$Cancel' (exit $LASTEXITCODE)." }
  Write-Output "Cancelled."
  return
}

$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
  throw "WorkDir does not exist or is not a directory: $WorkDir"
}

# --- fire time -------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'At') {
  $fireTime = [datetime]::Parse($At)
} else {
  $totalSeconds = $DelaySeconds + ($DelayMinutes * 60)
  if ($totalSeconds -le 0) { throw "Specify -DelaySeconds/-DelayMinutes (> 0) or -At." }
  $fireTime = (Get-Date).AddSeconds($totalSeconds)
}
# schtasks refuses a start time already in the past by the time it actually parses the command;
# give it at least a minute of headroom rather than letting a near-zero delay race the clock.
$minFireTime = (Get-Date).AddSeconds(45)
if ($fireTime -lt $minFireTime) { $fireTime = $minFireTime }

if ([string]::IsNullOrWhiteSpace($TaskName)) {
  $TaskName = "MindAtticWakeup-$Cli-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
  $parent = Split-Path -Parent $WorkDir
  $leaf = Split-Path -Leaf $WorkDir
  $LogDir = Join-Path $parent "wakeup-logs\$leaf"
} else {
  $LogDir = [IO.Path]::GetFullPath($LogDir)
}

$wrapperRoot = Join-Path $env:LOCALAPPDATA 'MindAttic\ScheduledWakeups'
New-Item -ItemType Directory -Path $wrapperRoot -Force | Out-Null
$wrapperPath = Join-Path $wrapperRoot "$TaskName.ps1"
$logFileName = "$TaskName.log"

$promptBytes = [System.Text.Encoding]::UTF8.GetBytes($Prompt)
$promptB64 = [System.Convert]::ToBase64String($promptBytes)

# --- per-CLI non-interactive invocation line --------------------------------
# Confirmed from each CLI's own --help / exec --help (MAT-T103), not guessed:
#   claude -p "<prompt>"            (cwd read directly; no separate -C/--cwd flag)
#   codex exec -C "<dir>" "<prompt>"
#   kimi -p "<prompt>"              (no -C/--cwd flag; relies on cwd, set via Set-Location below)
#   agy -p "<prompt>"               (no -C/--cwd flag; relies on cwd, set via Set-Location below)
# Extra args, if any, are rendered as individual quoted literals joined by spaces so they splat
# onto the call as separate arguments (NOT a PowerShell array-literal comma list).
$extraArgsLiteral = ($ExtraCliArgs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
# Piped through Out-File -Encoding utf8 rather than the native *>> redirection operator: in
# Windows PowerShell 5.1, *>> writes a native command's captured output using a different default
# encoding than Set-Content/Add-Content's own ANSI default, so the two interleave as mixed-encoding
# garbage in the same file (confirmed by MAT-T103's own first test run). Routing everything through
# one explicit -Encoding utf8 sink keeps the whole log file consistent.
$sink = "Out-File -FilePath `$logFile -Append -Encoding utf8"
switch ($Cli) {
  'claude' { $invokeLine = "& claude -p `$prompt $extraArgsLiteral 2>&1 | $sink" }
  'codex'  { $invokeLine = "& codex exec -C '$($WorkDir -replace "'", "''")' `$prompt $extraArgsLiteral 2>&1 | $sink" }
  'kimi'   { $invokeLine = "& kimi -p `$prompt $extraArgsLiteral 2>&1 | $sink" }
  'agy'    { $invokeLine = "& agy -p `$prompt $extraArgsLiteral 2>&1 | $sink" }
}
$invokeLine = $invokeLine -replace '\s{2,}', ' '  # tidy up the double space left when $extraArgsLiteral is empty

$envLines = ($EnvOverrides | ForEach-Object {
  $k, $v = $_.Split('=', 2)
  "`$env:$k = '$($v -replace "'", "''")'"
}) -join "`r`n"

$wrapperContent = @"
# Auto-generated by schedule-wakeup.ps1 (MAT-T103) - one-shot, self-deleting wakeup wrapper.
`$ErrorActionPreference = 'Continue'
$envLines
Set-Location -LiteralPath '$($WorkDir -replace "'", "''")'
`$logDir = '$($LogDir -replace "'", "''")'
if (-not (Test-Path -LiteralPath `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$logFile = Join-Path `$logDir '$logFileName'
`$prompt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$promptB64'))
"=== MindAttic scheduled wakeup fired at `$(Get-Date -Format o) ===" | Set-Content -LiteralPath `$logFile -Encoding utf8
"CLI: $Cli" | Add-Content -LiteralPath `$logFile -Encoding utf8
"WorkDir: $($WorkDir -replace "'", "''")" | Add-Content -LiteralPath `$logFile -Encoding utf8
"TaskName: $TaskName" | Add-Content -LiteralPath `$logFile -Encoding utf8
"Prompt: `$prompt" | Add-Content -LiteralPath `$logFile -Encoding utf8
"--- CLI output ---" | Add-Content -LiteralPath `$logFile -Encoding utf8
try {
  $invokeLine
  "--- exit code: `$LASTEXITCODE ---" | Add-Content -LiteralPath `$logFile -Encoding utf8
} catch {
  "ERROR invoking $Cli`: `$_" | Add-Content -LiteralPath `$logFile -Encoding utf8
}
# Self-delete: the scheduled task, then this wrapper script. Nothing lingers but the log.
schtasks /delete /tn '$TaskName' /f 2>&1 | Out-File -FilePath `$logFile -Append -Encoding utf8
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@

Set-Content -LiteralPath $wrapperPath -Value $wrapperContent -Encoding utf8

$startDate = $fireTime.ToString('MM/dd/yyyy')
$startTime = $fireTime.ToString('HH:mm')
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""

Write-Output "Scheduling '$TaskName' to fire $Cli in '$WorkDir' at $fireTime ..."
Write-Output "  wrapper: $wrapperPath"
Write-Output "  log:     $(Join-Path $LogDir $logFileName)"

schtasks /create /tn $TaskName /tr $tr /sc once /sd $startDate /st $startTime /f
if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed (exit $LASTEXITCODE)." }

Write-Output "Scheduled. Cancel with: schedule-wakeup.ps1 -Cancel $TaskName"
