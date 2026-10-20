<#
.SYNOPSIS
    Opts one MindAttic repo into the shared DocFX -> GitHub Pages docs site (HOUSE-LAW-14).

.DESCRIPTION
    1. Writes the thin caller .github/workflows/docs.yml, which runs MindAttic.Toolkit's reusable
       docs-pages.yml on every push to main.
    2. Retires the old codex README.htm renderer: deletes tools/build-readme.ps1 (or .js), README.htm,
       and tools/ if that leaves it empty.
    3. Turns GitHub Pages on for the repo with build_type=workflow, and sets the repo's homepage to the
       site when it has none.
    4. Lists any file that still mentions build-readme or README.htm, for a hand fix.

    It does not commit: the change belongs to the repo's own docs ticket.

.EXAMPLE
    powershell -File shared\docs-site\adopt-docs-site.ps1 -Repo MindAttic.Legion -Api
.EXAMPLE
    powershell -File shared\docs-site\adopt-docs-site.ps1 -Repo Claudia -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [switch]$Api,
    [string]$RunsOn = 'ubuntu-latest',
    [string]$Workspace = 'D:\Projects\MindAttic',
    [string]$Owner = 'mindattic',
    [switch]$SkipGitHub
)

$ErrorActionPreference = 'Stop'
$root = if (Test-Path -LiteralPath $Repo) { (Resolve-Path -LiteralPath $Repo).Path } else { Join-Path $Workspace $Repo }
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw "Not a repo: $root" }
$name = Split-Path -Leaf $root
$siteUrl = "https://$Owner.github.io/$name/"

$with = @()
if ($Api) { $with += '      api: true' }
if ($RunsOn -ne 'ubuntu-latest') { $with += "      runs-on: $RunsOn" }
$caller = @(
    '# Publishes this repo''s docs (README.md as the home page, docs/ as articles) to GitHub Pages.'
    '# The build lives once, in MindAttic.Toolkit; see HOUSE-LAW-14.'
    'name: docs'
    ''
    'on:'
    '  push:'
    '    branches: [main]'
    '  workflow_dispatch:'
    ''
    'permissions:'
    '  contents: read'
    '  pages: write'
    '  id-token: write'
    ''
    'jobs:'
    '  docs:'
    "    uses: $Owner/MindAttic.Toolkit/.github/workflows/docs-pages.yml@main"
)
if ($with) { $caller += @('    with:') + $with }
$callerPath = Join-Path $root '.github\workflows\docs.yml'
if ($PSCmdlet.ShouldProcess($callerPath, 'write docs workflow')) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $callerPath) -Force | Out-Null
    [IO.File]::WriteAllText($callerPath, (($caller -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    Write-Host "[adopt] wrote .github/workflows/docs.yml"
}

foreach ($old in @('tools\build-readme.ps1', 'tools\build-readme.js', 'README.htm')) {
    $p = Join-Path $root $old
    if ((Test-Path -LiteralPath $p) -and $PSCmdlet.ShouldProcess($p, 'delete retired README.htm renderer file')) {
        Remove-Item -LiteralPath $p -Force
        Write-Host "[adopt] removed $old"
    }
}
$tools = Join-Path $root 'tools'
if ((Test-Path -LiteralPath $tools) -and -not (Get-ChildItem -LiteralPath $tools -Force) -and $PSCmdlet.ShouldProcess($tools, 'remove empty folder')) {
    Remove-Item -LiteralPath $tools -Force
    Write-Host '[adopt] removed empty tools/'
}

if (-not $SkipGitHub) {
    # gh writes a 404 to stderr; Windows PowerShell would turn that into a terminating error.
    $ErrorActionPreference = 'Continue'
    $slug = "$Owner/$name"
    $null = gh api "repos/$slug/pages" 2>$null
    $exists = $LASTEXITCODE -eq 0
    if ($PSCmdlet.ShouldProcess($slug, 'enable GitHub Pages (build_type=workflow)')) {
        $method = if ($exists) { 'PUT' } else { 'POST' }
        $null = gh api -X $method "repos/$slug/pages" -f build_type=workflow
        if ($LASTEXITCODE) { throw "gh api $method repos/$slug/pages failed" }
        Write-Host "[adopt] Pages on for $slug (build_type=workflow)"
    }
    $homepage = gh repo view $slug --json homepageUrl --jq .homepageUrl
    if (-not $homepage -and $PSCmdlet.ShouldProcess($slug, "set homepage to $siteUrl")) {
        gh repo edit $slug --homepage $siteUrl | Out-Null
        Write-Host "[adopt] homepage -> $siteUrl"
    } elseif ($homepage -and $homepage -ne $siteUrl) {
        Write-Host "[adopt] homepage left as $homepage"
    }
}

$stale = @(git -C $root grep -l -I -E 'build-readme|README\.htm' -- . ':!docs/USER_STORIES.md' 2>$null)
if ($stale.Count) {
    Write-Warning "Still mentions build-readme / README.htm (fix by hand):"
    $stale | ForEach-Object { Write-Warning "  $_" }
}
Write-Host "[adopt] $name -> $siteUrl (live after the docs workflow's first run on main)"
