#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the Thunderstore API token from the MindAttic Vault APPDATA store (MindAttic:Vault:Thunderstore).

.DESCRIPTION
    Single source of truth per the Vault convention: %APPDATA%\MindAttic\Thunderstore\tokens.json,
    { "apiKey": "..." }. Generate a service account token at https://thunderstore.io/settings/teams/
    (pick the team the package is published under, then Service Accounts).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path $env:APPDATA 'MindAttic\Thunderstore\tokens.json'
if (-not (Test-Path -LiteralPath $path)) {
    throw "No Thunderstore API token found at $path. Generate one at https://thunderstore.io/settings/teams/ (Service Accounts), then save it there as { ""apiKey"": ""..."" }."
}
$json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if (-not $json.apiKey) {
    throw "$path exists but has no 'apiKey' field."
}
return $json.apiKey
