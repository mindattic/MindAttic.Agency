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

      Publish-DotNet             Config-aware dotnet publish of a 'dotnet' plan's projects into one folder (MAT-T276):
                                   Debug   -> dotnet publish -c Debug --self-contained false (framework-dependent, fast)
                                   Release -> dotnet publish -c Release --self-contained true -r win-x64
                                              -p:PublishSingleFile=true (standalone; no .NET runtime needed)
                                 Release also bundles native libraries into the exe (IncludeNativeLibrariesForSelfExtract,
                                 so WPF/WinForms/WebView2 natives don't sit beside it) and embeds the PDB, so a plain
                                 Exe/WinExe lands as one standalone .exe. Shapes that can't take that get the nearest fit
                                 (Get-DotnetPublishShape decides, Publish-DotNet says which on the console):
                                   web        Microsoft.NET.Sdk.Web/Razor app: self-contained, NOT single-file
                                              (wwwroot, appsettings and the like must sit beside it anyway).
                                   blazorwasm Blazor WebAssembly: a static site; plain publish in both configs, no RID.
                                   library    no Exe/WinExe OutputType: plain framework-dependent publish in both configs.
                                   netfx      .NET Framework (net4x / old-style csproj): plain publish, no RID.
                                 A csproj that says <PublishSingleFile>false</PublishSingleFile> or
                                 <SelfContained>false</SelfContained> keeps that opt-out in Release. Several projects
                                 (a multi-exe repo) publish into the same folder, each its own single-file exe.
      Get-DotnetPublishShape     Reads a csproj and returns its shape (app/web/blazorwasm/library/netfx) and opt-outs.

    Publish-Unity / Publish-Unreal land here in their own tickets (MAT-T270, MAT-T271).
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

function Get-DotnetPublishShape([string]$Project) {
    <# What kind of .NET project this is, for Publish-DotNet: Shape (app|web|blazorwasm|library|netfx) plus any opt-outs. #>
    $x = Get-Content $Project -Raw
    $shape = 'library'
    if ($x -notmatch '<Project\s[^>]*Sdk=' -or $x -match '<TargetFrameworks?>\s*(net[2-4]\d{1,2}(?![\d.])|v\d)') { $shape = 'netfx' }
    elseif ($x -match 'Sdk="Microsoft\.NET\.Sdk\.BlazorWebAssembly"') { $shape = 'blazorwasm' }
    elseif ($x -match 'Sdk="Microsoft\.NET\.Sdk\.(Web|Razor)"' -and $x -notmatch '<OutputType>\s*Library\s*</OutputType>') { $shape = 'web' }
    elseif ($x -match '<OutputType>\s*(WinExe|Exe)\s*</OutputType>') { $shape = 'app' }
    return @{
        Shape        = $shape
        NoSingleFile = [bool]($x -match '<PublishSingleFile>\s*false\s*</PublishSingleFile>')
        NoSelfContained = [bool]($x -match '<SelfContained>\s*false\s*</SelfContained>')
    }
}

function Publish-DotNet {
    <# dotnet-publishes each project into $Out: Debug framework-dependent, Release self-contained single-file (see the header). Throws on failure. #>
    param(
        [Parameter(Mandatory)][string[]]$Projects,
        [Parameter(Mandatory)][string]$Out,
        [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Config,
        [string]$Runtime = 'win-x64'
    )
    foreach ($proj in $Projects) {
        $leaf = Split-Path -Leaf $proj
        $s = Get-DotnetPublishShape $proj
        $a = @('publish', $proj, '-c', $Config, '-o', $Out, '-nologo', '-v', 'q')
        $how = 'framework-dependent'
        if ($s.Shape -in 'app', 'web') {
            if ($Config -eq 'Debug' -or $s.NoSelfContained) {
                $a += @('--self-contained', 'false', '-p:PublishSingleFile=false')
            } else {
                $a += @('--self-contained', 'true', '-r', $Runtime)
                $how = "self-contained $Runtime"
                if ($s.Shape -eq 'app' -and -not $s.NoSingleFile) {
                    $a += @('-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=embedded')
                    $how += ', single-file'
                } else {
                    $a += '-p:PublishSingleFile=false'
                    $how += $(if ($s.Shape -eq 'web') { ', not single-file (web app)' } else { ', not single-file (csproj opts out)' })
                }
            }
        } else {
            $how = "plain publish ($($s.Shape))"
        }
        Write-Host "  dotnet publish $leaf -c $Config : $how" -ForegroundColor DarkGray
        & dotnet @a
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish $leaf ($Config) failed ($LASTEXITCODE)" }
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
