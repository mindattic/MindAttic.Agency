#Requires -Version 5.1
<#
.SYNOPSIS
    Local fallback for /publish: uploads a mod's already-built dist zip to NexusMods as a new file
    version, without going through GitHub Actions.

.DESCRIPTION
    Runs the official Nexus-Mods/upload-action code directly with Node (vendored at
    shared/vendor/nexus-upload-action, pinned to v1.0.0-beta.11, see its NOTICE.md), fed the same
    INPUT_*/GITHUB_OUTPUT environment contract GitHub Actions would give it. The API key comes from
    the Nexus Vault bucket (get-nexus-api-key.ps1), never from an argument or the repo.

.PARAMETER RepoPath
    The mod repo root (must contain nexus.json: modId, fileId, modFolderName, project, category).
    Defaults to the current directory.

.PARAMETER Changelog
    Optional changelog text to attach to this version (requires nexus.json's modId).
#>
[CmdletBinding()]
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$Changelog = ''
)

$ErrorActionPreference = 'Stop'

$nexusConfigPath = Join-Path $RepoPath 'nexus.json'
if (-not (Test-Path -LiteralPath $nexusConfigPath)) {
    throw "$nexusConfigPath not found - this repo has no Nexus publish configured."
}
$cfg = Get-Content -LiteralPath $nexusConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.fileId -or $cfg.fileId -eq 0) {
    throw "nexus.json's fileId is missing/0 - fill it in from the mod page's Files tab (API Info) or Manage Files (edit) first."
}

$distDir = Join-Path $RepoPath 'dist'
$zip = Get-ChildItem -LiteralPath $distDir -Filter "$($cfg.modFolderName)-*.zip" -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) {
    throw "No $($cfg.modFolderName)-*.zip found in $distDir - build first: dotnet build $($cfg.project) -c Release"
}
if ($zip.BaseName -notmatch "^$([regex]::Escape($cfg.modFolderName))-(.+)$") {
    throw "Could not parse a version out of $($zip.Name)."
}
$version = $Matches[1]

$apiKey = & (Join-Path $PSScriptRoot 'get-nexus-api-key.ps1')

$env:INPUT_API_KEY = $apiKey
$env:INPUT_FILE_ID = "$($cfg.fileId)"
$env:INPUT_MOD_ID = "$($cfg.modId)"
$env:INPUT_FILENAME = $zip.FullName
$env:INPUT_VERSION = $version
$env:INPUT_CATEGORY = $(if ($cfg.category) { $cfg.category } else { 'main' })
$env:INPUT_CHANGELOG = $Changelog
$env:INPUT_ARCHIVE_EXISTING_VERSION = 'false'
$env:INPUT_ALLOW_MOD_MANAGER_DOWNLOAD = 'true'
$env:INPUT_PRIMARY_MOD_MANAGER_DOWNLOAD = 'false'
$env:INPUT_SHOW_REQUIREMENTS_POP_UP = 'false'
$env:INPUT_UPDATE_MOD_VERSION = 'false'

$outputFile = New-TemporaryFile
$env:GITHUB_OUTPUT = $outputFile.FullName
try {
    node (Join-Path $PSScriptRoot 'vendor\nexus-upload-action\index.js')
    if ($LASTEXITCODE -ne 0) { throw "Upload action exited with code $LASTEXITCODE." }
    Write-Output "Published $($zip.Name) as version $version to Nexus mod $($cfg.modId) file $($cfg.fileId)."
    Get-Content -LiteralPath $outputFile.FullName -ErrorAction SilentlyContinue
} finally {
    Remove-Item Env:\INPUT_API_KEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputFile.FullName -ErrorAction SilentlyContinue
}
