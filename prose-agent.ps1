[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('bootstrap','save','load','do','progress','show','queue')]
  [string]$Command = 'bootstrap',
  [string]$RepoRoot,
  [string]$Item,
  [switch]$List,
  [switch]$Drain,
  [string]$Task,
  [string]$Decisions,
  [string]$State,
  [string]$Next,
  [string]$Subject,
  [string]$Aspect,
  [string]$Universe,
  [switch]$Json,
  [switch]$Keep
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Get-Location).Path }
# Per-repo agent state lives in .agent (it was .prose, which read as the separate Prose product).
$stateDir = Join-Path $RepoRoot '.agent'
$sessionPath = Join-Path $stateDir 'agent-session.json'
# One-time migration: carry a handoff/queue (and their .NNN archives) saved under the old .prose
# folder across, so a save made before the rename still loads. Never overwrites a newer .agent file;
# anything else in .prose (e.g. Prose's own hooks) is left where it is.
$legacyStateDir = Join-Path $RepoRoot '.prose'
if (Test-Path -LiteralPath $legacyStateDir) {
  $legacy = @(Get-ChildItem -LiteralPath $legacyStateDir -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^agent-(session|queue)\.json(\.\d{3})?$' })
  if ($legacy.Count -gt 0) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    foreach ($f in $legacy) {
      $dest = Join-Path $stateDir $f.Name
      if (-not (Test-Path -LiteralPath $dest)) { Move-Item -LiteralPath $f.FullName -Destination $dest }
    }
    if (-not (Get-ChildItem -LiteralPath $legacyStateDir -Force)) { Remove-Item -LiteralPath $legacyStateDir }
  }
}
$cliDll = Join-Path $RepoRoot 'v3\Prose.Cli\bin\Debug\net10.0\Prose.Cli.dll'
# The bookmark queue: things to do later, captured mid-task without stopping. Drained into the
# next save (and archived, never deleted) so a queued item survives /clear.
$queuePath = Join-Path $stateDir 'agent-queue.json'

function Move-ToArchive([string]$path) {
  # Archive, never delete: shift existing .NNN archives up by one, then file this as .001.
  $n = 1
  while (Test-Path -LiteralPath ('{0}.{1:D3}' -f $path, $n)) { $n++ }
  for ($i = $n - 1; $i -ge 1; $i--) {
    Move-Item -LiteralPath ('{0}.{1:D3}' -f $path, $i) -Destination ('{0}.{1:D3}' -f $path, ($i + 1)) -Force
  }
  Move-Item -LiteralPath $path -Destination ('{0}.001' -f $path) -Force
}

function Get-Queue {
  if (-not (Test-Path -LiteralPath $queuePath)) { return @() }
  $raw = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  # PS 5.1 returns a JSON array as ONE object; enumerate it so callers get the elements.
  $out = @(); foreach ($e in ($raw | ConvertFrom-Json)) { $out += $e }; return $out
}

function Invoke-ProseCli([string[]]$cliArgs) {
  # Let the native call's own stdout stream through untouched; $LASTEXITCODE is left set by it
  # for the caller to read directly. (Returning it here would also push it onto the output
  # stream, appending a spurious exit-code line after the CLI's real output -- MAT-T41.)
  $project = Join-Path $RepoRoot 'v3\Prose.Cli\Prose.Cli.csproj'
  if (Test-Path -LiteralPath $cliDll) { & dotnet $cliDll @cliArgs }
  elseif (Test-Path -LiteralPath $project) { & dotnet run --project $project -- @cliArgs }
  else { throw "No Prose CLI found under $RepoRoot" }
}

switch ($Command) {
  'bootstrap' {
    $cliArgs = @('agent','bootstrap'); if ($Json) { $cliArgs += '--json' }
    if ($Universe) { $cliArgs = @('--universe',$Universe) + $cliArgs }
    Invoke-ProseCli $cliArgs; exit $LASTEXITCODE
  }
  'save' {
    if ([string]::IsNullOrWhiteSpace($Task) -or [string]::IsNullOrWhiteSpace($Next)) { throw 'save requires -Task and -Next' }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    if (Test-Path -LiteralPath $sessionPath) {
      # Never overwrite: archive the unconsumed prior save first (shift .NNN up, file it as .001).
      $n = 1
      while (Test-Path -LiteralPath ('{0}.{1:D3}' -f $sessionPath, $n)) { $n++ }
      for ($i = $n - 1; $i -ge 1; $i--) {
        Move-Item -LiteralPath ('{0}.{1:D3}' -f $sessionPath, $i) -Destination ('{0}.{1:D3}' -f $sessionPath, ($i + 1)) -Force
      }
      Move-Item -LiteralPath $sessionPath -Destination ('{0}.001' -f $sessionPath) -Force
    }
    $queued = @(Get-Queue)
    $payload = [ordered]@{ protocolVersion='1.1'; updatedAt=[DateTime]::UtcNow.ToString('o'); task=$Task; decisions=([string]$Decisions); state=([string]$State); next=$Next; queued=$queued; universe=$Universe }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sessionPath -Encoding UTF8
    if ($queued.Count -gt 0) { Move-ToArchive $queuePath }
    if ($Json) { $payload | ConvertTo-Json -Depth 8 } else { "Portable MindAttic handoff saved: $sessionPath" }; exit 0
  }
  'load' {
    if (-not (Test-Path -LiteralPath $sessionPath)) { if ($Json) { '{"status":"empty"}' } else { 'No portable MindAttic handoff exists.' }; exit 0 }
    $raw = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8
    if ($Json) { $raw } else {
      $s=$raw|ConvertFrom-Json
      "Task: $($s.task)`nDecisions: $($s.decisions)`nState: $($s.state)`nNext: $($s.next)`nUniverse: $($s.universe)`nUpdated: $($s.updatedAt)"
      foreach ($q in @($s.queued)) { if ($q) { "Queued [$($q.id)] $($q.item)" } }
    }
    if (-not $Keep) {
      # Archive, never delete: shift existing .NNN archives up by one, then file this as .001.
      $n = 1
      while (Test-Path -LiteralPath ('{0}.{1:D3}' -f $sessionPath, $n)) { $n++ }
      for ($i = $n - 1; $i -ge 1; $i--) {
        Move-Item -LiteralPath ('{0}.{1:D3}' -f $sessionPath, $i) -Destination ('{0}.{1:D3}' -f $sessionPath, ($i + 1)) -Force
      }
      Move-Item -LiteralPath $sessionPath -Destination ('{0}.001' -f $sessionPath) -Force
    }
    exit 0
  }
  'do' { & $PSCommandPath load -RepoRoot $RepoRoot -Keep:$Keep -Json:$Json; exit $LASTEXITCODE }
  'queue' {
    # queue -Item "<text>"  add a bookmark · queue -List  show pending · queue -Drain  archive (after a save consumed them)
    $q = @(Get-Queue)
    if (-not [string]::IsNullOrWhiteSpace($Item)) {
      New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
      $next = 1; if ($q.Count -gt 0) { $next = ([int](($q | Measure-Object -Property id -Maximum).Maximum)) + 1 }
      $entry = [ordered]@{ id=$next; addedAt=[DateTime]::UtcNow.ToString('o'); item=$Item }
      $q += [pscustomobject]$entry
      ConvertTo-Json -InputObject @($q) -Depth 6 | Set-Content -LiteralPath $queuePath -Encoding UTF8
      if ($Json) { ConvertTo-Json -InputObject $entry } else { "Queued [$next] $Item  ($($q.Count) pending)" }
      exit 0
    }
    if ($Drain) {
      if ($q.Count -eq 0) { if ($Json) { '{"status":"empty"}' } else { 'Queue already empty.' }; exit 0 }
      Move-ToArchive $queuePath
      if ($Json) { ConvertTo-Json -InputObject @{ drained=$q.Count } } else { "Drained $($q.Count) queued item(s) into the archive." }
      exit 0
    }
    if ($Json) { ConvertTo-Json -InputObject @($q) -Depth 6 } elseif ($q.Count -eq 0) { 'Queue is empty.' } else { foreach ($e in $q) { "[$($e.id)] $($e.item)" } }
    exit 0
  }
  'progress' {
    # Outside Prose, progress means subagent progress (the global /progress); Prose keeps its strand dashboard.
    if ((-not $cliDll -or -not (Test-Path -LiteralPath $cliDll)) -and -not $Universe) {
      $agentArgs=@{}; if ($Json) { $agentArgs.Json=$true }
      & (Join-Path $PSScriptRoot 'agent-progress.ps1') @agentArgs; exit $LASTEXITCODE
    }
    $cliArgs=@('--progress'); if ($Json) {$cliArgs+='--json'}; if($Universe){$cliArgs=@('--universe',$Universe)+$cliArgs}; Invoke-ProseCli $cliArgs; exit $LASTEXITCODE
  }
  'show' {
    if ([string]::IsNullOrWhiteSpace($Subject)) { throw 'show requires -Subject' }; $cliArgs=@('--show','--subject',$Subject); if($Aspect){$cliArgs+=@('--aspect',$Aspect)}; if($Json){$cliArgs+='--json'}; if($Universe){$cliArgs=@('--universe',$Universe)+$cliArgs}; Invoke-ProseCli $cliArgs; exit $LASTEXITCODE
  }
}
