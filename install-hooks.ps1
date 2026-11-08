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

    It also wires the test gate (MAT-T121, shared/hooks/test-gate.py: the no-test GOLDEN RULE) into every CLI
    where it isn't wired yet -- added, never duplicated, never touching any other hook:
      - Claude Code:  UserPromptSubmit, SubagentStart, PreToolUse (Bash|PowerShell|Monitor) in ~/.claude/settings.json
                      and in each ~/.claude-accounts/<login>/settings.json (MindAttic.Orchestrator derives those from
                      ~/.claude's, so it carries over there anyway; writing them too makes it live at once)
      - Codex:        UserPromptSubmit, SubagentStart, PreToolUse in ~/.codex/hooks.json ("codex" argv)
      - Kimi:         [[hooks]] UserPromptSubmit, SubagentStart, PreToolUse in ~/.kimi-code/config.toml ("kimi" argv)
      - agy:          PreToolUse and PreInvocation under "mindattic-standard" in ~/.gemini/config/hooks.json (unquoted
                      path, per agy's quoting gotcha; "agy <event>" argv since agy's payload names no event)

    It also wires the commit gate (M.ORCH-T1530, shared/hooks/commit-gate.py: agents sharing a checkout can't commit
    or close each other's unfinished work) the same way: Claude PreToolUse (Bash|PowerShell|Edit|Write|MultiEdit|
    NotebookEdit|Agent|Task), PostToolUse (Bash|PowerShell), SubagentStart, SubagentStop, SessionEnd; Codex and Kimi
    the same events with their argv; agy PreToolUse. Its git half runs from shared/hooks/commit-msg (install-commit-hooks.ps1).

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
    [string]$GlobalAgyRoot = "$env:USERPROFILE\.gemini\config",
    [string]$ClaudeAccountsRoot = "$env:USERPROFILE\.claude-accounts",
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

# -- Test gate (MAT-T121): add it where it isn't wired yet ------------------------------------------------------
$testGate = Join-Path $mirrorHooks 'test-gate.py'
foreach ($f in @('test-gate.py', 'test-gate-patterns.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $mirrorHooks $f))) {
        throw "missing shared hook: $(Join-Path $mirrorHooks $f) -- run sync-workspace-copy.ps1 (no -Check) from this repo first"
    }
}
$testGatePath = $testGate.Replace('\', '/')

function Test-HasTestGate($groups) {
    foreach ($g in @($groups)) {
        if ($null -eq $g) { continue }
        if ($g.PSObject.Properties.Name -contains 'command' -and "$($g.command)" -like '*test-gate.py*') { return $true }
        foreach ($h in @($g.hooks)) { if ($null -ne $h -and "$($h.command)" -like '*test-gate.py*') { return $true } }
    }
    return $false
}

# Adds { matcher, hooks: [ {command, timeout} ] } to each event of a Claude/Codex-shaped hooks object that has no
# test-gate.py command yet. Returns how many it added.
function Add-TestGateHooks($root, [string]$suffix, [hashtable]$matchers) {
    if ($null -eq $root.hooks) { $root | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $added = 0
    foreach ($eventName in $matchers.Keys) {
        $existing = if ($root.hooks.PSObject.Properties.Name -contains $eventName) { $root.hooks.$eventName } else { $null }
        if (Test-HasTestGate $existing) { continue }
        $group = [pscustomobject]@{
            matcher = $matchers[$eventName]
            hooks   = @([pscustomobject]@{ type = 'command'; command = "python `"$testGatePath`"$suffix"; timeout = 10 })
        }
        if ($null -eq $existing) {
            $root.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($group)
        } else {
            $root.hooks.$eventName = @($existing) + $group
        }
        $added++
    }
    return $added
}

$claudeMatchers = @{ UserPromptSubmit = ''; SubagentStart = ''; PreToolUse = 'Bash|PowerShell|Monitor' }
$claudeFiles = @(@{ path = $claudeSettingsPath; owner = 'claude' })
if (Test-Path -LiteralPath $ClaudeAccountsRoot) {
    foreach ($d in Get-ChildItem -LiteralPath $ClaudeAccountsRoot -Directory) {
        $p = Join-Path $d.FullName 'settings.json'
        if (Test-Path -LiteralPath $p) { $claudeFiles += @{ path = $p; owner = "claude-account-$($d.Name)" } }
    }
}
foreach ($cf in $claudeFiles) {
    if (-not (Test-Path -LiteralPath $cf.path)) { continue }
    $settings = Read-Json $cf.path
    $n = Add-TestGateHooks $settings '' $claudeMatchers
    if ($n -gt 0) {
        Write-Output "Claude: wired the test gate on $n event(s) in $($cf.path)"
        if (-not $WhatIf) { Save-Json $cf.path $settings $cf.owner }
    } else {
        Write-Output "Claude: test gate already wired in $($cf.path)"
    }
}

if (Test-Path -LiteralPath $codexHooksPath) {
    $codexHooks = Read-Json $codexHooksPath
    $n = Add-TestGateHooks $codexHooks ' codex' @{ UserPromptSubmit = ''; SubagentStart = ''; PreToolUse = '' }
    if ($n -gt 0) {
        Write-Output "Codex: wired the test gate on $n event(s) in $codexHooksPath"
        if (-not $WhatIf) { Save-Json $codexHooksPath $codexHooks 'codex' }
    } else {
        Write-Output "Codex: test gate already wired"
    }
}

if (Test-Path -LiteralPath $kimiConfigPath) {
    $raw = Get-Content -LiteralPath $kimiConfigPath -Raw -Encoding UTF8
    if ($raw -match 'test-gate\.py') {
        Write-Output "Kimi: test gate already wired"
    } else {
        $blocks = foreach ($e in @('UserPromptSubmit', 'SubagentStart', 'PreToolUse')) {
            "[[hooks]]`nevent = `"$e`"`ncommand = 'python `"$testGatePath`" kimi'`ntimeout = 10`n"
        }
        $updated = $raw.TrimEnd() + "`n`n" + ($blocks -join "`n")
        Write-Output "Kimi: wired the test gate in $kimiConfigPath"
        if (-not $WhatIf) {
            Backup-File $kimiConfigPath 'kimi'
            [System.IO.File]::WriteAllText($kimiConfigPath, $updated, (New-Object System.Text.UTF8Encoding $false))
        }
    }
}

$agyHooksPath = Join-Path $GlobalAgyRoot 'hooks.json'
if (Test-Path -LiteralPath $agyHooksPath) {
    $agy = Read-Json $agyHooksPath
    if ($null -eq $agy.'mindattic-standard') { $agy | Add-Member -NotePropertyName 'mindattic-standard' -NotePropertyValue ([pscustomobject]@{}) }
    $std = $agy.'mindattic-standard'
    $n = 0
    # agy: tool events take the matcher wrapper, other events are flat handler arrays; commands stay unquoted.
    $pre = if ($std.PSObject.Properties.Name -contains 'PreToolUse') { $std.PreToolUse } else { $null }
    if (-not (Test-HasTestGate $pre)) {
        $g = [pscustomobject]@{ matcher = ''; hooks = @([pscustomobject]@{ type = 'command'; command = "python $testGatePath agy PreToolUse"; timeout = 10 }) }
        if ($null -eq $pre) { $std | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @($g) } else { $std.PreToolUse = @($pre) + $g }
        $n++
    }
    $inv = if ($std.PSObject.Properties.Name -contains 'PreInvocation') { $std.PreInvocation } else { $null }
    if (-not (Test-HasTestGate $inv)) {
        $h = [pscustomobject]@{ type = 'command'; command = "python $testGatePath agy PreInvocation"; timeout = 10 }
        if ($null -eq $inv) { $std | Add-Member -NotePropertyName PreInvocation -NotePropertyValue @($h) } else { $std.PreInvocation = @($inv) + $h }
        $n++
    }
    if ($n -gt 0) {
        Write-Output "agy: wired the test gate on $n event(s) in $agyHooksPath"
        if (-not $WhatIf) { Save-Json $agyHooksPath $agy 'agy' }
    } else {
        Write-Output "agy: test gate already wired"
    }
} else {
    Write-Output "agy: no hooks.json at $agyHooksPath -- skipped"
}

# -- Commit gate (M.ORCH-T1530): per-agent path tracking, the ticket-close guard, and the "who is committing" marker
# the commit-msg hook's half of shared/hooks/commit-gate.py reads. Added where it isn't wired yet, never duplicated.
foreach ($f in @('commit-gate.py', 'commit-gate-shared.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $mirrorHooks $f))) {
        throw "missing shared hook: $(Join-Path $mirrorHooks $f) -- copy it from this repo's shared/hooks first"
    }
}
$commitGatePath = (Join-Path $mirrorHooks 'commit-gate.py').Replace('\', '/')

function Test-HasCommitGate($groups) {
    foreach ($g in @($groups)) {
        if ($null -eq $g) { continue }
        if ($g.PSObject.Properties.Name -contains 'command' -and "$($g.command)" -like '*commit-gate.py*') { return $true }
        foreach ($h in @($g.hooks)) { if ($null -ne $h -and "$($h.command)" -like '*commit-gate.py*') { return $true } }
    }
    return $false
}

function Add-CommitGateHooks($root, [string]$suffix, [hashtable]$matchers) {
    if ($null -eq $root.hooks) { $root | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $added = 0
    foreach ($eventName in $matchers.Keys) {
        $existing = if ($root.hooks.PSObject.Properties.Name -contains $eventName) { $root.hooks.$eventName } else { $null }
        if (Test-HasCommitGate $existing) { continue }
        $group = [pscustomobject]@{
            matcher = $matchers[$eventName]
            hooks   = @([pscustomobject]@{ type = 'command'; command = "python `"$commitGatePath`"$suffix"; timeout = 10 })
        }
        if ($null -eq $existing) {
            $root.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($group)
        } else {
            $root.hooks.$eventName = @($existing) + $group
        }
        $added++
    }
    return $added
}

$commitGateTools = 'Bash|PowerShell|Edit|Write|MultiEdit|NotebookEdit|Agent|Task'
$claudeCommitMatchers = @{ PreToolUse = $commitGateTools; PostToolUse = 'Bash|PowerShell'; SubagentStart = ''; SubagentStop = ''; SessionEnd = '' }
foreach ($cf in $claudeFiles) {
    if (-not (Test-Path -LiteralPath $cf.path)) { continue }
    $settings = Read-Json $cf.path
    $n = Add-CommitGateHooks $settings '' $claudeCommitMatchers
    if ($n -gt 0) {
        Write-Output "Claude: wired the commit gate on $n event(s) in $($cf.path)"
        if (-not $WhatIf) { Save-Json $cf.path $settings $cf.owner }
    } else {
        Write-Output "Claude: commit gate already wired in $($cf.path)"
    }
}

if (Test-Path -LiteralPath $codexHooksPath) {
    $codexHooks = Read-Json $codexHooksPath
    $n = Add-CommitGateHooks $codexHooks ' codex' @{ PreToolUse = ''; PostToolUse = ''; SubagentStart = ''; SubagentStop = '' }
    if ($n -gt 0) {
        Write-Output "Codex: wired the commit gate on $n event(s) in $codexHooksPath"
        if (-not $WhatIf) { Save-Json $codexHooksPath $codexHooks 'codex' }
    } else {
        Write-Output "Codex: commit gate already wired"
    }
}

if (Test-Path -LiteralPath $kimiConfigPath) {
    $raw = Get-Content -LiteralPath $kimiConfigPath -Raw -Encoding UTF8
    if ($raw -match 'commit-gate\.py') {
        Write-Output "Kimi: commit gate already wired"
    } else {
        $blocks = foreach ($e in @('PreToolUse', 'PostToolUse', 'SubagentStart', 'SubagentStop')) {
            "[[hooks]]`nevent = `"$e`"`ncommand = 'python `"$commitGatePath`" kimi'`ntimeout = 10`n"
        }
        $updated = $raw.TrimEnd() + "`n`n" + ($blocks -join "`n")
        Write-Output "Kimi: wired the commit gate in $kimiConfigPath"
        if (-not $WhatIf) {
            Backup-File $kimiConfigPath 'kimi'
            [System.IO.File]::WriteAllText($kimiConfigPath, $updated, (New-Object System.Text.UTF8Encoding $false))
        }
    }
}

if (Test-Path -LiteralPath $agyHooksPath) {
    $agy = Read-Json $agyHooksPath
    if ($null -eq $agy.'mindattic-standard') { $agy | Add-Member -NotePropertyName 'mindattic-standard' -NotePropertyValue ([pscustomobject]@{}) }
    $std = $agy.'mindattic-standard'
    $pre = if ($std.PSObject.Properties.Name -contains 'PreToolUse') { $std.PreToolUse } else { $null }
    if (-not (Test-HasCommitGate $pre)) {
        $g = [pscustomobject]@{ matcher = ''; hooks = @([pscustomobject]@{ type = 'command'; command = "python $commitGatePath agy PreToolUse"; timeout = 10 }) }
        if ($null -eq $pre) { $std | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @($g) } else { $std.PreToolUse = @($pre) + $g }
        Write-Output "agy: wired the commit gate in $agyHooksPath"
        if (-not $WhatIf) { Save-Json $agyHooksPath $agy 'agy' }
    } else {
        Write-Output "agy: commit gate already wired"
    }
}

if ($WhatIf) { Write-Output 'WhatIf: nothing was changed.' }
