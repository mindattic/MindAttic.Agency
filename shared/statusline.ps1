<#
  Statusline - live context-window gauge with escalating quicksave warnings.

  Claude Code pipes a JSON status blob to this script on stdin every render. We surface the
  usual bearings (model / folder / git branch) plus a context-usage segment that escalates as
  the window fills, so there is time to run /quicksave and /clear WITH ROOM TO SPARE before the
  harness auto-compacts.

  Thresholds (percent of context used) - tune these two numbers to taste:
    WARN  -> "[!] quicksave soon"   (amber)
    CRIT  -> "[!!] /quicksave NOW"  (red, bold)
  Defaults leave real headroom below the ~95% auto-compaction point.

  Notes: used_percentage counts input tokens only and is null before the first API call and
  right after a compact. Pure-ASCII markers ([!]/[!!]) so any terminal renders them.
#>
$WARN = 80
$CRIT = 90

$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }

# --- usage limits: Claude Code's own 5-hour / 7-day used percent, saved for MindAttic.Orchestrator's pacer ---
if ($j -and $j.rate_limits) {
  try {
    $file = Join-Path $env:USERPROFILE '.claude\claude-usage.json'
    # Each open session redraws every minute with the percent from its OWN last reply, so an idle one carries a stale,
    # lower percent (12% while the window was at 35%). Usage never falls within a window: a reading no higher than the
    # file's for the same window is left out, so the file only moves up and its time stays the newest real reading.
    $stale = $false
    $new = $j.rate_limits.five_hour
    if ($new -and $null -ne $new.used_percentage -and (Test-Path -LiteralPath $file)) {
      try {
        $old = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).rate_limits.five_hour
        $stale = $old -and "$($old.resets_at)" -eq "$($new.resets_at)" -and [double]$new.used_percentage -le [double]$old.used_percentage
      } catch { }
    }
    if (-not $stale) {
      $usage = [ordered]@{ rate_limits = $j.rate_limits; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json -Depth 5 -Compress
      [IO.File]::WriteAllText("$file.$PID.tmp", $usage)
      Move-Item -LiteralPath "$file.$PID.tmp" -Destination $file -Force
    }
  } catch { }
}

# --- this session's context fill, so the orchestrator can /quicksave, /clear, /quickload it before it's full ---
if ($j -and $j.session_id -and $j.context_window -and $null -ne $j.context_window.used_percentage) {
  try {
    $dir = Join-Path $env:USERPROFILE '.claude\session-context'
    [void][IO.Directory]::CreateDirectory($dir)
    $ctxJson = [ordered]@{
      session_id = $j.session_id; cwd = $j.cwd; transcript_path = $j.transcript_path
      used_percentage = $j.context_window.used_percentage; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json -Compress
    $file = Join-Path $dir "$($j.session_id).json"
    [IO.File]::WriteAllText("$file.$PID.tmp", $ctxJson)
    Move-Item -LiteralPath "$file.$PID.tmp" -Destination $file -Force
  } catch { }
}

$e = [char]27
$reset = "$e[0m"; $dim = "$e[2m"; $cyan = "$e[36m"; $amber = "$e[33m"; $red = "$e[1;31m"; $green = "$e[32m"

# --- model ---
$model = ''
if ($j -and $j.model -and $j.model.display_name) { $model = $j.model.display_name }

# --- current dir (leaf) ---
$cwd = ''
if ($j -and $j.workspace -and $j.workspace.current_dir) { $cwd = $j.workspace.current_dir }
elseif ($j -and $j.cwd) { $cwd = $j.cwd }
$leaf = if ($cwd) { Split-Path -Leaf $cwd } else { '' }

# --- git branch (read .git/HEAD directly; walk up; no git process) ---
$branch = ''
$repoRoot = ''
$dir = $cwd
for ($i = 0; $i -lt 6 -and $dir; $i++) {
  $head = Join-Path $dir '.git\HEAD'
  if (Test-Path $head) {
    $repoRoot = $dir
    $h = (Get-Content -LiteralPath $head -Raw -ErrorAction SilentlyContinue).Trim()
    if ($h -match '^ref:\s*refs/heads/(.+)$') { $branch = $Matches[1] }
    elseif ($h) { $branch = $h.Substring(0, [Math]::Min(7, $h.Length)) }
    break
  }
  $parent = Split-Path -Parent $dir
  if ($parent -eq $dir) { break }
  $dir = $parent
}

# --- context segment ---
$pct = $null
if ($j -and $j.context_window -and $null -ne $j.context_window.used_percentage) {
  $pct = [int]$j.context_window.used_percentage
}
if ($null -eq $pct) {
  $ctx = "${dim}ctx --%${reset}"
} elseif ($pct -ge $CRIT) {
  $ctx = "${red}[!!] ctx ${pct}% - /quicksave NOW${reset}"
} elseif ($pct -ge $WARN) {
  $ctx = "${amber}[!] ctx ${pct}% - quicksave soon${reset}"
} else {
  $ctx = "${green}ctx ${pct}%${reset}"
}

# --- assemble ---
$parts = @()
if ($model)  { $parts += "${cyan}$model${reset}" }
if ($leaf)   { $parts += "$leaf" }
if ($branch) { $parts += "${dim}($branch)${reset}" }
$parts += $ctx

Write-Output ($parts -join "  ${dim}|${reset}  ")

# --- autopilot waiting on the pace (saved by MindAttic.Orchestrator each tick; costs no tokens) ---
if ($repoRoot) {
  try {
    $wait = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\allocate-waiting.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    $repo = Split-Path -Leaf $repoRoot
    $fresh = ([DateTime]::UtcNow - [DateTime]::Parse($wait.at).ToUniversalTime()).TotalMinutes -lt 10
    if ($fresh -and ($wait.repos | Where-Object { $_ -ieq $repo })) {
      Write-Output "${amber}Autopilot is on for $repo, but usage is ahead of the 5-hour pace; I'll pick up the next ticket as soon as there's room.${reset}"
    }
  } catch { }
}
