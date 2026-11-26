#Requires -Version 5.1
<#
.SYNOPSIS
    Shared deploy library: the per-kind pieces of /publish, one copy for publish-app.ps1 and every app repo's run.ps1.

.DESCRIPTION
    Dot-source it; it defines functions and one default, and runs nothing:
        . (Join-Path <agent-standard>\shared 'deploy-lib.ps1')

    Apps deploy to <AppsRoot>\<repo>\Debug (framework-dependent, the dev/test copy) and
    <AppsRoot>\<repo>\Release (standalone, the copy a player double-clicks). AppsRoot defaults to
    R:\MindAttic\Apps ($DeployLibAppsRoot).

    Functions (moved from publish-app.ps1 unchanged, MAT-T275):
      Get-Plan <repo>            How a repo is built, first match wins:
                                   1. <repo>\.agent\publish.json  { "kind": "script"|"dotnet"|"unity"|"none", ... }
                                   2. a Unity project (ProjectSettings\ProjectVersion.txt at the root or one level down)
                                   3. .NET Exe/WinExe/Web projects (not tests, benches or samples)
                                   4. run.ps1 / deploy.ps1 (root or tools\) that takes -Out / -OutDir
                                 Mod repos (nexus.json / thunderstore.toml) and anything else return $null.
      Get-UnityProject, Get-DotnetApps, Get-OutScript   Get-Plan's detectors.
      Get-DeployTarget           <AppsRoot>\<repo>\<Debug|Release>.
      Publish-Script             Runs a plan of kind 'outscript' (the repo's own script with -Out <folder>) or
                                 'script' (.agent\publish.json's command with {out}/{config}/{mode} filled in).
      Write-PublishSidecar       Writes <target>\.publish.json (repo, mode, configuration, kind, commit, dirty, time).

    Publish-DotNet / Publish-Unity / Publish-Unreal land here in their own tickets (MAT-T276, MAT-T270, MAT-T271).
#>

$DeployLibAppsRoot = 'R:\MindAttic\Apps'

function Get-UnityProject([string]$repo) {
    foreach ($d in @($repo) + @(Get-ChildItem $repo -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
        if (Test-Path (Join-Path $d 'ProjectSettings\ProjectVersion.txt')) { return $d }
    }
    return $null
}

function Get-DotnetApps([string]$repo) {
    Get-ChildItem $repo -Recurse -Filter *.csproj -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|Library|Packages|\.git)\\' -and $_.BaseName -notmatch '(Tests?|Bench(marks?)?|Samples?|Harness)$' } |
        Where-Object {
            $x = Get-Content $_.FullName -Raw
            $x -match '<OutputType>\s*(WinExe|Exe)\s*</OutputType>' -or $x -match 'Sdk="Microsoft\.NET\.Sdk\.(Web|BlazorWebAssembly|Razor)"'
        } | ForEach-Object { $_.FullName }
}

function Get-OutScript([string]$repo) {
    foreach ($rel in 'run.ps1', 'deploy.ps1', 'tools\run.ps1', 'tools\deploy.ps1') {
        $p = Join-Path $repo $rel
        if (-not (Test-Path $p)) { continue }
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
        if ($ast.ParamBlock -and ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -in 'Out', 'OutDir' })) {
            return @{ Path = $p; Param = ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -in 'Out', 'OutDir' } | Select-Object -First 1).Name.VariablePath.UserPath }
        }
    }
    return $null
}

function Get-Plan([string]$repo) {
    $cfgFile = Join-Path $repo '.agent\publish.json'
    if (Test-Path $cfgFile) {
        $c = Get-Content $cfgFile -Raw | ConvertFrom-Json
        switch ($c.kind) {
            'none' { return $null }
            'script' { return @{ Kind = 'script'; Command = $c.command } }
            'dotnet' { return @{ Kind = 'dotnet'; Projects = @($c.projects | ForEach-Object { Join-Path $repo $_ }) } }
            'unity' { return @{ Kind = 'unity'; Project = $(if ($c.project) { Join-Path $repo $c.project } else { Get-UnityProject $repo }) } }
        }
    }
    if ((Test-Path (Join-Path $repo 'nexus.json')) -or (Test-Path (Join-Path $repo 'thunderstore.toml'))) { return $null }
    $u = Get-UnityProject $repo
    if ($u) { return @{ Kind = 'unity'; Project = $u } }
    $apps = @(Get-DotnetApps $repo)
    if ($apps.Count) { return @{ Kind = 'dotnet'; Projects = $apps } }
    $s = Get-OutScript $repo
    if ($s) { return @{ Kind = 'outscript'; Script = $s.Path; Param = $s.Param } }
    return $null
}

function Get-DeployTarget {
    param(
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Config,
        [string]$AppsRoot = $DeployLibAppsRoot
    )
    if (-not $AppsRoot) { $AppsRoot = 'R:\MindAttic\Apps' }
    return (Join-Path (Join-Path $AppsRoot $RepoName) $Config)
}

function Publish-Script {
    <# Runs an 'outscript' or 'script' plan from Get-Plan into $Out. Throws on a non-zero exit. #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Out,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Config,
        [Parameter(Mandatory)][ValidateSet('dev', 'release')][string]$Mode
    )
    switch ($Plan.Kind) {
        'outscript' {
            $splat = @{ $Plan.Param = $Out }
            & $Plan.Script @splat
            if ($LASTEXITCODE) { throw "$(Split-Path -Leaf $Plan.Script) failed ($LASTEXITCODE)" }
        }
        'script' {
            $cmd = $Plan.Command.Replace('{out}', $Out).Replace('{config}', $Config).Replace('{mode}', $Mode)
            Push-Location $Repo
            try { cmd.exe /c $cmd; if ($LASTEXITCODE) { throw "publish command failed ($LASTEXITCODE): $cmd" } } finally { Pop-Location }
        }
        default { throw "Publish-Script runs 'outscript' or 'script' plans, not '$($Plan.Kind)'." }
    }
}

function Write-PublishSidecar {
    <# Writes <Target>\.publish.json recording what was published, from where, and when. #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('dev', 'release')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Config,
        [Parameter(Mandatory)][string]$Kind
    )
    $name = Split-Path -Leaf $Repo
    [ordered]@{ repo = $name; mode = $Mode; configuration = $Config; kind = $Kind
        commit = (git -C $Repo rev-parse HEAD 2>$null); dirty = [bool](git -C $Repo status --porcelain 2>$null)
        publishedAt = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $Target '.publish.json') -Encoding UTF8
}

function Get-UnrealPackageHook([string]$repo) {
    <# The Unreal repo's own package script, for Publish-Unreal (MAT-T271): the first of tools\package.ps1, package.ps1,
       tools\run.ps1, run.ps1 whose param block takes -Configuration. Returns @{ Path; Configs (its ValidateSet, or
       $null when open); OutParam (-Out/-OutDir/-ArchiveDirectory when it takes one, else $null); Params (all names) }. #>
    foreach ($rel in 'tools\package.ps1', 'package.ps1', 'tools\run.ps1', 'run.ps1') {
        $p = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
        if (-not $ast.ParamBlock) { continue }
        $params = @($ast.ParamBlock.Parameters)
        $cfg = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Configuration' } | Select-Object -First 1
        if (-not $cfg) { continue }
        $set = $cfg.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | Select-Object -First 1
        $configs = if ($set) { @($set.PositionalArguments | ForEach-Object { $_.SafeGetValue() }) } else { $null }
        $names = @($params | ForEach-Object { $_.Name.VariablePath.UserPath })
        $outParam = $names | Where-Object { $_ -in 'Out', 'OutDir', 'ArchiveDirectory' } | Select-Object -First 1
        return @{ Path = $p; Configs = $configs; OutParam = $outParam; Params = $names }
    }
    return $null
}

function Publish-Unreal {
    <#
    Packages an Unreal repo through its own package hook (Get-UnrealPackageHook) and deploys the package into $Out
    (MAT-T271). Debug packages DebugGame, Release packages Shipping. A hook whose -Configuration ValidateSet has no
    DebugGame (SpaceGod.Unreal's tools\package.ps1 takes Development|Shipping today) packages Development for Debug,
    with a warning. A hook that takes -Out/-OutDir/-ArchiveDirectory writes straight into $Out; otherwise the hook
    archives into the repo (SpaceGod.Unreal: Builds\Cpp\Windows) and that folder is copied into $Out: -ArchiveDir
    names it, else it is the newest Builds\**\Windows folder holding an .exe written by this run. Running copies
    of the game from $Out are stopped first, and $Out is replaced, not merged. Throws on any failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Out,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Config,
        [string]$ArchiveDir,
        [int]$MaxParallelActions = 4
    )
    $hook = Get-UnrealPackageHook $Repo
    if (-not $hook) {
        throw "Publish-Unreal: $Repo has no package hook (tools\package.ps1, package.ps1 or run.ps1 taking -Configuration)."
    }
    $ueConfig = if ($Config -eq 'Debug') { 'DebugGame' } else { 'Shipping' }
    if ($hook.Configs -and $ueConfig -notin $hook.Configs) {
        if ($Config -eq 'Debug' -and 'Development' -in $hook.Configs) {
            Write-Warning "$(Split-Path -Leaf $hook.Path) takes no -Configuration DebugGame ($($hook.Configs -join '|')): packaging Development for Debug."
            $ueConfig = 'Development'
        } else {
            throw "Publish-Unreal: $($hook.Path) takes -Configuration $($hook.Configs -join '|'), not $ueConfig."
        }
    }

    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Out, 'OrdinalIgnoreCase') } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $splat = @{ Configuration = $ueConfig }
    if ('MaxParallelActions' -in $hook.Params) { $splat.MaxParallelActions = $MaxParallelActions }
    if ($hook.OutParam) {
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
        $splat[$hook.OutParam] = $Out
    }
    $started = Get-Date
    Write-Host "  Packaging $ueConfig ($(Split-Path -Leaf $hook.Path))..." -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    & $hook.Path @splat
    if ($LASTEXITCODE) { throw "$(Split-Path -Leaf $hook.Path) -Configuration $ueConfig failed ($LASTEXITCODE)" }

    if (-not $hook.OutParam) {
        if (-not $ArchiveDir) {
            $builds = Join-Path $Repo 'Builds'
            $ArchiveDir = Get-ChildItem -LiteralPath $builds -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in 'Windows', 'Win64', 'WindowsNoEditor' -and $_.LastWriteTime -ge $started.AddSeconds(-5) -and
                    (Get-ChildItem -LiteralPath $_.FullName -Filter *.exe -File -ErrorAction SilentlyContinue) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
            if (-not $ArchiveDir) { throw "Publish-Unreal: no package written under $builds by this run; pass -ArchiveDir." }
        }
        if (-not (Test-Path -LiteralPath $ArchiveDir)) { throw "Publish-Unreal: no package at $ArchiveDir." }
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
        New-Item -ItemType Directory -Force $Out | Out-Null
        Copy-Item -Path (Join-Path $ArchiveDir '*') -Destination $Out -Recurse -Force
    }
    if (-not (Get-ChildItem -LiteralPath $Out -Filter *.exe -File -ErrorAction SilentlyContinue)) {
        throw "Publish-Unreal: the package in $Out has no .exe."
    }
    Write-Host "  Published Unreal $ueConfig -> $Out" -ForegroundColor Green
}
