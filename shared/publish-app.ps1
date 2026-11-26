#Requires -Version 5.1
<#
.SYNOPSIS
    /publish for apps: builds a repo and deploys it to R:\MindAttic\Apps\<repo>\Release (release) or \Debug (dev).

.DESCRIPTION
    Release is the one definitive release candidate of each app (filmable on its own); Debug is the working copy.
      /publish, /publish dev       -> publish-app.ps1 -Mode dev       (this repo, Debug)
      /publish release             -> publish-app.ps1 -Mode release   (this repo, Release)
      /publish all dev|release     -> publish-app.ps1 -All -Mode ...  (every deployable repo in docs/workspace-repos.json)

    The per-kind build logic lives in deploy-lib.ps1 (dot-sourced; MAT-T277). How a repo is built is Get-Plan's call:
      1. <repo>\.agent\publish.json  { "kind": "script", "command": "...{out}...{config}..." }  or
                                     { "kind": "dotnet", "projects": ["src/App/App.csproj"] }  or
                                     { "kind": "unity", "project": "subfolder" }  or  { "kind": "unreal" }  or  { "kind": "none" }
      2. Unreal project (.uproject at the root or one level down): Publish-Unreal (Debug = DebugGame else Development, Release = Shipping).
      3. Unity project (ProjectSettings\ProjectVersion.txt at the root or one level down): Publish-Unity -Target Android
         builds an APK, then play.json, play.ps1 and play.bat are written next to it (Android.Emulator.Suite's
         device/action menu).
      4. .NET: Publish-DotNet (Debug framework-dependent, Release self-contained win-x64 single-file).
      5. run.ps1 / deploy.ps1 (root or tools\) that takes -Out: Publish-Script runs it with -Out <folder>.
    Mod repos (nexus.json / thunderstore.toml) are skipped here; bare /publish there is the mod release flow.
    -All also skips repos whose workspace-repos.json Kind is library, site or hardware, and the archived SpaceGod race
    repos.

    The build goes to <folder>.staging first; processes running from the folder are stopped, then the folder is
    replaced. <folder>\.publish.json records the repo, mode, commit and time. -DryRun lists each repo's kind and
    target folder without building anything.

.EXAMPLE
    powershell -File publish-app.ps1 -Repo Android.Emulator.Suite -Mode release
    powershell -File publish-app.ps1 -All -Mode dev
    powershell -File publish-app.ps1 -All -DryRun
#>
param(
    [string]$Repo,
    [ValidateSet('dev', 'release')][string]$Mode = 'dev',
    [switch]$All,
    [switch]$DryRun,
    [string]$Root = 'D:\Projects\MindAttic',
    [string]$AppsRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')
if (-not $AppsRoot) { $AppsRoot = $DeployLibAppsRoot }
$config = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }

# -All never publishes these: workspace-repos.json kinds with nothing to run, and the archived SpaceGod race repos.
$skipKinds = 'library', 'site', 'hardware'
$archived = 'SpaceGod.Unreal.Cpp', 'SpaceGod.Unreal.CSharp', 'SpaceGod.Unity.CSharp', 'Unreal.SpaceGod'

function Get-RepoRoot([string]$name) {
    if (-not $name) { $top = git rev-parse --show-toplevel 2>$null; if (-not $top) { throw 'Not in a git repo; pass -Repo.' }; return (Resolve-Path $top).Path }
    if (Test-Path $name) { return (Resolve-Path $name).Path }
    $p = Join-Path $Root $name
    if (Test-Path $p) { return $p }
    throw "No repo '$name' under $Root"
}

function Invoke-UnityApk([string]$repoName, [string]$project, [string]$stage) {
    # Publish-Unity builds the APK (Debug -> development build); this adds the play.json / play.bat device menu.
    $r = @(Publish-Unity -Project $project -RepoName $repoName -Config $config -Out $stage -Target Android -AppsRoot $AppsRoot) | Select-Object -Last 1
    $apk = $r.Path
    $info = Get-Content "$apk.json" -Raw | ConvertFrom-Json
    Remove-Item "$apk.json"
    $id = ($repoName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') + "-$Mode"
    $play = [ordered]@{
        id = $id; name = "$($info.name) ($config)"; package = $info.package; apk = (Split-Path -Leaf $apk)
        buildCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Repo $repoName -Mode $Mode"
        minSdk = $info.minSdk; orientation = $info.orientation; version = $info.version
    }
    $play | ConvertTo-Json | Set-Content (Join-Path $stage 'play.json') -Encoding UTF8
    # Android.Emulator.Suite's deploy.ps1 now writes its play\ folder under the R: AppsRoot (AES-T12).
    $suitePlay = Join-Path $AppsRoot 'Android.Emulator.Suite\Release\play'
    if (-not (Test-Path (Join-Path $suitePlay 'play.ps1'))) { $suitePlay = Join-Path $Root 'Android.Emulator.Suite\tools' }
    if (-not (Test-Path (Join-Path $suitePlay 'play.ps1'))) { Write-Host "Android.Emulator.Suite's play.ps1 wasn't found; the APK is there without a launcher." -ForegroundColor Yellow }
    else { Copy-Item (Join-Path $suitePlay 'play.ps1'), (Join-Path $suitePlay 'play.bat') $stage -Force }
}

function Publish-Repo([string]$repo) {
    $name = Split-Path -Leaf $repo
    $plan = Get-Plan $repo
    if (-not $plan) { return [pscustomobject]@{ Repo = $name; Result = 'skipped'; Detail = 'nothing deployable (library, mod or docs repo)' } }
    $target = Get-DeployTarget -RepoName $name -Config $config -AppsRoot $AppsRoot
    if ($DryRun) { return [pscustomobject]@{ Repo = $name; Result = "would publish ($($plan.Kind))"; Detail = $target } }
    $stage = "$target.staging"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Write-Host "== $name -> $target ($($plan.Kind))" -ForegroundColor Cyan
    try {
        switch ($plan.Kind) {
            'unity' { Invoke-UnityApk $name $plan.Project $stage }
            'unreal' { Publish-Unreal -Repo $repo -Out $stage -Config $config }
            'dotnet' { Publish-DotNet -Projects $plan.Projects -Out $stage -Config $config }
            default { Publish-Script -Plan $plan -Repo $repo -Out $stage -Config $config -Mode $Mode }
        }
    }
    catch {
        Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Repo = $name; Result = 'FAILED'; Detail = $_.Exception.Message }
    }

    Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) } catch { $false } } | Stop-Process -Force
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $stage $target
    Write-PublishSidecar -Repo $repo -Target $target -Mode $Mode -Config $config -Kind $plan.Kind
    return [pscustomobject]@{ Repo = $name; Result = 'published'; Detail = $target }
}

$results = @()
if ($All) {
    $list = (Get-Content (Join-Path $Root 'docs\workspace-repos.json') -Raw | ConvertFrom-Json).Repos |
        Where-Object { $_.Kind -notin $skipKinds -and $_.Name -notin $archived } | ForEach-Object { $_.Name }
    foreach ($n in $list) {
        $p = Join-Path $Root $n
        if (Test-Path (Join-Path $p '.git')) { $results += Publish-Repo $p }
    }
} else {
    $results += Publish-Repo (Get-RepoRoot $Repo)
}
$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
if ($results | Where-Object { $_.Result -eq 'FAILED' }) { exit 1 }
