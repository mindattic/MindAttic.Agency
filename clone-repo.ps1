[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,            # "owner/name" or bare "name" (owner defaults to $Owner)
  [string]$Owner = 'mindattic',
  [string]$WorkspaceRoot,
  [string]$Topic = 'wip',
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
$existing = @(gh api "repos/$fullName/topics" --jq '.names[]' 2>$null)
$topics = @($existing + $Topic | Select-Object -Unique)
$namesArgs = $topics | ForEach-Object { @('-f', "names[]=$_") }
gh api -X PUT "repos/$fullName/topics" @namesArgs | Out-Null
Write-Output "tagged $fullName with: $($topics -join ', ')"

# D) - restart any open Launcher *program* instance so its roster (and Discover Projects)
# picks the new repo up. A 'host ...'/'commit ...'/etc. CLI instance is a live agent tab and is
# left alone; only a bare no-argument invocation (the interactive menu) is restarted.
if (-not $NoRestartLauncher) {
  $exe = 'C:\Apps\MindAttic.Launcher\MindAttic.Launcher.exe'
  $menus = @(Get-CimInstance Win32_Process -Filter "Name='MindAttic.Launcher.exe'" | Where-Object {
    $rest = $_.CommandLine -replace '^\s*"[^"]+"\s*', '' -replace '^\s*\S+\s*', ''
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
