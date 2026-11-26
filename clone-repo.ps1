[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,            # "owner/name" or bare "name" (owner defaults to $Owner)
  [string]$Owner = 'mindattic',
  [string]$WorkspaceRoot,
  [string]$Topic = 'wip',
  [ValidateSet('library','app','unity','unreal','site','mod','hardware')][string]$Kind,   # recorded in docs\workspace-repos.json; derived from the clone when omitted
  [switch]$NoRestartLauncher
)

<#
.SYNOPSIS
The one way a new repo joins the workspace: clone it, tag it, make the Launcher see it.

.DESCRIPTION
mindattic-agent-standard rule - run this (never a bare "git clone") whenever a new repo is
added to the workspace, by an agent or by hand:
  A) create the destination folder
  B) clone the repo into it
  C) tag the repo 'wip' on GitHub (the lever MindAttic.Launcher's TopicRepoSync filters its
     roster by - see MindAttic.Launcher/Services/TopicRepoSync.cs)
  D) restart any open MindAttic.Launcher *program* instance (the bare interactive menu - a
     process with no subcommand), never a 'host'/'commit'/'backup'/'restore'/'bootstrap'/
     'version' CLI instance, since those are per-tab agent sessions mid-use

A fresh restart re-runs DiscoverProjectsMenu, which offers to register the newly-tagged repo
into settings.json interactively (tab color, description) the next time someone looks at the
menu. This script doesn't answer that wizard for you.
#>

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')

if ($Repo -match '/') { $fullName = $Repo } else { $fullName = "$Owner/$Repo" }
$name = $fullName.Substring($fullName.LastIndexOf('/') + 1)
$target = Join-Path $WorkspaceRoot $name

# A) + B) - create the folder and clone into it. "git clone" creates the leaf directory itself;
# only the parent (the workspace root) needs to already exist. A repo already on disk (e.g. one
# that only needs tagging/re-registering) skips straight to C) and D) instead of failing.
if (Test-Path -LiteralPath $target) {
  Write-Output "$target already exists - skipping clone, still tagging and restarting."
} else {
  New-Item -ItemType Directory -Path $WorkspaceRoot -Force | Out-Null
  git clone --recurse-submodules "https://github.com/$fullName.git" $target
  if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }
}

# C) - tag it on GitHub, merged with whatever topics it already carries (a template repo may
# ship with some). This is the only lever MindAttic.Launcher's roster filter reads.
# Both gh calls' exit codes are checked: a failed read must not be treated as "no existing
# topics" (that would make the PUT below wipe them), and a failed write must not be reported as
# success (MAT-T43).
$existing = @(gh api "repos/$fullName/topics" --jq '.names[]' 2>$null)
if ($LASTEXITCODE -ne 0) { throw "gh api repos/$fullName/topics failed (exit $LASTEXITCODE); refusing to guess its existing topics." }
$topics = @($existing + $Topic | Select-Object -Unique)
$namesArgs = $topics | ForEach-Object { @('-f', "names[]=$_") }
gh api -X PUT "repos/$fullName/topics" @namesArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "gh api -X PUT repos/$fullName/topics failed (exit $LASTEXITCODE)." }
Write-Output "tagged $fullName with: $($topics -join ', ')"

# E) - record the repo in the workspace manifest (docs\workspace-repos.json) with its Kind, so
# tooling (publish-app.ps1 -All, the deploy rollout) never re-derives kind by heuristic. Kind is
# -Kind when given, else the repo's existing entry, else derived from what is on disk.
$manifest = Join-Path $WorkspaceRoot 'docs\workspace-repos.json'
if (Test-Path -LiteralPath $manifest) {
  if (-not $Kind) {
    if (Test-Path -LiteralPath (Join-Path $target 'ProjectSettings\ProjectVersion.txt')) { $Kind = 'unity' }
    elseif (Get-ChildItem -LiteralPath $target -Filter *.uproject -ErrorAction SilentlyContinue) { $Kind = 'unreal' }
    elseif ((Test-Path -LiteralPath (Join-Path $target 'nexus.json')) -or (Test-Path -LiteralPath (Join-Path $target 'thunderstore.toml'))) { $Kind = 'mod' }
    elseif (Test-Path -LiteralPath (Join-Path $target 'index.htm')) { $Kind = 'site' }
    elseif (Get-ChildItem -LiteralPath $target -Recurse -Depth 3 -Filter *.csproj -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Test' -and (Select-String -LiteralPath $_.FullName -Quiet -Pattern '<OutputType>\s*(Win)?Exe|Sdk="Microsoft\.NET\.Sdk\.Web') }) { $Kind = 'app' }
    else { $Kind = 'library' }
  }
  $raw = [IO.File]::ReadAllText($manifest)
  $bom = $raw.StartsWith([string][char]0xFEFF)
  $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $esc = [regex]::Escape($name)
  if ($raw -match "(?s)`"Name`": `"$esc`",\s*`"Remote`": `"[^`"]*`"(,\s*`"Kind`": `"[^`"]*`")?") {
    $raw = [regex]::Replace($raw, "(?s)(`"Name`": `"$esc`",(\s*)`"Remote`": `"[^`"]*`")(,\s*`"Kind`": `"[^`"]*`")?", {
      param($m) "$($m.Groups[1].Value),$($m.Groups[2].Value)`"Kind`": `"$Kind`"" })
  } else {
    $entry = "    {$nl      `"Name`": `"$name`",$nl      `"Remote`": `"https://github.com/$fullName.git`",$nl      `"Kind`": `"$Kind`"$nl    }"
    $raw = [regex]::Replace($raw, "(?s)\s*\]\s*\}\s*$", { param($m) ",$nl$entry$nl  ]$nl}$nl" })
  }
  [IO.File]::WriteAllText($manifest, $raw, (New-Object Text.UTF8Encoding($bom)))
  Write-Output "recorded $name in docs\workspace-repos.json as Kind=$Kind"
}
# D) - restart any open Launcher *program* instance so its roster (and Discover Projects)
# picks the new repo up. A 'host ...'/'commit ...'/etc. CLI instance is a live agent tab and is
# left alone; only a bare no-argument invocation (the interactive menu) is restarted.
if (-not $NoRestartLauncher) {
  $exe = 'R:\MindAttic\Apps\MindAttic.Launcher\Release\MindAttic.Launcher.exe'
  $menus = @(Get-CimInstance Win32_Process -Filter "Name='MindAttic.Launcher.exe'" | Where-Object {
    # Strip exactly the exe token (quoted or not) in one pass. Two chained -replace calls here
    # would strip the exe AND the first argument when the exe path was quoted, so a bare one-word
    # subcommand with no further args (e.g. "... .exe" version) would wrongly look argument-less
    # and get killed as if it were the menu (MAT-T77, ported from the workspace mirror).
    # A $null CommandLine (an elevated process we can't read) is unknown, not argument-less: leave it alone.
    if ($null -eq $_.CommandLine) { return $false }
    $rest = $_.CommandLine -replace '^\s*(?:"[^"]+"|\S+)\s*', ''
    [string]::IsNullOrWhiteSpace($rest)
  })

  if ($menus) {
    foreach ($p in $menus) {
      Stop-Process -Id $p.ProcessId -Force
      if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
    }
    Write-Output "restarted $($menus.Count) Launcher menu instance(s)"
  } else {
    Write-Output 'no open Launcher menu instance found to restart (host/commit/etc. tabs are left alone)'
  }
}
