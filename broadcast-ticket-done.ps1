<#
.SYNOPSIS
Generic, provider-agnostic "tell every other CLI a ticket just closed" broadcast (MAT-T105).

.DESCRIPTION
Reuses the nudge mechanism MindAttic.Orchestrator's own Daemon already relies on
(MindAttic.Orchestrator/src/MindAttic.Orchestrator.Core/Sessions/CliNudges.cs, M.ORCH-T864):
a nudge-<pid>-<kind>.txt file dropped in the shared session-context directory is picked up by
`shared/hooks/context-gate.py`'s take_nudges() and folded into that PID's own next turn as hook
context - never typed into its input box, and never gated on which CLI product owns that PID,
because take_nudges() keys purely on MINDATTIC_CLI_PID / the OS pid. Since install-hooks.ps1
(MAT-T94) already points Claude's, Codex's, Kimi's and agy's hooks at this one shared
context-gate.py, writing one of these files reaches whichever of those four products happens to
own that pid - with no per-product branch needed here.

This script finds every CLI process currently known to be alive (any state.json under the shared
session-context directory, deduped by pid, filtered to pids a live process still answers to) and
leaves each one a "ticket done" nudge.

Limits, stated plainly rather than assumed away:
- Delivery depends on that CLI's own hook actually firing before the nudge goes stale (20 minutes,
  context-gate.py's own take_nudges() constant) - a CLI idle longer than that simply never sees it.
  The ticket database itself (`tickets ticket show <ID> --json`) stays the durable, no-expiry record;
  this is a best-effort "find out sooner" layer on top of it, not a replacement for it.
- Only reaches pids that have ever run the shared context-gate.py (so written a state.json here).
  A CLI that has never run a single turn since being wired to the shared hooks has no state.json
  yet and is invisible to this script until it does.

.PARAMETER TicketId
The ticket ID that just closed, e.g. U.RICO-T166.

.PARAMETER Summary
One line: what the ticket was and what's now true. Kept short - this lands as plain hook context.

.PARAMETER ExcludePid
Optional pid(s) to skip (normally the calling CLI's own pid, so it doesn't nudge itself with news
it already knows).

.EXAMPLE
powershell -File MindAttic.Agency\broadcast-ticket-done.ps1 -TicketId U.RICO-T166 `
  -Summary "Autowalk capture timing fixed - earlier-room PNGs under docs/captures/ are now real." `
  -ExcludePid 52524
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TicketId,
    [Parameter(Mandatory)][string]$Summary,
    [int[]]$ExcludePid = @()
)

$ErrorActionPreference = 'Stop'

$marksDir = Join-Path $HOME ".claude\session-context"
if (-not (Test-Path $marksDir)) {
    Write-Warning "No session-context directory at $marksDir - nothing to broadcast to yet."
    return
}

$cutoff = (Get-Date).ToUniversalTime().AddHours(-6)
$pids = @{}
Get-ChildItem -Path $marksDir -Filter '*.state.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $json = Get-Content -Raw -Encoding UTF8 $_.FullName | ConvertFrom-Json
    } catch { return }
    if (-not $json.pid) { return }
    $at = $null
    if ($json.at) { try { $at = [DateTime]::Parse($json.at, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch {} }
    if ($at -and $at -lt $cutoff) { return }   # state file too old to trust the pid is still this CLI
    $pids[[int]$json.pid] = $true
}

$targets = $pids.Keys | Where-Object { $ExcludePid -notcontains $_ } | Sort-Object -Unique
$text = "Ticket $TicketId closed: $Summary Check your repo's queue (tickets ticket queue) - a prerequisite may now be clear."

$sent = 0
foreach ($p in $targets) {
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if (-not $proc) { continue }   # state.json is stale; that pid is gone
    $path = Join-Path $marksDir "nudge-$p-ticket-done.txt"
    $temp = "$path.tmp"
    try {
        [System.IO.File]::WriteAllText($temp, $text, [System.Text.Encoding]::UTF8)
        Move-Item -Force $temp $path
        $sent++
    } catch {
        Write-Warning "Couldn't leave a nudge for pid $p`: $($_.Exception.Message)"
    }
}

Write-Host "Left a ticket-done nudge for $sent live CLI process(es)."
