#Requires -Version 5.1
<#
.SYNOPSIS
    Content-addressable hash of a built mod payload, for /publish's no-op guard.

.DESCRIPTION
    Hashes relative path + bytes of every file under -Path (sorted, so file-system enumeration
    order never matters), excluding any filename in -ExcludeNames (case-insensitive, matched
    against the file's own name, not its path). Deliberately NOT a hash of a zip: zip format
    embeds timestamps and can reorder/recompress identical content differently between builds,
    which would make an unchanged mod look "changed". This hashes the actual payload bytes
    instead, so two builds of byte-identical source always produce the same hash regardless of
    when or how many times they were built.

    Exclude the mod's own metadata/doc files (manifest.json, CHANGELOG.md, README.md, nexus.json,
    thunderstore.toml) from -ExcludeNames when calling this for a no-op check: those are expected
    to change on every real publish (version bump, changelog entry) independent of whether the
    compiled/packaged payload changed, and including them would make the hash never repeat.

.PARAMETER Path
    Directory containing the built mod payload (e.g. the installed mod folder before zipping, or
    GTFO's package/ folder).

.PARAMETER ExcludeNames
    File names (not paths) to leave out of the hash, e.g. 'manifest.json','CHANGELOG.md','README.md'.

.OUTPUTS
    Lowercase hex SHA-256 string.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$ExcludeNames = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "compute-mod-hash.ps1: '$Path' is not a directory."
}

$root = (Resolve-Path -LiteralPath $Path).Path
$excludeSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]($ExcludeNames | ForEach-Object { $_.ToLowerInvariant() }),
    [System.StringComparer]::OrdinalIgnoreCase)

$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { -not $excludeSet.Contains($_.Name.ToLowerInvariant()) } |
    Sort-Object { $_.FullName.Substring($root.Length).Replace('\', '/').TrimStart('/') }

$sha = [System.Security.Cryptography.SHA256]::Create()
$ms = New-Object System.IO.MemoryStream
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length).Replace('\', '/').TrimStart('/')
        $relBytes = [System.Text.Encoding]::UTF8.GetBytes($rel + "`n")
        $ms.Write($relBytes, 0, $relBytes.Length)
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $ms.Write($bytes, 0, $bytes.Length)
    }
    $ms.Position = 0
    $hashBytes = $sha.ComputeHash($ms)
} finally {
    $ms.Dispose()
    $sha.Dispose()
}

return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
