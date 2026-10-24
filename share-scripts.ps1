#Requires -Version 5.1
<#
.SYNOPSIS
    One shared copy of the statusline and the "do" quickload hook instead of one per repo.

.DESCRIPTION
    The statusline (.claude/statusline.ps1) and the quickload hook (.claude/hooks/quickload-on-do.ps1)
    were copied into most repos. This points this machine's global Claude settings
    (~/.claude/settings.json) at the copies in mindattic-agent-standard/shared by absolute path (global
    settings are per machine, and an absolute path also works in orchestrator worktrees, which live
    outside the workspace), then, in each repo whose copy is byte-identical to the common original:
    removes the repo's settings entry for it and the copy itself, so the global one applies.

    A copy that differs (drifted or customized) is left alone, with its settings entry, and listed;
    the shared hook stands aside in such a repo. Every settings file is backed up before it's changed.
    tools/build-readme.ps1 needs nothing: each repo's copy is already a 3-line forwarder to the shared
    engine in codex-standard.

.PARAMETER WhatIf
    Report what would change; change nothing.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$shared = Join-Path $PSScriptRoot 'shared'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The common originals, as the repos have them (the shared hook differs in how it finds the repo).
$scripts = @(
    [pscustomobject]@{ Name = 'statusline';  Local = '.claude\statusline.ps1';             Original = 'fcbbdfbfc9a3457eb9325e5dbf7cb7a5'; Shared = (Join-Path $shared 'statusline.ps1') },
    [pscustomobject]@{ Name = 'quickload';   Local = '.claude\hooks\quickload-on-do.ps1';  Original = '2ba09661ccb7ef149c9d032a94d8e84a'; Shared = (Join-Path $shared 'hooks\quickload-on-do.ps1') }
)

function Get-Md5([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLowerInvariant() }

function Read-Json([string]$path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }

function Save-Json([string]$path, $value) {
    # Backups go outside the repos, so an agent's `git add -A` can't commit them.
    $owner = if ($path.StartsWith($WorkspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $path)) } else { '_global' }
    $backup = Join-Path $env:LOCALAPPDATA "MindAttic\share-scripts-backup\$stamp\$owner"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Copy-Item -LiteralPath $path -Destination (Join-Path $backup 'settings.json') -ErrorAction SilentlyContinue
    $json = $value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
}

function Command-For([string]$script) { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script.Replace('\','/'))`"" }

# ── Global settings: point at the shared copies ─────────────────────────────
$globalPath = Join-Path $GlobalClaudeRoot 'settings.json'
$global = if (Test-Path $globalPath) { Read-Json $globalPath } else { [pscustomobject]@{} }
$globalChanged = $false

$statusCommand = Command-For $scripts[0].Shared
if (-not ($global.PSObject.Properties.Name -contains 'statusLine')) {
    $global | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $statusCommand })
    $globalChanged = $true
    Write-Output "global: statusline -> $($scripts[0].Shared)"
}

$hookCommand = Command-For $scripts[1].Shared
if (-not ($global.PSObject.Properties.Name -contains 'hooks')) { $global | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
if (-not ($global.hooks.PSObject.Properties.Name -contains 'UserPromptSubmit')) { $global.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue @() }
$existing = @($global.hooks.UserPromptSubmit | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
if ($existing -notcontains $hookCommand) {
    $groups = @($global.hooks.UserPromptSubmit)
    if ($groups.Count -eq 0) { $groups = @([pscustomobject]@{ matcher = ''; hooks = @() }) }
    $groups[0].hooks = @($groups[0].hooks) + [pscustomobject]@{ type = 'command'; command = $hookCommand }
    $global.hooks.UserPromptSubmit = $groups
    $globalChanged = $true
    Write-Output "global: UserPromptSubmit hook -> $($scripts[1].Shared)"
}
if ($globalChanged -and -not $WhatIf) { Save-Json $globalPath $global }

# -- Global commands: shared/commands/*.md is the source of the global /quicksave, /quickload ... --
# A global command that differs is backed up (outside the repos), then replaced with the shared copy.
$globalCommands = Join-Path $GlobalClaudeRoot 'commands'
foreach ($cmd in Get-ChildItem -LiteralPath (Join-Path $shared 'commands') -Filter '*.md' -File -ErrorAction SilentlyContinue) {
    $dest = Join-Path $globalCommands $cmd.Name
    if ((Test-Path -LiteralPath $dest) -and (Get-Md5 $dest) -eq (Get-Md5 $cmd.FullName)) { continue }
    Write-Output "global: command /$($cmd.BaseName) -> $($cmd.FullName)"
    if ($WhatIf) { continue }
    New-Item -ItemType Directory -Force -Path $globalCommands | Out-Null
    if (Test-Path -LiteralPath $dest) {
        $backup = Join-Path $env:LOCALAPPDATA "MindAttic\share-scripts-backup\$stamp\_global\commands"
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Copy-Item -LiteralPath $dest -Destination (Join-Path $backup $cmd.Name)
    }
    Copy-Item -LiteralPath $cmd.FullName -Destination $dest -Force
}

# ── Repos: drop identical copies and the settings entries that run them ─────
$left = @()
foreach ($repo in Get-ChildItem -LiteralPath $WorkspaceRoot -Directory) {
    $settingsPath = Join-Path $repo.FullName '.claude\settings.json'
    $settings = if (Test-Path $settingsPath) { Read-Json $settingsPath } else { $null }
    $changed = $false
    foreach ($s in $scripts) {
        $local = Join-Path $repo.FullName $s.Local
        if (-not (Test-Path $local)) { continue }
        if ((Get-Md5 $local) -ne $s.Original) { $left += "$($repo.Name): $($s.Local) differs from the common copy; kept"; continue }

        $needle = $s.Local.Replace('\', '/')
        if ($settings) {
            if ($s.Name -eq 'statusline' -and $settings.PSObject.Properties.Name -contains 'statusLine' -and "$($settings.statusLine.command)".Replace('\','/') -like "*$needle*") {
                $settings.PSObject.Properties.Remove('statusLine'); $changed = $true
            }
            if ($s.Name -eq 'quickload' -and $settings.PSObject.Properties.Name -contains 'hooks' -and $settings.hooks.PSObject.Properties.Name -contains 'UserPromptSubmit') {
                $groups = @($settings.hooks.UserPromptSubmit | ForEach-Object {
                    $_.hooks = @($_.hooks | Where-Object { "$($_.command)".Replace('\','/') -notlike "*$needle*" }); $_ } | Where-Object { @($_.hooks).Count -gt 0 })
                if ($groups.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove('UserPromptSubmit') } else { $settings.hooks.UserPromptSubmit = $groups }
                if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
                $changed = $true
            }
        }
        Write-Output "$($repo.Name): uses the shared $($s.Name); removing $($s.Local)"
        if (-not $WhatIf) { Remove-Item -LiteralPath $local }
    }
    if ($changed -and -not $WhatIf) { Save-Json $settingsPath $settings }
}

foreach ($l in $left) { Write-Output "kept: $l" }
if ($WhatIf) { Write-Output 'WhatIf: nothing was changed.' }
