#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the shared pace/context/rate-limit gate hooks to each CLI's expected location (MAT-T94).

.DESCRIPTION
    context-gate.py, pace-gate.py and rl-check.py (plus the Claude-only log-user-input.ps1) used to
    live ONLY as loose, untracked files directly under the Claude home (e.g. C:\Users\ryand\.claude\)
    -- a single disk loss would have destroyed them, with no git history anywhere. They are now
    tracked at shared/hooks/ in this repo (synced out to the workspace-root mindattic-agent-standard/
    mirror by sync-workspace-copy.ps1, same as shared/statusline.ps1 and
    shared/hooks/quickload-on-do.ps1 already are).

    This script repoints each CLI's own config at the mirror copy by absolute path, matching the
    convention share-scripts.ps1 already established for the statusline and the quickload hook:
      - Claude Code:  ~/.claude/settings.json          hooks.<Event>[].hooks[].command
      - Codex:        ~/.codex/hooks.json               hooks.<Event>[].hooks[].command
      - Kimi:         ~/.kimi-code/config.toml          [[hooks]] command = '...'

    It only ever rewrites a command string that still names one of the old loose-file paths; a
    command already pointing at the shared copy, or at something else entirely (a different script,
    a provider argument appended after the path, a timeout), is left alone except for that one
    substring swap -- "python \"...\\pace-gate.py\"" becomes "python \"<shared>\\pace-gate.py\"" and
    nothing else about the command changes. Every file this script edits is backed up first (same
    backup convention as share-scripts.ps1: $env:LOCALAPPDATA\MindAttic\install-hooks-backup\<stamp>).

    The old loose files are NOT deleted here. A single disk is now backed by git either way; removing
    the loose copies is a separate, deliberate step once the new wiring has been proven live (MAT-T94).

.PARAMETER WhatIf
    Report what would change; change nothing.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",
    [string]$GlobalCodexRoot = "$env:USERPROFILE\.codex",
    [string]$GlobalKimiRoot = "$env:USERPROFILE\.kimi-code",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Same pattern install-commit-hooks.ps1 uses: the live wiring points at the workspace-root mirror
# (mindattic-agent-standard/shared/hooks), which sync-workspace-copy.ps1 keeps byte-identical to
# this repo's own shared/hooks/ -- the canonical, git-tracked source.
$mirrorHooks = Join-Path $WorkspaceRoot 'mindattic-agent-standard\shared\hooks'
$hookFiles = @('context-gate.py', 'pace-gate.py', 'rl-check.py', 'log-user-input.ps1')
foreach ($f in $hookFiles) {
    $p = Join-Path $mirrorHooks $f
    if (-not (Test-Path -LiteralPath $p)) {
        throw "missing shared hook: $p -- run sync-workspace-copy.ps1 (no -Check) from this repo first"
    }
}

function Read-Json([string]$path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }

function Backup-File([string]$path, [string]$owner) {
    $backup = Join-Path $env:LOCALAPPDATA "MindAttic\install-hooks-backup\$stamp\$owner"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Copy-Item -LiteralPath $path -Destination (Join-Path $backup (Split-Path -Leaf $path)) -ErrorAction SilentlyContinue
}

function Save-Json([string]$path, $value, [string]$owner) {
    Backup-File $path $owner
    $json = $value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
}

# The old loose-file absolute paths this replaces, and their new shared replacement -- both
# normalized to forward slashes, since every CLI here already writes its hook commands that way.
$oldToNew = @{}
foreach ($f in $hookFiles) {
    $old = if ($f -eq 'log-user-input.ps1') { Join-Path $GlobalClaudeRoot "hooks\$f" } else { Join-Path $GlobalClaudeRoot $f }
    $oldToNew[$old.Replace('\', '/')] = (Join-Path $mirrorHooks $f).Replace('\', '/')
}

function Repoint-Command([string]$command) {
    $out = $command
    foreach ($old in $oldToNew.Keys) { $out = $out.Replace($old, $oldToNew[$old]) }
    return $out
}

# Walk a Claude/Codex-shaped hooks object: { <Event>: [ { matcher, hooks: [ { command, ... } ] } ] }
# and repoint every command string in place. Returns how many commands it changed.
function Repoint-HooksObject($hooksObj) {
    $changedCount = 0
    if ($null -eq $hooksObj) { return 0 }
    foreach ($eventName in @($hooksObj.PSObject.Properties.Name)) {
        foreach ($group in @($hooksObj.$eventName)) {
            foreach ($h in @($group.hooks)) {
                if (-not $h.PSObject.Properties.Name.Contains('command')) { continue }
                $new = Repoint-Command $h.command
                if ($new -ne $h.command) { $h.command = $new; $changedCount++ }
            }
        }
    }
    return $changedCount
}

# -- Claude Code: ~/.claude/settings.json -----------------------------------------------------
$claudeSettingsPath = Join-Path $GlobalClaudeRoot 'settings.json'
if (Test-Path -LiteralPath $claudeSettingsPath) {
    $claudeSettings = Read-Json $claudeSettingsPath
    $n = Repoint-HooksObject $claudeSettings.hooks
    if ($n -gt 0) {
        Write-Output "Claude: repointed $n hook command(s) in $claudeSettingsPath"
        if (-not $WhatIf) { Save-Json $claudeSettingsPath $claudeSettings 'claude' }
    } else {
        Write-Output "Claude: already points at the shared hooks (or none found to repoint)"
    }
} else {
    Write-Output "Claude: no settings.json at $claudeSettingsPath -- skipped"
}

# -- Codex: ~/.codex/hooks.json ----------------------------------------------------------------
$codexHooksPath = Join-Path $GlobalCodexRoot 'hooks.json'
if (Test-Path -LiteralPath $codexHooksPath) {
    $codexHooks = Read-Json $codexHooksPath
    $n = Repoint-HooksObject $codexHooks.hooks
    if ($n -gt 0) {
        Write-Output "Codex: repointed $n hook command(s) in $codexHooksPath"
        if (-not $WhatIf) { Save-Json $codexHooksPath $codexHooks 'codex' }
    } else {
        Write-Output "Codex: already points at the shared hooks (or none found to repoint)"
    }
} else {
    Write-Output "Codex: no hooks.json at $codexHooksPath -- skipped"
}

# -- Kimi: ~/.kimi-code/config.toml --------------------------------------------------------------
# TOML, not JSON: config.toml's [[hooks]] command is a plain quoted string, so a straight substring
# swap on the raw text is enough and keeps every other key (event, timeout, other [[hooks]] blocks)
# byte-for-byte untouched.
$kimiConfigPath = Join-Path $GlobalKimiRoot 'config.toml'
if (Test-Path -LiteralPath $kimiConfigPath) {
    $raw = Get-Content -LiteralPath $kimiConfigPath -Raw -Encoding UTF8
    $updated = $raw
    foreach ($old in $oldToNew.Keys) { $updated = $updated.Replace($old, $oldToNew[$old]) }
    if ($updated -ne $raw) {
        Write-Output "Kimi: repointed hook command path(s) in $kimiConfigPath"
        if (-not $WhatIf) {
            Backup-File $kimiConfigPath 'kimi'
            [System.IO.File]::WriteAllText($kimiConfigPath, $updated, (New-Object System.Text.UTF8Encoding $false))
        }
    } else {
        Write-Output "Kimi: already points at the shared hooks (or none found to repoint)"
    }
} else {
    Write-Output "Kimi: no config.toml at $kimiConfigPath -- skipped"
}

if ($WhatIf) { Write-Output 'WhatIf: nothing was changed.' }
