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

function Get-RepliedAt($session, $path) {
  # When this session's last reply came (epoch seconds): its transcript's last assistant entry; $null when unknown. Cached by
  # the transcript's length, so an unchanged transcript isn't read again (outside session-context, which is all sessions).
  if (-not $session -or -not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
  $cache = Join-Path (Join-Path $env:TEMP 'mindattic-statusline') "$session.json"
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
  try {
    $length = $fs.Length
    try { $c = Get-Content -LiteralPath $cache -Raw -ErrorAction Stop | ConvertFrom-Json; if ($c.length -eq $length) { return $c.replied } } catch { }
    $take = [int][Math]::Min($length, 1MB)
    [void]$fs.Seek(-$take, 'End')
    $buf = New-Object byte[] $take
    $read = 0
    while ($read -lt $take) { $n = $fs.Read($buf, $read, $take - $read); if ($n -le 0) { break }; $read += $n }
    $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n"
  } finally { $fs.Dispose() }
  $replied = $null
  for ($i = $lines.Count - 1; $i -ge 0 -and $null -eq $replied; $i--) {
    if ($lines[$i] -match '"type"\s*:\s*"assistant"') {
      # The entry's own time is its last "timestamp": a tool call's input can carry one of its own earlier in the line.
      $stamps = [regex]::Matches($lines[$i], '"timestamp"\s*:\s*"([^"]+)"')
      if ($stamps.Count) {
        $replied = [DateTimeOffset]::Parse($stamps[$stamps.Count - 1].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() / 1000.0
      }
    }
  }
  try {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $cache))
    [IO.File]::WriteAllText($cache, ([ordered]@{ length = $length; replied = $replied } | ConvertTo-Json -Compress))
  } catch { }
  return $replied
}

$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }

# --- usage limits: Claude Code's own 5-hour / 7-day used percent, saved for MindAttic.Orchestrator's pacer ---
if ($j -and $j.rate_limits) {
  try {
    $file = Join-Path $env:USERPROFILE '.claude\claude-usage.json'
    # Each open session redraws every minute with the percent from its OWN last reply, so an idle one carries a stale,
    # lower percent (12% while the window was at 35%). Usage never falls within a window: a reading no higher than the
    # file's for the same window is left out, so the file only moves up and its time stays the newest real reading.
    # A reply from a window that has already reset is left out too: restamped with now, it hid the running window's
    # reading for 1h55m on Oct 19 (M.ORCH-T479), since the pacer saw a fresh file and never asked Claude itself.
    $stale = $false
    $new = $j.rate_limits.five_hour
    # resets_at is normally epoch seconds, but parse defensively (MAT-T50): a payload that ever carries
    # it as an ISO date must not throw past this point and silently drop the whole usage write below; an
    # unparseable value is treated as already stale rather than skipping the M.ORCH-T479 check outright.
    if ($new -and $null -ne $new.resets_at) {
      $resetsAtSeconds = $null
      try { $resetsAtSeconds = [double]$new.resets_at } catch {
        try { $resetsAtSeconds = [DateTimeOffset]::Parse([string]$new.resets_at, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() } catch { $stale = $true }
      }
      if ($null -ne $resetsAtSeconds -and $resetsAtSeconds -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { $stale = $true }
    }
    if (-not $stale -and $new -and $null -ne $new.used_percentage -and (Test-Path -LiteralPath $file)) {
      try {
        $old = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).rate_limits.five_hour
        $stale = $old -and "$($old.resets_at)" -eq "$($new.resets_at)" -and [double]$new.used_percentage -le [double]$old.used_percentage
      } catch { }
    }
    # After a /login the same redraw restamps the old account's last reply as new. A reply from after the current account's
    # sign-in (account.json, kept by MindAttic.Orchestrator) is tagged with that account so it counts at once; one from
    # before it is the old account's and is left out. An API key has no windows of its own to tag.
    $account = $null
    $signIn = Join-Path $env:USERPROFILE '.claude\session-context\account.json'
    if (-not $stale -and (Test-Path -LiteralPath $signIn)) {
      try {
        $seen = Get-Content -LiteralPath $signIn -Raw | ConvertFrom-Json
        if ($seen.account -and $null -ne $seen.since) {
          $replied = Get-RepliedAt $j.session_id $j.transcript_path
          if ($null -ne $replied -and $replied -lt [double]$seen.since) { $stale = $true }
          elseif ($null -ne $replied -and $seen.account -ne 'api-key') { $account = $seen.account }
        }
      } catch { }
    }
    if (-not $stale) {
      $usage = [ordered]@{ rate_limits = $j.rate_limits; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
      if ($account) { $usage.account = $account }
      $usage = $usage | ConvertTo-Json -Depth 5 -Compress
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

# --- this CLI's own ticket work waiting on the pace (saved by MindAttic.Orchestrator each tick; costs no tokens) ---
if ($repoRoot) {
  try {
    $wait = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\allocate-waiting.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    $repo = Split-Path -Leaf $repoRoot
    $fresh = ([DateTime]::UtcNow - [DateTime]::Parse($wait.at).ToUniversalTime()).TotalMinutes -lt 10
    if ($fresh -and ($wait.repos | Where-Object { $_ -ieq $repo })) {
      Write-Output "${amber}Ticket work for $repo is paused - usage is ahead of the 5-hour pace; I'll pick up the next ticket as soon as there's room.${reset}"
    }
  } catch { }
}
