[CmdletBinding()]
param([string]$WorkspaceRoot,[string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",[string]$KimiHome = "$env:USERPROFILE\.kimi-code",[string]$AgyHome = "$env:USERPROFILE\.agy",[string]$OutputPath)
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
    $entry = [ordered]@{scope=$scope;project=$project;kind=$kind;name=$name;path=$rel}
    # MAT-T95: a 'global'+'command' item that a shared/abilities/<...>.md source renders also
    # records that source and which target CLIs it was actually rendered for (see $abilities below).
    if ($scope -eq 'global' -and $kind -eq 'command' -and $abilityByCommandName.Contains($name)) {
      $a = $abilityByCommandName[$name]
      $entry['portableSource'] = $a.Source
      $entry['renderedFor'] = $a.RenderedFor
      if ($a.ClaudeOnly) { $entry['claudeOnly'] = $true }
    }
    $items.Add($entry)
  }
}

# ── MAT-T95: shared/abilities/*.md is the one portable-ability source; work out, for each one,
# the command name(s) it renders to and which target CLIs it actually landed in on this machine. ──
function Read-AbilityMeta([System.IO.FileInfo]$File) {
  $text = [IO.File]::ReadAllText($File.FullName)
  $name = $File.BaseName
  $claudeOnly = $false
  $aliases = @()
  $template = $false
  if ($text -match '(?m)^claude-only:\s*true\s*$') { $claudeOnly = $true }
  if ($text -match '(?m)^template:\s*true\s*$') { $template = $true }
  if ($text -match '(?m)^aliases:\s*\[(.*?)\]\s*$') {
    $aliases = @($Matches[1] -split ',\s*' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
  }
  [pscustomobject]@{ Name = $name; ClaudeOnly = $claudeOnly; Aliases = $aliases; Template = $template; File = $File }
}

$abilitiesDir = Join-Path $PSScriptRoot 'shared\abilities'
$codexCatalogPath = Join-Path $PSScriptRoot 'shared\codex-command-catalog.md'
$codexCatalogExists = Test-Path -LiteralPath $codexCatalogPath -PathType Leaf
$abilityByCommandName = @{}
$abilitiesList = [System.Collections.Generic.List[object]]::new()
foreach ($af in (Get-ChildItem -LiteralPath $abilitiesDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
  $m = Read-AbilityMeta $af
  $base = ([IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\') + '\')
  $srcFull = [IO.Path]::GetFullPath($af.FullName)
  $srcRel = if ($srcFull.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { $srcFull.Substring($base.Length) } else { $srcFull }

  $renderedFor = [System.Collections.Generic.List[string]]::new()
  if ($m.Template) {
    # member-contact: not a literal file - rendered by shared/member-commands.ps1 for Claude only.
    $renderedFor.Add('claude (via shared/member-commands.ps1)')
  } else {
    foreach ($n in (@($m.Name) + @($m.Aliases))) {
      if (Test-Path -LiteralPath (Join-Path $GlobalClaudeRoot "commands\$n.md")) { $renderedFor.Add('claude') ; break }
    }
    if (-not $m.ClaudeOnly) {
      if ($codexCatalogExists) { $renderedFor.Add('codex (shared/codex-command-catalog.md)') }
      if (Test-Path -LiteralPath (Join-Path $KimiHome "skills\$($m.Name)\SKILL.md")) { $renderedFor.Add('kimi') }
    }
    if (Test-Path -LiteralPath $AgyHome) {
      # agy's own confirmed command/skill convention isn't wired up yet (MAT-T96) - never claimed here.
    }
  }
  $renderedFor = @($renderedFor | Select-Object -Unique)

  foreach ($n in (@($m.Name) + @($m.Aliases))) {
    $abilityByCommandName[$n] = [pscustomobject]@{ Source = $srcRel; RenderedFor = $renderedFor; ClaudeOnly = $m.ClaudeOnly }
  }
  $abilitiesList.Add([ordered]@{ name=$m.Name; aliases=@($m.Aliases); source=$srcRel; claudeOnly=$m.ClaudeOnly; renderedFor=$renderedFor })
}
# Exclude by full path, not just each folder's own leaf name: checking only $_.Name let -Recurse
# still catalog vendored content *under* an excluded folder as its own "project" (e.g. a Unity
# package under Library\PackageCache\com.unity.timeline@.../.claude\skills\... was filed as
# project "com.unity.timeline@..." - MAT-T44). genericize-instructions.ps1 already excludes this
# way; match it here.
$excludedDirPattern = '\\(node_modules|PackageCache|\.git|\.vs|_dropbox|mindattic-agent-standard|codex-standard)(\\|$)'
$dirs = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object {
    $_.FullName -notmatch $excludedDirPattern -and
    # A linked git worktree (agent scratch checkout under .claude\worktrees, or a ticket worktree
    # sitting next to its repo) has its own .git *file* pointing at the real repo's worktrees
    # folder, not a .git directory; it disappears once its agent finishes, so cataloging it as its
    # own "project" makes every regeneration noisy and points at paths that won't exist tomorrow.
    -not (Test-Path (Join-Path $_.FullName '.git') -PathType Leaf) -and
    ((Test-Path (Join-Path $_.FullName '.git')) -or (Test-Path (Join-Path $_.FullName '.claude')))
  }
foreach($d in $dirs) {
  foreach($f in Get-ChildItem (Join-Path $d.FullName '.claude\commands') -File -ErrorAction SilentlyContinue){ Add-File 'project' $d.Name 'command' $f.FullName }
  $skillsRoot = Join-Path $d.FullName '.claude\skills'
  foreach($f in Get-ChildItem $skillsRoot -File -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue){
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
$doc = [ordered]@{standard='MindAttic Agent Standard';protocolVersion='1.0';generatedAt=(Get-Date).ToUniversalTime().ToString('o');items=$items;abilities=$abilitiesList}
$doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "wrote $($items.Count) entries to $OutputPath"
