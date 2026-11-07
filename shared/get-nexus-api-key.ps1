#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the Nexus Mods API key from the MindAttic Vault APPDATA store (MindAttic:Vault:Nexus).

.DESCRIPTION
    Single source of truth per the Vault convention: %APPDATA%\MindAttic\Nexus\tokens.json,
    { "apiKey": "..." }. Generate a key at https://next.nexusmods.com/settings/api-keys.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path $env:APPDATA 'MindAttic\Nexus\tokens.json'
if (-not (Test-Path -LiteralPath $path)) {
    throw "No Nexus API key found at $path. Generate one at https://next.nexusmods.com/settings/api-keys, then save it there as { ""apiKey"": ""..."" }."
}
$json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if (-not $json.apiKey) {
    throw "$path exists but has no 'apiKey' field."
}
return $json.apiKey
