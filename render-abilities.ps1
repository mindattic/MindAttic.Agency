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

    - Codex: no custom `/name args` slash-command PARSER is confirmed for Codex CLI - checked
      empirically (`codex --help`, `codex mcp --help` list no such option; Codex's own
      extensibility is a plugin marketplace (`codex plugin ...`), and a plugin's manifest
      (`.codex-plugin/plugin.json`) only ever wraps the same three primitives: `skills` (model-
      interpreted by description match, not harness-dispatched), `hooks` (lifecycle events, not
      user commands) and `mcpServers` (real tool calls, but still invoked at the model's
      judgment, never a literal user-typed `/name` the harness parses deterministically the way
      Claude Code's own command files are). MAT-T98 built nothing as a plugin because of this:
      a plugin would only be packaging overhead (marketplace.json, versioning, interface
      metadata) around a mechanism already reachable directly (see next point) - the ticket's own
      "don't force a heavyweight MCP-server plugin for marginal gain" guidance applies.
      **CORRECTION (MAT-T98, supersedes MAT-T95's assumption above):** `$CODEX_HOME\skills` is
      NOT limited to the internal `.system` cache - a plain `skills\<name>\SKILL.md` dropped
      there directly (no plugin, no marketplace registration) IS auto-discovered and invoked,
      confirmed empirically with an isolated scratch CODEX_HOME: a probe skill's description
      ("use this whenever the user says 'run the probe'") was matched by a live `codex exec`
      prompt, and Codex read the file itself (via its own exec/shell tool) and followed it. This
      is the SAME shape and SAME tier of mechanism Kimi/agy already use below (model-interpreted
      from a description, not a deterministic slash parser), but it is strictly better than
      dumping the whole catalog into AGENTS.md as constant-cost inline text: it is selectively
      surfaced per-skill and costs nothing in context until matched. So abilities are now
      rendered BOTH ways: into `$CODEX_HOME\skills\<name>\SKILL.md` (mirroring the Kimi/agy
      branches exactly - this is the real, working mechanism) AND into the single
      `shared\codex-command-catalog.md` file referenced from AGENTS.md (kept as a human-readable
      index of what exists and what's unavailable, and as the fallback for a Codex install old
      enough that host skill discovery isn't present). Neither one is a true native "/name"
      command parser; that still does not exist on Codex today. Claude-only abilities carrying a
      `codex-equivalent`/`codex-equivalent-note` field (see shared/abilities/allocate.md,
      research.md, member-contact.md) get that caveat rendered into the catalog instead of a flat
      "unavailable" - a confirmed-possible, honestly-caveated path, never silently wired in as
      production-ready. This script does NOT edit AGENTS.md's one-line pointer to the catalog
      (left for a later pass, same as MAT-T95 left it).

    - Kimi: confirmed via Kimi's own docs (https://moonshotai.github.io/kimi-code/, Customization
      > Skills) that it auto-discovers user-level skills at $KIMI_CODE_HOME\skills (defaults to
      ~/.kimi-code/skills) and ~/.agents/skills, directory-per-skill with a SKILL.md whose
      frontmatter requires name + description - the same shape Claude's own Skill tool uses.
      Portable abilities are rendered to ~/.kimi-code/skills/<name>/SKILL.md; claude-only
      abilities are skipped (they would not function there). CONFIRMED-WORKING FROM SOURCE
      (MAT-T98, 2026-11-06 - reading the bundled JS inside Kimi Code's own executable,
      ~/.kimi-code/bin/kimi.exe, the same binary-analysis technique MAT-T100 used on codex.exe):
      Kimi genuinely substitutes `$ARGUMENTS` (plus `$ARGUMENTS[N]`, `$1`, and named `$NAME`
      placeholders declared via an `arguments:` frontmatter field) with a real argument string
      before the model ever sees the skill body - this is NOT the same architecture as agy below.
      The call path is `renderSkillPrompt(skill, rawArgs)` ->
      `expandSkillParameters(skill.content, rawArgs, {...})`, which does a literal
      `body.replaceAll("$ARGUMENTS", args)` (and appends a trailing `ARGUMENTS: <args>` line if the
      body has no placeholder at all); Kimi's own in-binary docstring says this placeholder syntax
      "is modelled after common conventions" - i.e. deliberately Claude-slash-command-compatible.
      `rawArgs` comes from whatever text follows an explicit `/name args` invocation, or from an
      explicit `args` string the model supplies when it chooses to invoke a skill on its own (the
      model-facing tool schema explicitly instructs it to pass the relevant text and "omit it only
      when there is nothing to pass"). So the rendered body keeps `$ARGUMENTS` literal, exactly like
      the Claude branch above - no rewrite needed or applied here.

    - agy: confirmed by MAT-T96 by actually running `agy -p "..."` once in a throwaway scratch
      directory and inspecting what appeared on disk. agy (Google Antigravity CLI) is NOT at
      `~/.agy`/`~/.antigravity` (neither exists) - its real machine-wide customization root is
      **`~/.gemini/config/`** (agy's own built-in docs call this "Global Configuration
      (Machine-Local)"; it's the same root that already holds `mcp_config.json`). Skills there
      follow the identical shape Kimi uses: `skills/<name>/SKILL.md` with `name` + `description`
      frontmatter - confirmed live (a throwaway probe skill with a secret-phrase instruction was
      picked up and triggered by a matching `agy -p` prompt). So portable (non claude-only, non
      template) abilities are rendered to `~/.gemini/config/skills/<name>/SKILL.md`, exactly like
      the Kimi branch below. CONFIRMED (MAT-T98) by directly testing a disposable probe skill
      against `agy -p`: `$ARGUMENTS` in the rendered body is NOT substituted by any harness before
      the model sees it - a probe skill asked to quote its own instruction text verbatim reported
      the literal five characters `$ARGUMENTS` still present, unreplaced, in its own context. A
      separate probe did correctly pick up the user's typed argument text, but only because the
      model read it directly out of the user's own conversational message (agy's skills are
      model-activated from their description, not invoked as an explicit `/name args` the way
      Claude commands are - there is no slash-command parser to substitute anything). So
      `$ARGUMENTS` is rewritten to plain-English guidance in the rendered body instead of being
      left as dead, never-substituted text.

.PARAMETER WorkspaceRoot
    The MindAttic workspace root. Defaults to this script's own parent's parent, same convention
    install.ps1/share-scripts.ps1 use.

.PARAMETER GlobalClaudeRoot
    Claude Code's global config folder. Defaults to ~/.claude.

.PARAMETER KimiHome
    Kimi Code's config folder ($KIMI_CODE_HOME). Defaults to ~/.kimi-code. Rendering into it
    no-ops (with a message) if this folder doesn't exist.

.PARAMETER AgyHome
    agy's (Google Antigravity CLI) global customization root. Defaults to ~/.gemini/config
    (confirmed by MAT-T96 - NOT ~/.agy, which doesn't exist). Rendering into it no-ops (with a
    message) if this folder doesn't exist.

.PARAMETER WhatIf
    Report what would change; change nothing.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",
    [string]$KimiHome = "$env:USERPROFILE\.kimi-code",
    [string]$AgyHome = "$env:USERPROFILE\.gemini\config",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$abilitiesDir = Join-Path $PSScriptRoot 'shared\abilities'
$commandsDir = Join-Path $PSScriptRoot 'shared\commands'
$utf8 = New-Object System.Text.UTF8Encoding $false
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-Md5([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLowerInvariant() }

# ── agy has no harness that substitutes $ARGUMENTS (Kimi is different - see its own branch below) ──
# CONFIRMED (MAT-T98, direct test against agy): a rendered skill's literal `$ARGUMENTS` token is
# NOT substituted before the model sees it - a probe skill asked to quote its own instruction text
# verbatim reported the five characters "$ARGUMENTS" still present, unreplaced, in its own context.
# A separate probe did correctly answer using the user's typed argument text - but only because the
# model read it directly out of the user's own conversational message, not because the placeholder
# was filled in. Leaving a literal, never-substituted `$ARGUMENTS` token in a rendered skill body is
# useless noise for agy, so it's rewritten to plain-English guidance instead. NOTE (MAT-T98,
# 2026-11-06): Kimi was previously assumed to share this same no-substitution architecture "by
# analogy" - that assumption was wrong. Reading Kimi Code's own bundled JS source
# (~/.kimi-code/bin/kimi.exe) found a real `expandSkillParameters`/`renderSkillPrompt` substitution
# path that does replace `$ARGUMENTS` with real argument text, so Kimi's own branch below does NOT
# use this rewrite - only agy does.
$agyArgNote = 'Note: this skill is activated by the model matching its description to the ' +
    'conversation, not by a slash-command harness - nothing here is pre-filled for you. Wherever ' +
    "this skill's text below refers to 'the rest of the user's own message', read it yourself " +
    'directly from what the user actually typed in this conversation.'
function ConvertTo-AgyModelActivatedText([string]$text) {
    return $text.Replace('$ARGUMENTS', "the rest of the user's own message")
}

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
# $ARGUMENTS is kept LITERAL here (unlike the agy branch below) - CONFIRMED-WORKING FROM SOURCE
# (MAT-T98, 2026-11-06): Kimi's own bundled JS (~/.kimi-code/bin/kimi.exe) genuinely substitutes
# `$ARGUMENTS`/`$1`/`$NAME` with real argument text via `expandSkillParameters`/`renderSkillPrompt`
# before the model sees the body - see the script header for the full source citation.
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
        $bodyText = $a.Body.Trim()
        $skill = '---' + "`n" + "name: $($a.Name)" + "`n" + 'description: "' + ($descBits -join ' ') + '"' + "`n" + '---' + "`n`n" + $bodyText + "`n"
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
    Write-Output 'kimi: NOTE - CONFIRMED-WORKING FROM SOURCE (MAT-T98): Kimi genuinely substitutes $ARGUMENTS'
    Write-Output '      with real argument text (see ~/.kimi-code/bin/kimi.exe source analysis in docs/'
    Write-Output '      hook-contract-matrix.md), so the literal placeholder is kept as-is - no rewrite.'
} else {
    Write-Output "kimi: $KimiHome not found - skipping (pass -KimiHome, or install Kimi Code, to render here)"
}

# =================================================================================================
# agy (Google Antigravity CLI): confirmed by MAT-T96 - global customization root is
# ~/.gemini/config (NOT ~/.agy), skills live at skills/<name>/SKILL.md there, identical shape to
# Kimi's. Mirrors the Kimi branch above.
# =================================================================================================
if (Test-Path -LiteralPath $AgyHome) {
    $agySkillsDir = Join-Path $AgyHome 'skills'
    New-Item -ItemType Directory -Force -Path $agySkillsDir | Out-Null
    $renderedAgy = [System.Collections.Generic.List[string]]::new()
    foreach ($a in ($abilities | Where-Object { -not $_.Template -and -not $_.ClaudeOnly })) {
        $dir = Join-Path $agySkillsDir $a.Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $descBits = [System.Collections.Generic.List[string]]::new()
        $descBits.Add(((ConvertTo-AgyModelActivatedText $a.Description) -replace '"', '\"'))
        if ($a.ArgumentHint) { $descBits.Add("Argument hint: $($a.ArgumentHint).") }
        if ($a.Aliases.Count -gt 0) { $descBits.Add('Also invoked as: ' + (($a.Aliases | ForEach-Object { "/$_" }) -join ', ') + '.') }
        $bodyText = ConvertTo-AgyModelActivatedText ($a.Body.Trim())
        if ($a.Body.Contains('$ARGUMENTS')) { $bodyText = $agyArgNote + "`n`n" + $bodyText }
        $skill = '---' + "`n" + "name: $($a.Name)" + "`n" + 'description: "' + ($descBits -join ' ') + '"' + "`n" + '---' + "`n`n" + $bodyText + "`n"
        $dest = Join-Path $dir 'SKILL.md'
        $renderedAgy.Add($a.Name)
        if ((Test-Path -LiteralPath $dest) -and ([IO.File]::ReadAllText($dest) -eq $skill)) { continue }
        Write-Output "agy: ~/.gemini/config/skills/$($a.Name)/SKILL.md <- shared/abilities/$($a.Name).md"
        if (-not $WhatIf) { [IO.File]::WriteAllText($dest, $skill, $utf8) }
    }
    foreach ($d in Get-ChildItem -LiteralPath $agySkillsDir -Directory -ErrorAction SilentlyContinue) {
        if ($renderedAgy -contains $d.Name) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md')) {
            Write-Output "agy: ~/.gemini/config/skills/$($d.Name)/SKILL.md is no longer produced by any portable ability - left alone (remove by hand if stale)"
        }
    }
    Write-Output 'agy: NOTE - CONFIRMED (MAT-T98): agy does not substitute $ARGUMENTS before the model sees'
    Write-Output '     it (model-activated skill, not a harness-parsed slash command). Rendered bodies rewrite'
    Write-Output '     the placeholder to plain-English guidance instead of leaving dead, never-substituted text.'
} else {
    Write-Output "agy: $AgyHome not found - skipping (pass -AgyHome, or run agy once, to render here)"
}

if ($WhatIf) { Write-Output 'WhatIf: nothing was changed.' }
