[CmdletBinding()]
param([string]$WorkspaceRoot,[string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",[string]$OutputPath)
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot 'command-catalog.json' }
$items = [System.Collections.Generic.List[object]]::new()
function Add-File([string]$scope,[string]$project,[string]$kind,[string]$path,[string]$name) {
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $base = ([IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\') + '\')
    $full = [IO.Path]::GetFullPath($path)
    $rel = if ($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { $full.Substring($base.Length) } else { $full }
    if ([string]::IsNullOrEmpty($name)) { $name = [IO.Path]::GetFileNameWithoutExtension($path) }
    $items.Add([ordered]@{scope=$scope;project=$project;kind=$kind;name=$name;path=$rel})
  }
}
# Exclude by full path, not just each folder's own leaf name: checking only $_.Name let -Recurse
# still catalog vendored content *under* an excluded folder as its own "project" (e.g. a Unity
# package under Library\PackageCache\com.unity.timeline@.../.claude\skills\... was filed as
# project "com.unity.timeline@..." - MAT-T44). genericize-instructions.ps1 already excludes this
# way; match it here.
$excludedDirPattern = '\\(node_modules|PackageCache|\.git|\.vs|_dropbox|mindattic-agent-standard|codex-standard)(\\|$)'
$dirs = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch $excludedDirPattern -and ((Test-Path (Join-Path $_.FullName '.git')) -or (Test-Path (Join-Path $_.FullName '.claude'))) }
foreach($d in $dirs) {
  foreach($f in Get-ChildItem (Join-Path $d.FullName '.claude\commands') -File -ErrorAction SilentlyContinue){ Add-File 'project' $d.Name 'command' $f.FullName }
  $skillsRoot = Join-Path $d.FullName '.claude\skills'
  foreach($f in Get-ChildItem $skillsRoot -File -Recurse -ErrorAction SilentlyContinue){
    # Every skill file is named SKILL.md, so the file's own basename never distinguishes one
    # skill from another; the skill's real name is its containing folder, one level under
    # .claude\skills\ (MAT-T42).
    $skillsBase = ([IO.Path]::GetFullPath($skillsRoot).TrimEnd('\') + '\')
    $skillRel = ([IO.Path]::GetFullPath($f.FullName)).Substring($skillsBase.Length)
    $skillName = $skillRel.Split([IO.Path]::DirectorySeparatorChar)[0]
    Add-File 'project' $d.Name 'skill' $f.FullName $skillName
  }
  foreach($f in Get-ChildItem (Join-Path $d.FullName '.claude\hooks') -File -ErrorAction SilentlyContinue){ Add-File 'project' $d.Name 'hook' $f.FullName }
  Add-File 'project' $d.Name 'instructions' (Join-Path $d.FullName 'CLAUDE.md')
}
foreach($f in Get-ChildItem (Join-Path $GlobalClaudeRoot 'commands') -File -ErrorAction SilentlyContinue){ Add-File 'global' 'global' 'command' $f.FullName }
Add-File 'global' 'global' 'instructions' (Join-Path $GlobalClaudeRoot 'CLAUDE.md')
$doc = [ordered]@{standard='MindAttic Agent Standard';protocolVersion='1.0';generatedAt=(Get-Date).ToUniversalTime().ToString('o');items=$items}
$doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "wrote $($items.Count) entries to $OutputPath"
