#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps the workspace root's mindattic-agent-standard/ folder in sync with this repo (MAT-T50).

.DESCRIPTION
    This repo is the canonical MindAttic Agent Standard. D:\Projects\MindAttic\mindattic-agent-standard\
    is a legacy mirror left over from before the standard was pulled into its own repo, and Claude Code's
    global statusline actually runs the copy there (see share-scripts.ps1). Left alone, the two drift in
    both directions: MAT-T26's readiness sweep found AGENTS.md's HOUSE-LAW-12/14 sections, the autopilot
    -> /allocate rename, and two statusline.ps1 fixes (M.ORCH-T479, M.ORCH-T286) had landed only in the
    mirror, while this repo had independently gained MAT-T30/39/40/41/42/43/44/45 that never made it back
    out to the mirror (MAT-T50).

    This repo is the one source of truth: every tracked file here (other than its own repo-local .agent/
    state, .github/ workflows, .gitignore and docs/USER_STORIES.md -- none of which belong in the shared
    standard) should be byte-identical to its counterpart under the workspace root's mindattic-agent-standard/.

.PARAMETER WorkspaceRoot
    Defaults to this repo's own parent folder (the convention clone-repo.ps1/export-catalog.ps1 already
    use), i.e. this script expects to be run from the real checkout at <WorkspaceRoot>\MindAttic.Agency.

.PARAMETER Check
    Report drift only; change nothing. Exits 1 if anything differs or is missing, so this can gate a
    readiness sweep or be run from share-scripts.ps1 without it making changes on its own.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$target = Join-Path $WorkspaceRoot 'mindattic-agent-standard'

function Get-Md5([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLowerInvariant() }

Push-Location $PSScriptRoot
try {
    $files = @(git ls-files | Where-Object {
        $_ -ne '.gitignore' -and
        $_ -ne 'docs/USER_STORIES.md' -and
        $_ -notlike '.agent/*' -and
        $_ -notlike '.github/*'
    })
} finally {
    Pop-Location
}

$drift = @()
foreach ($rel in $files) {
    $relPath = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
    $src = Join-Path $PSScriptRoot $relPath
    $dest = Join-Path $target $relPath
    $same = (Test-Path -LiteralPath $dest -PathType Leaf) -and ((Get-Md5 $src) -eq (Get-Md5 $dest))
    if ($same) { continue }
    $drift += $rel
    if ($Check) {
        Write-Output "drift: $rel"
    } else {
        Write-Output "sync: $rel"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
}

if ($Check) {
    if ($drift.Count -eq 0) { Write-Output "mindattic-agent-standard is in sync with $PSScriptRoot." }
    else {
        Write-Output "$($drift.Count) file(s) under mindattic-agent-standard differ from or are missing from this repo; run sync-workspace-copy.ps1 (no -Check) to fix."
        exit 1
    }
} elseif ($drift.Count -eq 0) {
    Write-Output 'Already in sync; nothing copied.'
} else {
    Write-Output "Copied $($drift.Count) file(s) to $target."
}
