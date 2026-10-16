[CmdletBinding()]
param(
  [string]$WorkspaceRoot,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
$shared = Join-Path $WorkspaceRoot 'mindattic-agent-standard\shared\hooks\commit-msg'
$marker = '# mindattic-commit-msg'
$sharedSh = $shared -replace '\\','/'
$shim = "#!/bin/sh`n$marker`nexec sh `"$sharedSh`" `"`$@`"`n"

$repos = @(Get-Item -LiteralPath $WorkspaceRoot) + @(Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Force) |
  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container }

foreach ($repo in $repos) {
  $hooksPath = git -C $repo.FullName config --local --get core.hooksPath
  $hooksDir = if ($hooksPath) {
    if ([IO.Path]::IsPathRooted($hooksPath)) { $hooksPath } else { Join-Path $repo.FullName $hooksPath }
  } else { Join-Path $repo.FullName '.git\hooks' }
  $target = Join-Path $hooksDir 'commit-msg'

  if ((Test-Path -LiteralPath $target) -and -not ((Get-Content -LiteralPath $target -Raw) -match [regex]::Escape($marker))) {
    Write-Output "skipped $($repo.Name): it has its own commit-msg hook ($target)"
    continue
  }
  if ((Test-Path -LiteralPath $target) -and (Get-Content -LiteralPath $target -Raw) -eq $shim) { continue }
  if ($WhatIf) { Write-Output "would install $target"; continue }
  New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
  [IO.File]::WriteAllText($target, $shim, [Text.UTF8Encoding]::new($false))
  $tracked = if ($hooksPath) { ' (tracked in the repo: commit it under its own ticket)' } else { '' }
  Write-Output "installed $target$tracked"
}
exit 0
