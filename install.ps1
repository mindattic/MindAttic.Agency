[CmdletBinding()]
param(
  [string]$WorkspaceRoot,
  [string]$GlobalClaudeRoot = "$env:USERPROFILE\.claude",
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
$shared = Join-Path $WorkspaceRoot 'mindattic-agent-standard'
$excluded = @('.git','.vs','_dropbox','codex-standard')
$projects = Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Force |
  Where-Object { $excluded -notcontains $_.Name -and ((Test-Path (Join-Path $_.FullName '.git')) -or (Test-Path (Join-Path $_.FullName '.claude'))) }

$agentText = @"
# MindAttic project agent entrypoint

Read the shared protocol at `..\mindattic-agent-standard\AGENTS.md` and this project's own
documentation. Common prompt commands are implemented by the shared runner; do not add a second
copy under a provider-specific command folder.
"@
$commandText = @"
# Portable command

Invoke `..\mindattic-agent-standard\prose-agent.ps1` with the command name and `-RepoRoot (Get-Location)`.
See `..\mindattic-agent-standard\README.md`.
"@
$globalCommandDir = Join-Path $GlobalClaudeRoot 'commands'
$globalNames = @(Get-ChildItem $globalCommandDir -File -ErrorAction SilentlyContinue | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' })

foreach ($project in $projects) {
  $agentPath = Join-Path $project.FullName 'AGENTS.md'
  $commandDir = Join-Path $project.FullName '.prose\commands'
  if ($WhatIf) { Write-Output "would install $($project.Name)"; continue }
  if (-not (Test-Path $agentPath)) { Set-Content -LiteralPath $agentPath -Value $agentText -Encoding UTF8 }
  New-Item -ItemType Directory -Path $commandDir -Force | Out-Null
  # do/quicksave/quickload/commit/deploy are now real global commands at
  # $GlobalClaudeRoot\commands (see AGENTS.md) and get picked up by the $globalNames loop below.
  # Only progress/show/bootstrap/queue have no global file of their own — they're reached by
  # invoking prose-agent.ps1 directly, so a non-Claude client still needs a pointer for them.
  foreach ($name in @('progress','show','bootstrap','queue')) {
    $path = Join-Path $commandDir "$name.md"
    if (-not (Test-Path $path)) { Set-Content -LiteralPath $path -Value ($commandText -replace 'Portable command',"Portable command: $name") -Encoding UTF8 }
  }
  $legacyCommands = Join-Path $project.FullName '.claude\commands'
  foreach ($legacy in Get-ChildItem $legacyCommands -File -ErrorAction SilentlyContinue) {
    $name = [IO.Path]::GetFileNameWithoutExtension($legacy.Name)
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { continue }
    $path = Join-Path $commandDir "$name.md"
    if (-not (Test-Path $path)) {
      $base = ([IO.Path]::GetFullPath($project.FullName).TrimEnd('\') + '\')
      $source = ([IO.Path]::GetFullPath($legacy.FullName)).Substring($base.Length)
      @"
# Portable command: /$name

This alias is provider-neutral. Read the legacy source at `$source` for this project's intent,
then execute it using the available client tools and the shared MindAttic Agent Standard.
Do not require Claude, Codex, or a specific vendor to interpret this command.
"@ | Set-Content -LiteralPath $path -Encoding UTF8
    }
  }
  foreach ($name in $globalNames) {
    $path = Join-Path $commandDir "$name.md"
    if (-not (Test-Path $path)) {
      @"
# Portable global command: /$name

This alias is available in every MindAttic project. Resolve its current definition from the
central MindAttic Agent Standard command catalog, then execute it with the available client tools.
It must work without requiring a Claude or OpenAI-specific runtime.
"@ | Set-Content -LiteralPath $path -Encoding UTF8
    }
  }
  Write-Output "installed $($project.Name)"
}

& (Join-Path $shared 'install-commit-hooks.ps1') -WorkspaceRoot $WorkspaceRoot -WhatIf:$WhatIf

# One shared statusline and quickload hook instead of a copy per repo.
& (Join-Path $shared 'share-scripts.ps1') -WorkspaceRoot $WorkspaceRoot -GlobalClaudeRoot $GlobalClaudeRoot -WhatIf:$WhatIf
