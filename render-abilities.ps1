#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the portable ability catalog (shared/abilities/*.md) into every CLI's own native
    command/skill convention (MAT-T95, a child of MAT-T93).

.DESCRIPTION
    shared/abilities/*.md is now the one source of truth for MindAttic's portable slash
    commands ("abilities"): plain Markdown with minimal YAML-ish frontmatter (name, description,
    argument-hint, claude-only true|false, optional aliases, and Claude-only passthrough fields
    for things that must round-trip exactly - claude-allowed-tools, claude-disable-model-invocation,
    claude-no-frontmatter). shared/commands/*.md is now a RENDER TARGET for Claude, not a source:
    don't hand-edit it any more - edit shared/abilities/*.md and re-run this script.

    What gets rendered where, and why:

    - Claude (always - it is every ability's one real, working home, claude-only or not):
      writes shared/commands/<name>.md (and one copy per alias) in Claude's own frontmatter
      shape, then copies any that changed into $GlobalClaudeRoot\commands - MD5-compared and
      backed up first, the same approach share-scripts.ps1 already uses for the handful of files
      it manages. The `member-contact` ability is templated, not a literal file: it is rendered
      by the existing shared\member-commands.ps1 generator (unchanged), which this script just
      makes sure still runs.

    - Codex: as of this writing, no custom prompts/commands directory is confirmed for Codex CLI
      (checked empirically: `codex --help` and `codex mcp --help` list no such option; Codex's
      own extensibility is a plugin marketplace (`codex plugin ...`), not a markdown-prompt
      folder; $CODEX_HOME\skills exists but holds only an internal `.system` cache, no
      user-authored skill content; `codex features list` shows `plugins`/`plugin_sharing` as the
      stable extensibility surface, nothing named for custom prompts). Codex DOES read AGENTS.md
      natively and DOES support PreToolUse/Stop hooks ($CODEX_HOME\hooks.json, wired by MAT-T94).
      So, per the ticket's own instructed fallback, portable (non claude-only) abilities are
      rendered into one generated file, shared\codex-command-catalog.md, with plain-English
      dispatch instructions; claude-only abilities are listed too, marked unavailable. This
      script does NOT edit AGENTS.md (MAT-T95 leaves that pointer for a later pass) - add one
      line to it by hand once: "Codex: shared/codex-command-catalog.md is the command catalog."

    - Kimi: confirmed via Kimi's own docs (https://moonshotai.github.io/kimi-code/, Customization
      > Skills) that it auto-discovers user-level skills at $KIMI_CODE_HOME\skills (defaults to
      ~/.kimi-code/skills) and ~/.agents/skills, directory-per-skill with a SKILL.md whose
      frontmatter requires name + description - the same shape Claude's own Skill tool uses.
      Portable abilities are rendered to ~/.kimi-code/skills/<name>/SKILL.md; claude-only
      abilities are skipped (they would not function there). UNVERIFIED: whether a Kimi skill's
      body receives `$ARGUMENTS` the same way a Claude slash command does - Kimi's docs describe
      skills as invoked by the model "on demand" from their description, not necessarily via an
      explicit `/name args` the way Claude commands are. Treat the `$ARGUMENTS` placeholders in
      the rendered bodies as an assumption carried over from the Claude source, not a confirmed
      Kimi mechanism.

    - agy: MAT-T96 is bootstrapping agy's config directory concurrently; it does not exist on
      this machine yet. This script checks for $AgyHome and no-ops cleanly with a note when it's
      missing, rather than erroring. TODO (MAT-T96): once ~/.agy (or wherever its config lands)
      exists, confirm its REAL command/skill convention before extending the agy branch below -
      agy.exe's own strings reference AGENTS.md/hooks.json/settings.json, suggesting high overlap
      with Claude's conventions, but that is an assumption, not something this script has
      verified against an actual agy config directory.

.PARAMETER WorkspaceRoot
    The MindAttic workspace root. Defaults to this script's own parent's parent, same convention
    install.ps1/share-scripts.ps1 use.

.PARAMETER GlobalClaudeRoot
    Claude Code's global config folder. Defaults to ~/.claude.

.PARAMETER KimiHome
    Kimi Code's config folder ($KIMI_CODE_HOME). Defaults to ~/.kimi-code. Rendering into it
    no-ops (with a message) if this folder doesn't exist.

.PARAMETER AgyHome
    agy's config folder. Defaults to ~/.agy. Rendering into it no-ops (with a message) until
    MAT-T96 creates this folder and its real shape is confirmed.

.PARAMETER WhatIf
    Report what would change; change nothing.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",
    [string]$KimiHome = "$env:USERPROFILE\.kimi-code",
    [string]$AgyHome = "$env:USERPROFILE\.agy",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$abilitiesDir = Join-Path $PSScriptRoot 'shared\abilities'
$commandsDir = Join-Path $PSScriptRoot 'shared\commands'
$utf8 = New-Object System.Text.UTF8Encoding $false
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-Md5([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLowerInvariant() }

# ── Parse a shared/abilities/<name>.md file into a structured object ────────────────────────────
# Not full YAML - just enough for this flat, one-value-per-line frontmatter shape.
function Read-Ability {
    param([System.IO.FileInfo]$File)
    $text = [IO.File]::ReadAllText($File.FullName)
    if ($text -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$') {
        throw "ability file has no frontmatter: $($File.FullName)"
    }
    $fmText = $Matches[1]
    $body = $Matches[2] -replace '^(\r?\n)+', ''
    $fm = [ordered]@{}
    foreach ($line in ($fmText -split '\r?\n')) {
        if ($line -notmatch '^([A-Za-z0-9_-]+):\s*(.*)$') { continue }
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($val -match '^\[(.*)\]$') {
            $fm[$key] = @($Matches[1] -split ',\s*' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
        } elseif ($val -match '^"(.*)"$') {
            $fm[$key] = $Matches[1]
        } else {
            $fm[$key] = $val
        }
    }
    [pscustomobject]@{
        File                         = $File
        Name                         = [string]$fm['name']
        Description                  = [string]$fm['description']
        ArgumentHint                 = if ($fm.Contains('argument-hint')) { [string]$fm['argument-hint'] } else { $null }
        ClaudeOnly                   = ("$($fm['claude-only'])" -eq 'true')
        ClaudeOnlyReason             = if ($fm.Contains('claude-only-reason')) { [string]$fm['claude-only-reason'] } else { 'depends on a Claude-only mechanism' }
        Aliases                      = if ($fm.Contains('aliases')) { @($fm['aliases']) } else { @() }
        ClaudeAllowedTools           = if ($fm.Contains('claude-allowed-tools')) { [string]$fm['claude-allowed-tools'] } else { $null }
        ClaudeDisableModelInvocation = ("$($fm['claude-disable-model-invocation'])" -eq 'true')
        ClaudeNoFrontmatter          = ("$($fm['claude-no-frontmatter'])" -eq 'true')
        Template                     = ("$($fm['template'])" -eq 'true')
        Body                         = $body
    }
}

$abilities = @(Get-ChildItem -LiteralPath $abilitiesDir -Filter '*.md' -File | ForEach-Object { Read-Ability -File $_ } | Sort-Object Name)
Write-Output "render-abilities: read $($abilities.Count) abilities from $abilitiesDir"

# =================================================================================================
# Claude: regenerate shared/commands/<name>.md (and one per alias), then sync into ~/.claude/commands
# =================================================================================================
function Format-ClaudeFrontmatterValue([string]$value) {
    if ($value -match '[:#]' -or $value.StartsWith('"') -or $value.StartsWith('[')) {
        return '"' + ($value -replace '"', '\"') + '"'
    }
    return $value
}

function Format-ClaudeCommand($Ability) {
    if ($Ability.ClaudeNoFrontmatter) { return $Ability.Body.TrimEnd() + "`n" }
    $fm = [System.Collections.Generic.List[string]]::new()
    $fm.Add('---')
    $fm.Add("description: $(Format-ClaudeFrontmatterValue $Ability.Description)")
    if ($null -ne $Ability.ArgumentHint) { $fm.Add('argument-hint: "' + ($Ability.ArgumentHint -replace '"', '\"') + '"') }
    if ($Ability.ClaudeAllowedTools) { $fm.Add("allowed-tools: $($Ability.ClaudeAllowedTools)") }
    if ($Ability.ClaudeDisableModelInvocation) { $fm.Add('disable-model-invocation: true') }
    $fm.Add('---')
    return ($fm -join "`n") + "`n`n" + $Ability.Body.TrimEnd() + "`n"
}

New-Item -ItemType Directory -Force -Path $commandsDir | Out-Null
$renderedNames = [System.Collections.Generic.List[string]]::new()
foreach ($a in ($abilities | Where-Object { -not $_.Template })) {
    $content = Format-ClaudeCommand $a
    foreach ($n in (@($a.Name) + @($a.Aliases))) {
        $dest = Join-Path $commandsDir "$n.md"
        $renderedNames.Add($n)
        if ((Test-Path -LiteralPath $dest) -and ([IO.File]::ReadAllText($dest) -eq $content)) { continue }
        Write-Output "claude: shared/commands/$n.md <- shared/abilities/$($a.Name).md"
        if (-not $WhatIf) { [IO.File]::WriteAllText($dest, $content, $utf8) }
    }
}
foreach ($f in Get-ChildItem -LiteralPath $commandsDir -Filter '*.md' -File -ErrorAction SilentlyContinue) {
    if ($renderedNames -contains $f.BaseName) { continue }
    Write-Output "claude: shared/commands/$($f.Name) is no longer produced by any ability - left alone (remove by hand if stale)"
}

# Deploy shared/commands/*.md into $GlobalClaudeRoot\commands: MD5-compare, back up a changed file
# before overwriting it, same approach share-scripts.ps1 already uses for the scripts it manages.
$globalCommands = Join-Path $GlobalClaudeRoot 'commands'
New-Item -ItemType Directory -Force -Path $globalCommands | Out-Null
foreach ($cmd in Get-ChildItem -LiteralPath $commandsDir -Filter '*.md' -File) {
    $dest = Join-Path $globalCommands $cmd.Name
    if ((Test-Path -LiteralPath $dest) -and (Get-Md5 $dest) -eq (Get-Md5 $cmd.FullName)) { continue }
    Write-Output "claude: ~/.claude/commands/$($cmd.Name) <- $($cmd.FullName)"
    if ($WhatIf) { continue }
    if (Test-Path -LiteralPath $dest) {
        $backup = Join-Path $env:LOCALAPPDATA "MindAttic\render-abilities-backup\$stamp\claude\commands"
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Copy-Item -LiteralPath $dest -Destination (Join-Path $backup $cmd.Name)
    }
    Copy-Item -LiteralPath $cmd.FullName -Destination $dest -Force
}

# member-contact is templated, not a literal file - keep using the existing generator as-is.
if (@($abilities | Where-Object { $_.Template }).Count -gt 0) {
    $memberScript = Join-Path $PSScriptRoot 'shared\member-commands.ps1'
    if (Test-Path -LiteralPath $memberScript) {
        Write-Output 'claude: member-contact -> shared/member-commands.ps1 (existing generator, unchanged)'
        if ($WhatIf) { & $memberScript -GlobalClaudeRoot $GlobalClaudeRoot -WhatIf } else { & $memberScript -GlobalClaudeRoot $GlobalClaudeRoot }
    } else {
        Write-Output 'claude: member-contact skipped - shared/member-commands.ps1 not found'
    }
}

# =================================================================================================
# Codex: no confirmed custom-prompts directory (see header). Fall back to one generated catalog
# file with plain-English dispatch instructions; AGENTS.md itself is left for a later pass.
# =================================================================================================
$codexCatalogPath = Join-Path $PSScriptRoot 'shared\codex-command-catalog.md'
$codexLines = [System.Collections.Generic.List[string]]::new()
$codexLines.Add('# MindAttic command catalog for Codex (generated by render-abilities.ps1 - MAT-T95)')
$codexLines.Add('')
$codexLines.Add('Codex CLI has no confirmed custom prompts/commands directory as of this writing: `codex --help`')
$codexLines.Add('and `codex mcp --help` list no such option, `codex features list` shows a plugin-marketplace')
$codexLines.Add('system (`plugins`, `plugin_sharing`) as the stable extensibility surface, and `$CODEX_HOME\skills`')
$codexLines.Add('holds only an internal `.system` cache, not user-authored skill content. Codex does read AGENTS.md')
$codexLines.Add('natively and does support hooks (`$CODEX_HOME\hooks.json`, wired separately under MAT-T94), so this')
$codexLines.Add('file is the fallback: when the user types one of the names below as `/name args` or `name args`,')
$codexLines.Add('read its entry here and follow it in plain English - there is no special slash-command parser,')
$codexLines.Add('just these conventions. AGENTS.md should point here once (not done by this script - MAT-T95')
$codexLines.Add('leaves that one-line edit for a later pass).')
$codexLines.Add('')
foreach ($a in ($abilities | Where-Object { -not $_.Template })) {
    $names = @($a.Name) + @($a.Aliases)
    $codexLines.Add('## ' + (($names | ForEach-Object { "/$_" }) -join ', '))
    $codexLines.Add('')
    $codexLines.Add($a.Description)
    $codexLines.Add('')
    if ($a.ClaudeOnly) {
        $codexLines.Add("**Unavailable on Codex today** - $($a.ClaudeOnlyReason)")
    } else {
        $codexLines.Add($a.Body.Trim())
    }
    $codexLines.Add('')
}
if (@($abilities | Where-Object { $_.Template }).Count -gt 0) {
    foreach ($t in ($abilities | Where-Object { $_.Template })) {
        $codexLines.Add('## /<member> (e.g. /amy, /ryan, /waffle ...)')
        $codexLines.Add('')
        $codexLines.Add($t.Description)
        $codexLines.Add('')
        $codexLines.Add("**Unavailable on Codex today** - $($t.ClaudeOnlyReason)")
        $codexLines.Add('')
    }
}
$codexContent = ($codexLines -join "`n").TrimEnd() + "`n"
if (-not (Test-Path -LiteralPath $codexCatalogPath) -or ([IO.File]::ReadAllText($codexCatalogPath) -ne $codexContent)) {
    Write-Output "codex: shared/codex-command-catalog.md regenerated ($($abilities.Count) abilities)"
    if (-not $WhatIf) { [IO.File]::WriteAllText($codexCatalogPath, $codexContent, $utf8) }
}
Write-Output 'codex: NOTE - AGENTS.md is not edited by this script (left for a later pass). Add one pointer'
Write-Output '       line to it by hand, e.g. "Codex: see mindattic-agent-standard/shared/codex-command-catalog.md".'

# =================================================================================================
# Kimi: confirmed via https://moonshotai.github.io/kimi-code/en/customization/skills - user-level
# auto-discovery at $KIMI_CODE_HOME\skills (default ~/.kimi-code/skills), directory-per-skill with
# SKILL.md (name + description required) - the same shape Claude's own Skill tool uses.
# =================================================================================================
if (Test-Path -LiteralPath $KimiHome) {
    $kimiSkillsDir = Join-Path $KimiHome 'skills'
    New-Item -ItemType Directory -Force -Path $kimiSkillsDir | Out-Null
    $renderedKimi = [System.Collections.Generic.List[string]]::new()
    foreach ($a in ($abilities | Where-Object { -not $_.Template -and -not $_.ClaudeOnly })) {
        $dir = Join-Path $kimiSkillsDir $a.Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $descBits = [System.Collections.Generic.List[string]]::new()
        $descBits.Add(($a.Description -replace '"', '\"'))
        if ($a.ArgumentHint) { $descBits.Add("Argument hint: $($a.ArgumentHint).") }
        if ($a.Aliases.Count -gt 0) { $descBits.Add('Also invoked as: ' + (($a.Aliases | ForEach-Object { "/$_" }) -join ', ') + '.') }
        $skill = '---' + "`n" + "name: $($a.Name)" + "`n" + 'description: "' + ($descBits -join ' ') + '"' + "`n" + '---' + "`n`n" + $a.Body.Trim() + "`n"
        $dest = Join-Path $dir 'SKILL.md'
        $renderedKimi.Add($a.Name)
        if ((Test-Path -LiteralPath $dest) -and ([IO.File]::ReadAllText($dest) -eq $skill)) { continue }
        Write-Output "kimi: ~/.kimi-code/skills/$($a.Name)/SKILL.md <- shared/abilities/$($a.Name).md"
        if (-not $WhatIf) { [IO.File]::WriteAllText($dest, $skill, $utf8) }
    }
    foreach ($d in Get-ChildItem -LiteralPath $kimiSkillsDir -Directory -ErrorAction SilentlyContinue) {
        if ($renderedKimi -contains $d.Name) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md')) {
            Write-Output "kimi: ~/.kimi-code/skills/$($d.Name)/SKILL.md is no longer produced by any portable ability - left alone (remove by hand if stale)"
        }
    }
    Write-Output 'kimi: NOTE - unverified whether a Kimi skill body receives $ARGUMENTS the way a Claude command'
    Write-Output '      does; the rendered bodies carry that placeholder over from the Claude source as-is.'
} else {
    Write-Output "kimi: $KimiHome not found - skipping (pass -KimiHome, or install Kimi Code, to render here)"
}

# =================================================================================================
# agy: MAT-T96 is bootstrapping ~/.agy concurrently; it does not exist on this machine yet. No-op
# cleanly rather than erroring. See the header comment for what MAT-T96 needs to confirm.
# =================================================================================================
if (Test-Path -LiteralPath $AgyHome) {
    Write-Output "agy: $AgyHome exists, but render-abilities.ps1 does not yet know agy's confirmed command/skill"
    Write-Output '     convention (MAT-T96) - no abilities rendered. Extend the agy branch of this script once'
    Write-Output '     MAT-T96 documents the real shape (its own AGENTS.md/hooks.json/settings.json, or whatever'
    Write-Output '     it actually turns out to be).'
} else {
    Write-Output "agy: $AgyHome not found yet (MAT-T96 not landed) - skipping cleanly."
    Write-Output '     TODO for MAT-T96: once agy''s config directory is confirmed, extend this script''s agy'
    Write-Output '     branch to render shared/abilities/*.md (excluding claude-only ones) into it, the same'
    Write-Output '     way the Kimi branch above renders into ~/.kimi-code/skills.'
}

if ($WhatIf) { Write-Output 'WhatIf: nothing was changed.' }
