#Requires -Version 5.1
<#
.SYNOPSIS
    /publish for apps: builds a repo and deploys it to C:\Apps\MindAttic\<repo>\Release (release) or \Debug (dev).

.DESCRIPTION
    Release is the one definitive release candidate of each app (filmable on its own); Debug is the working copy.
      /publish, /publish dev       -> publish-app.ps1 -Mode dev       (this repo, Debug)
      /publish release             -> publish-app.ps1 -Mode release   (this repo, Release)
      /publish all dev|release     -> publish-app.ps1 -All -Mode ...  (every deployable repo in docs/workspace-repos.json)

    How a repo is built, first match wins:
      1. <repo>\.agent\publish.json  { "kind": "script", "command": "...{out}...{config}..." }  or
                                     { "kind": "dotnet", "projects": ["src/App/App.csproj"] }  or
                                     { "kind": "unity", "project": "subfolder" }  or  { "kind": "none" }
      2. Unity project (ProjectSettings\ProjectVersion.txt at the root or one level down): batch-builds an Android APK
         with an injected editor script (shared\unity\MindAtticPublish.cs, removed afterwards), then writes play.json,
         play.ps1 and play.bat next to it (Android.Emulator.Suite's device/action menu).
      3. .NET: every Exe/WinExe/Web project (not tests, benches or samples) is dotnet-published into the folder.
      4. run.ps1 / deploy.ps1 (root or tools\) that takes -Out: run with -Out <folder>.
    Mod repos (nexus.json / thunderstore.toml) are skipped here; bare /publish there is the mod release flow.

    The build goes to <folder>.staging first; processes running from the folder are stopped, then the folder is
    replaced. <folder>\.publish.json records the repo, mode, commit and time.

.EXAMPLE
    powershell -File publish-app.ps1 -Repo Android.Emulator.Suite -Mode release
    powershell -File publish-app.ps1 -All -Mode dev
#>
param(
    [string]$Repo,
    [ValidateSet('dev', 'release')][string]$Mode = 'dev',
    [switch]$All,
    [string]$Root = 'D:\Projects\MindAttic',
    [string]$AppsRoot = 'C:\Apps\MindAttic'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$config = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }

function Get-RepoRoot([string]$name) {
    if (-not $name) { $top = git rev-parse --show-toplevel 2>$null; if (-not $top) { throw 'Not in a git repo; pass -Repo.' }; return (Resolve-Path $top).Path }
    if (Test-Path $name) { return (Resolve-Path $name).Path }
    $p = Join-Path $Root $name
    if (Test-Path $p) { return $p }
    throw "No repo '$name' under $Root"
}

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

function Invoke-Unity([string]$repoName, [string]$project, [string]$stage) {
    $ver = (Select-String -Path (Join-Path $project 'ProjectSettings\ProjectVersion.txt') -Pattern 'm_EditorVersion: (.+)').Matches[0].Groups[1].Value.Trim()
    $unity = "C:\Program Files\Unity\Hub\Editor\$ver\Editor\Unity.exe"
    if (-not (Test-Path $unity)) { throw "Unity $ver isn't installed ($unity)." }
    $leaf = Split-Path -Leaf $project
    if (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$leaf*" }) {
        throw "$leaf is open in the Unity Editor. Close it (File > Quit) and publish again."
    }
    if (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { -not $_.MainWindowTitle }) {
        Write-Host "Another Unity batch process is running; one heavy build at a time, so waiting for it..." -ForegroundColor Yellow
        while (Get-Process -Name Unity -ErrorAction SilentlyContinue | Where-Object { -not $_.MainWindowTitle }) { Start-Sleep 15 }
    }

    $editorDir = Join-Path $project 'Assets\Editor\MindAtticPublish'
    $made = -not (Test-Path $editorDir)
    $parentMade = -not (Test-Path (Join-Path $project 'Assets\Editor'))
    New-Item -ItemType Directory -Force $editorDir | Out-Null
    Copy-Item (Join-Path $here 'unity\MindAtticPublish.cs') $editorDir -Force
    $apkName = ($repoName -replace '[^A-Za-z0-9]', '') + '.apk'
    $apk = Join-Path $stage $apkName
    $log = Join-Path $stage 'unity-build.log'
    New-Item -ItemType Directory -Force $stage | Out-Null
    try {
        $uargs = @('-batchmode', '-nographics', '-quit', '-projectPath', $project, '-buildTarget', 'Android',
            '-executeMethod', 'MindAtticPublish.BuildApk', '-mindatticOut', $apk, '-logFile', $log)
        if ($Mode -eq 'dev') { $uargs += '-mindatticDev' }
        Write-Host "Unity ${ver}: building $apkName ($config)... log: $log" -ForegroundColor Cyan
        & $unity @uargs | Out-Default
        $exit = $LASTEXITCODE
        if ($exit -ne 0 -or -not (Test-Path $apk)) {
            Get-Content $log -Tail 40 -ErrorAction SilentlyContinue | Write-Host
            throw "Unity build failed (exit $exit); full log: $log"
        }
    }
    finally {
        if ($made) { Remove-Item -Recurse -Force $editorDir, "$editorDir.meta" -ErrorAction SilentlyContinue }
        else { Remove-Item -Force (Join-Path $editorDir 'MindAtticPublish.cs'), (Join-Path $editorDir 'MindAtticPublish.cs.meta') -ErrorAction SilentlyContinue }
        if ($parentMade) { Remove-Item -Recurse -Force (Join-Path $project 'Assets\Editor'), (Join-Path $project 'Assets\Editor.meta') -ErrorAction SilentlyContinue }
    }

    $info = Get-Content "$apk.json" -Raw | ConvertFrom-Json
    Remove-Item "$apk.json"
    $id = ($repoName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') + "-$Mode"
    $play = [ordered]@{
        id = $id; name = "$($info.name) ($config)"; package = $info.package; apk = $apkName
        buildCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Repo $repoName -Mode $Mode"
        minSdk = $info.minSdk; orientation = $info.orientation; version = $info.version
    }
    $play | ConvertTo-Json | Set-Content (Join-Path $stage 'play.json') -Encoding UTF8
    $suitePlay = 'C:\Apps\Android.Emulator.Suite\play'
    if (-not (Test-Path (Join-Path $suitePlay 'play.ps1'))) { $suitePlay = Join-Path $Root 'Android.Emulator.Suite\tools' }
    if (-not (Test-Path (Join-Path $suitePlay 'play.ps1'))) { Write-Host "Android.Emulator.Suite's play.ps1 wasn't found; the APK is there without a launcher." -ForegroundColor Yellow }
    else { Copy-Item (Join-Path $suitePlay 'play.ps1'), (Join-Path $suitePlay 'play.bat') $stage -Force }
}

function Publish-Repo([string]$repo) {
    $name = Split-Path -Leaf $repo
    $plan = Get-Plan $repo
    if (-not $plan) { return [pscustomobject]@{ Repo = $name; Result = 'skipped'; Detail = 'nothing deployable (library, mod or docs repo)' } }
    $target = Join-Path (Join-Path $AppsRoot $name) $config
    $stage = "$target.staging"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Write-Host "== $name -> $target ($($plan.Kind))" -ForegroundColor Cyan
    try {
        switch ($plan.Kind) {
            'unity' { Invoke-Unity $name $plan.Project $stage }
            'dotnet' {
                foreach ($proj in $plan.Projects) {
                    dotnet publish $proj -c $config -o $stage -nologo -v q
                    if ($LASTEXITCODE -ne 0) { throw "dotnet publish $(Split-Path -Leaf $proj) failed ($LASTEXITCODE)" }
                }
            }
            'outscript' {
                $splat = @{ $plan.Param = $stage }
                & $plan.Script @splat
                if ($LASTEXITCODE) { throw "$(Split-Path -Leaf $plan.Script) failed ($LASTEXITCODE)" }
            }
            'script' {
                $cmd = $plan.Command.Replace('{out}', $stage).Replace('{config}', $config).Replace('{mode}', $Mode)
                Push-Location $repo
                try { cmd.exe /c $cmd; if ($LASTEXITCODE) { throw "publish command failed ($LASTEXITCODE): $cmd" } } finally { Pop-Location }
            }
        }
    }
    catch {
        Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Repo = $name; Result = 'FAILED'; Detail = $_.Exception.Message }
    }

    Get-Process | Where-Object { try { $_.Path -and $_.Path.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) } catch { $false } } | Stop-Process -Force
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $stage $target
    [ordered]@{ repo = $name; mode = $Mode; configuration = $config; kind = $plan.Kind
        commit = (git -C $repo rev-parse HEAD 2>$null); dirty = [bool](git -C $repo status --porcelain 2>$null)
        publishedAt = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $target '.publish.json') -Encoding UTF8
    return [pscustomobject]@{ Repo = $name; Result = 'published'; Detail = $target }
}

$results = @()
if ($All) {
    $list = (Get-Content (Join-Path $Root 'docs\workspace-repos.json') -Raw | ConvertFrom-Json).Repos | ForEach-Object { $_.Name }
    foreach ($n in $list) {
        $p = Join-Path $Root $n
        if (Test-Path (Join-Path $p '.git')) { $results += Publish-Repo $p }
    }
} else {
    $results += Publish-Repo (Get-RepoRoot $Repo)
}
$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
if ($results | Where-Object { $_.Result -eq 'FAILED' }) { exit 1 }
