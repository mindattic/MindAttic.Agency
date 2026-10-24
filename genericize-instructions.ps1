[CmdletBinding()]
param([string]$WorkspaceRoot,[string]$ArchivePath)
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $PSScriptRoot 'legacy-instructions' }
$names=@('CLAUDE.md','CODEX.md','GEMINI.md','KIMI.md','DEEPSEEK.md','MISTRAL.md','LLAMA.md','COPILOT.md','AI.md')
$files=Get-ChildItem $WorkspaceRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object {$names -contains $_.Name -and $_.FullName -notmatch '\\(node_modules|PackageCache|\.git|mindattic-agent-standard|codex-standard)\\'}
New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
$agentMdPath = Join-Path $WorkspaceRoot 'MINDATTIC_AGENT.md'
$stub=@('# Provider compatibility forwarder','', "Read the canonical global instructions at $agentMdPath, then",'mindattic-agent-standard\AGENTS.md and the current project documentation. This file intentionally','contains no vendor-specific behavior or duplicated workflow.')
foreach($f in $files){
  $rel=$f.FullName.Substring(([IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')+'\').Length)
  $dest=Join-Path $ArchivePath ($rel -replace '[\\/:]','__')
  if(-not (Test-Path $dest)){Set-Content -LiteralPath $dest -Value (Get-Content $f.FullName -Raw) -Encoding UTF8}
  Set-Content -LiteralPath $f.FullName -Value $stub -Encoding UTF8
}
Write-Output "genericized=$($files.Count)"
