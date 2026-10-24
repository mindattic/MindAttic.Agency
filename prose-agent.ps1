[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('bootstrap','save','load','do','progress','show','queue','handoffs')]
  [string]$Command = 'bootstrap',
  # load <code>: load that exact handoff from the shared registry instead of this repo's latest save.
  [Parameter(Position=1)]
  [string]$Code,
  [string]$RepoRoot,
  # Where shareable handoffs live. Every login on this machine (each Claude account is its own config
  # dir, but the same Windows user) reads and writes the same registry, so a code saved in one login's
  # CLI loads in any other. Override with -RegistryRoot or $env:MINDATTIC_HANDOFF_REGISTRY.
  [string]$RegistryRoot,
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

# ---- Shareable handoff codes (MAT-T40) ----------------------------------------------------------
# Each save also gets a short memorable code (adjective-animal, e.g. 'lively-oxen') and is recorded
# in the registry as <registry>\<code>.json. A code file sitting in the registry root is unconsumed;
# loading it moves it to <registry>\consumed\ (archived, never deleted), which frees the code for reuse.
if ([string]::IsNullOrWhiteSpace($RegistryRoot)) { $RegistryRoot = $env:MINDATTIC_HANDOFF_REGISTRY }
if ([string]::IsNullOrWhiteSpace($RegistryRoot)) { $RegistryRoot = Join-Path $env:LOCALAPPDATA 'MindAttic\handoffs' }
$consumedDir = Join-Path $RegistryRoot 'consumed'
$codePattern = '^[a-z]+-[a-z]+$'

function Get-WordList([string]$name) {
  $path = Join-Path $PSScriptRoot "shared\handoff-words\$name.txt"
  @(Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -match '^[a-z]+$' } | Select-Object -Unique)
}

function Get-RepoInfo([string]$root) {
  # Which repo and (if any) which worktree the save was made in, so a loader in another folder or
  # another login knows exactly where the work lives.
  $info = [ordered]@{ name = (Split-Path -Leaf $root); path = $root; worktree = $false; mainRepo = $root; branch = $null }
  try {
    $gitDir = (& git -C $root rev-parse --path-format=absolute --git-dir 2>$null)
    $common = (& git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null)
    $branch = (& git -C $root rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitDir -and $common) {
      $info.branch = [string]$branch
      $gitDirFull = [IO.Path]::GetFullPath($gitDir).TrimEnd('\','/')
      $commonFull = [IO.Path]::GetFullPath($common).TrimEnd('\','/')
      if ($gitDirFull -ne $commonFull) {
        $info.worktree = $true
        $info.mainRepo = Split-Path -Parent $commonFull
        $info.name = Split-Path -Leaf $info.mainRepo
      }
    }
  } catch { }
  return $info
}

function New-HandoffCode([hashtable]$entryBase) {
  # Picks a random adjective-animal code and claims it atomically (CreateNew), regenerating on any
  # collision with an unconsumed code, so two CLIs saving at once can never share a code.
  # @() at the call site too: a function's one-element array comes back as a bare string.
  $adjectives = @(Get-WordList 'adjectives'); $animals = @(Get-WordList 'animals')
  if ($adjectives.Count -eq 0 -or $animals.Count -eq 0) { throw 'Handoff word lists are missing or empty.' }
  New-Item -ItemType Directory -Path $RegistryRoot -Force | Out-Null
  $rng = New-Object System.Random
  $capacity = $adjectives.Count * $animals.Count
  for ($attempt = 0; $attempt -lt [Math]::Max(200, 4 * $capacity); $attempt++) {
    $candidate = '{0}-{1}' -f $adjectives[$rng.Next($adjectives.Count)], $animals[$rng.Next($animals.Count)]
    $path = Join-Path $RegistryRoot "$candidate.json"
    if (Test-Path -LiteralPath $path) { continue }
    $entry = [ordered]@{ code = $candidate }; foreach ($k in $entryBase.Keys) { $entry[$k] = $entryBase[$k] }
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($entry | ConvertTo-Json -Depth 8))
    try { $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { if (Test-Path -LiteralPath $path) { continue } else { throw } }
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    return $candidate
  }
  throw "No free handoff code left in $RegistryRoot ($capacity possible); load or archive some handoffs first."
}

function Complete-HandoffCode([string]$codeToConsume) {
  # Consume: stamp consumedAt and file it under consumed\ (never deleted), freeing the code.
  $path = Join-Path $RegistryRoot "$codeToConsume.json"
  if (-not (Test-Path -LiteralPath $path)) { return }
  $e = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $e | Add-Member -NotePropertyName consumedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  New-Item -ItemType Directory -Path $consumedDir -Force | Out-Null
  $dest = Join-Path $consumedDir ('{0}.{1}.json' -f $codeToConsume, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
  [IO.File]::WriteAllText($dest, ($e | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
  Remove-Item -LiteralPath $path
}

function Format-Handoff($s) {
  if ($s.code) { "Code: $($s.code)" }
  if ($s.repo) {
    $where = "Repo: $($s.repo.name) ($($s.repo.path))"
    if ($s.repo.worktree) { $where += " [worktree of $($s.repo.mainRepo), branch $($s.repo.branch)]" }
    elseif ($s.repo.branch) { $where += " [branch $($s.repo.branch)]" }
    $where
  }
  if ($s.savedBy) { "Saved by: $($s.savedBy)" }
  "Task: $($s.task)`nDecisions: $($s.decisions)`nState: $($s.state)`nNext: $($s.next)`nUniverse: $($s.universe)`nUpdated: $($s.updatedAt)"
  foreach ($q in @($s.queued)) { if ($q) { "Queued [$($q.id)] $($q.item)" } }
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
    $savedBy = if ($env:CLAUDE_CONFIG_DIR) { Split-Path -Leaf $env:CLAUDE_CONFIG_DIR } else { $env:USERNAME }
    $updatedAt = [DateTime]::UtcNow.ToString('o')
    $repoInfo = Get-RepoInfo $RepoRoot
    # Claim the shareable code first (it's written into the registry atomically), then record the
    # same handoff, code included, as this repo's local save.
    $registered = [ordered]@{ protocolVersion='1.2'; updatedAt=$updatedAt; savedBy=$savedBy; repo=$repoInfo; task=$Task; decisions=([string]$Decisions); state=([string]$State); next=$Next; queued=$queued; universe=$Universe }
    $newCode = New-HandoffCode $registered
    $payload = [ordered]@{ protocolVersion='1.2'; code=$newCode; updatedAt=$updatedAt; savedBy=$savedBy; repo=$repoInfo; task=$Task; decisions=([string]$Decisions); state=([string]$State); next=$Next; queued=$queued; universe=$Universe }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sessionPath -Encoding UTF8
    if ($queued.Count -gt 0) { Move-ToArchive $queuePath }
    if ($Json) { $payload | ConvertTo-Json -Depth 8 } else { "Portable MindAttic handoff saved: $sessionPath`nHandoff code: $newCode  (quickload $newCode from any login's CLI)" }; exit 0
  }
  'load' {
    if (-not [string]::IsNullOrWhiteSpace($Code)) {
      # load <code>: that exact handoff from the shared registry, wherever and by whichever login it was saved.
      $Code = $Code.Trim().ToLowerInvariant()
      if ($Code -notmatch $codePattern) { throw "'$Code' is not a handoff code (expected adjective-animal, e.g. lively-oxen)." }
      $entryPath = Join-Path $RegistryRoot "$Code.json"
      $consumedNote = $null
      if (-not (Test-Path -LiteralPath $entryPath)) {
        # Already loaded once: recall its most recent consumed copy read-only rather than failing.
        $old = Get-ChildItem -LiteralPath $consumedDir -Filter "$Code.*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $old) {
          if ($Json) { ConvertTo-Json -InputObject ([ordered]@{ status='unknown'; code=$Code }) } else { "No handoff with code '$Code' exists in $RegistryRoot." }
          exit 1
        }
        $entryPath = $old.FullName
        $consumedNote = "Note: '$Code' was already loaded (consumed) before; this is that same handoff, recalled read-only."
      }
      $raw = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
      $s = $raw | ConvertFrom-Json
      if ($Json) { $raw } else { if ($consumedNote) { $consumedNote }; Format-Handoff $s }
      if (-not $Keep -and -not $consumedNote) {
        Complete-HandoffCode $Code
        # If this repo's own live save is the same handoff, it's consumed too (archived, as a local load does).
        if (Test-Path -LiteralPath $sessionPath) {
          $local = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
          if ($local.code -eq $Code) { Move-ToArchive $sessionPath }
        }
      }
      exit 0
    }
    if (-not (Test-Path -LiteralPath $sessionPath)) { if ($Json) { '{"status":"empty"}' } else { 'No portable MindAttic handoff exists.' }; exit 0 }
    $raw = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8
    $s=$raw|ConvertFrom-Json
    if ($Json) { $raw } else { Format-Handoff $s }
    if (-not $Keep) {
      # Loading the local save also consumes its shareable code, freeing it for reuse.
      if ($s.code -and ([string]$s.code) -match $codePattern) { Complete-HandoffCode ([string]$s.code) }
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
  'do' { & $PSCommandPath load -Code $Code -RepoRoot $RepoRoot -RegistryRoot $RegistryRoot -Keep:$Keep -Json:$Json; exit $LASTEXITCODE }
  'handoffs' {
    # Every unconsumed shareable handoff in the registry, newest first.
    $rows = @(Get-ChildItem -LiteralPath $RegistryRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.BaseName -match $codePattern } |
      ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
      Sort-Object updatedAt -Descending)
    if ($Json) { ConvertTo-Json -InputObject $rows -Depth 8 }
    elseif ($rows.Count -eq 0) { "No unconsumed handoffs in $RegistryRoot." }
    else { foreach ($r in $rows) { '{0,-22} {1,-28} {2}  {3}' -f $r.code, $r.repo.name, $r.updatedAt, $r.task } }
    exit 0
  }
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
