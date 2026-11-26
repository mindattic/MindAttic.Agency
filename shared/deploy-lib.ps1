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

function Publish-Unity {
    <#
    Batch-builds a Unity project (MAT-T270). -Target Windows (default) makes a 64-bit Windows player:
        Debug   -> Development build (BuildOptions.Development: profiler, debug console, script debugging)
        Release -> Release build (BuildOptions.None)
    into $Out\<RepoName>.exe. -Target Android runs the existing MindAtticPublish.BuildApk instead ($Out\<RepoName>.apk
    plus <apk>.json with the app's identity; publish-app.ps1 turns that into play.json).
    -Config takes Debug, Release or both (the default); with both, or with no -Out, each config lands in its own
    Get-DeployTarget folder (<AppsRoot>\<RepoName>\<Config>). The caller owns staging/replacement of that folder.
    Same machinery as publish-app.ps1's Invoke-Unity: refuses while the project is open in the editor, waits for another
    batch Unity, copies shared\unity\MindAtticPublish.cs into Assets\Editor for the build only, and puts every byte of
    ProjectSettings\ and Packages\ back afterwards (switching build target rewrites them). Returns one object per
    config (Config, Out, Path, Log). Throws on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$RepoName,
        [ValidateSet('Debug', 'Release')][string[]]$Config = @('Debug', 'Release'),
        [string]$Out,
        [ValidateSet('Windows', 'Android')][string]$Target = 'Windows',
        [string]$AppsRoot = $DeployLibAppsRoot,
        [string]$EditorScript
    )
    $Project = (Resolve-Path $Project).Path
    if (-not $RepoName) {
        $top = git -C $Project rev-parse --show-toplevel 2>$null
        $RepoName = if ($top) { Split-Path -Leaf $top } else { Split-Path -Leaf $Project }
    }
    if ($Out -and @($Config).Count -gt 1) { throw 'Publish-Unity: -Out takes one -Config; leave -Out off to build both into their deploy targets.' }
    if (-not $EditorScript) { $EditorScript = Join-Path $PSScriptRoot 'unity\MindAtticPublish.cs' }
    if (-not (Test-Path $EditorScript)) { throw "Publish-Unity: editor script not found ($EditorScript)." }

    $ver = (Select-String -Path (Join-Path $Project 'ProjectSettings\ProjectVersion.txt') -Pattern 'm_EditorVersion: (.+)').Matches[0].Groups[1].Value.Trim()
    $unity = "C:\Program Files\Unity\Hub\Editor\$ver\Editor\Unity.exe"
    if (-not (Test-Path $unity)) { throw "Unity $ver isn't installed ($unity)." }
    $leaf = Split-Path -Leaf $Project
    if (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$leaf*" }) {
        throw "$leaf is open in the Unity Editor. Close it (File > Quit) and publish again."
    }

    $exeBase = ($RepoName -replace '[^A-Za-z0-9._-]', '')
    $method = if ($Target -eq 'Android') { 'MindAtticPublish.BuildApk' } else { 'MindAtticPublish.BuildWindows' }
    $buildTarget = if ($Target -eq 'Android') { 'Android' } else { 'Win64' }
    $results = @()
    foreach ($cfg in @($Config)) {
        $dest = if ($Out) { $Out } else { Get-DeployTarget -RepoName $RepoName -Config $cfg -AppsRoot $AppsRoot }
        New-Item -ItemType Directory -Force $dest | Out-Null
        $file = Join-Path $dest ($exeBase + $(if ($Target -eq 'Android') { '.apk' } else { '.exe' }))
        $log = Join-Path $dest 'unity-build.log'

        if (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { -not $_.MainWindowTitle }) {
            Write-Host "Another Unity batch process is running; one heavy build at a time, so waiting for it..." -ForegroundColor Yellow
            while (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { -not $_.MainWindowTitle }) { Start-Sleep 15 }
        }
        $editorDir = Join-Path $Project 'Assets\Editor\MindAtticPublish'
        $made = -not (Test-Path $editorDir)
        $parentMade = -not (Test-Path (Join-Path $Project 'Assets\Editor'))
        New-Item -ItemType Directory -Force $editorDir | Out-Null
        Copy-Item $EditorScript $editorDir -Force
        $snap = @{}
        foreach ($f in @(Get-ChildItem (Join-Path $Project 'ProjectSettings'), (Join-Path $Project 'Packages') -File -ErrorAction SilentlyContinue)) {
            $snap[$f.FullName] = [IO.File]::ReadAllBytes($f.FullName)
        }
        $utmpMade = -not (Test-Path (Join-Path $Project '.utmp'))
        try {
            $uargs = @('-batchmode', '-nographics', '-quit', '-projectPath', $Project, '-buildTarget', $buildTarget,
                '-executeMethod', $method, '-mindatticOut', $file, '-logFile', $log)
            if ($cfg -eq 'Debug') { $uargs += '-mindatticDev' }
            $kind = if ($cfg -eq 'Debug') { 'Development' } else { 'Release' }
            Write-Host "Unity ${ver}: building $(Split-Path -Leaf $file) ($Target, $kind) -> $dest ... log: $log" -ForegroundColor Cyan
            & $unity @uargs | Out-Default
            $exit = $LASTEXITCODE
            if ($exit -ne 0 -or -not (Test-Path $file)) {
                Get-Content $log -Tail 40 -ErrorAction SilentlyContinue | Write-Host
                throw "Unity $Target $cfg build failed (exit $exit); full log: $log"
            }
        }
        finally {
            if ($made) { Remove-Item -Recurse -Force $editorDir, "$editorDir.meta" -ErrorAction SilentlyContinue }
            else { Remove-Item -Force (Join-Path $editorDir 'MindAtticPublish.cs'), (Join-Path $editorDir 'MindAtticPublish.cs.meta') -ErrorAction SilentlyContinue }
            if ($parentMade) { Remove-Item -Recurse -Force (Join-Path $Project 'Assets\Editor'), (Join-Path $Project 'Assets\Editor.meta') -ErrorAction SilentlyContinue }
            foreach ($f in @(Get-ChildItem (Join-Path $Project 'ProjectSettings'), (Join-Path $Project 'Packages') -File -ErrorAction SilentlyContinue)) {
                if (-not $snap.ContainsKey($f.FullName)) { Remove-Item -Force $f.FullName }
            }
            foreach ($k in $snap.Keys) { [IO.File]::WriteAllBytes($k, $snap[$k]) }
            if ($utmpMade) { Remove-Item -Recurse -Force (Join-Path $Project '.utmp') -ErrorAction SilentlyContinue }
        }
        Get-ChildItem $dest -Directory -Filter '*_DoNotShip' | Remove-Item -Recurse -Force
        $results += [pscustomobject]@{ Config = $cfg; Out = $dest; Path = $file; Log = $log }
    }
    return $results
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
