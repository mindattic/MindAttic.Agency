#Requires -Version 5.1
<#
.SYNOPSIS
    /flush drive|ssd|hdd|hd (MAT-T165): measures, then on -Apply empties, the disk cruft listed in cruft-sources.json, never
    touching what's connected to the MindAttic tree, and reports unlisted cruft that has started piling up.

.DESCRIPTION
    Every source is data in cruft-sources.json (temp folders, crash dumps, the Recycle Bin, Windows Update leftovers,
    logs, package and browser caches...); a new kind of cruft is a new entry there, not code here.
    Kept everywhere: Claude Code session folders (claude\, Orchestrator's SessionTempPruner owns them), MindAttic app
    extraction folders (.net\MindAttic.*), anything named MindAttic/Orchestrator/TermHost, and inside temp roots also
    ticket work folders (SG-T143...) and anything an environment variable points into (NUGET_PACKAGES...).
    Only files untouched for a source's minAgeHours (default 24) count, so work in progress anywhere keeps its files.
    Discovery (unless -NoDiscover) walks AppData and ProgramData for Cache/Logs/Dumps-style folders no source covers
    and lists the big ones, so the list can grow with whatever accumulates next.
    Without -Apply nothing is changed. -Groups picks what -Apply empties (default: the sources marked default).
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Groups,
    [switch]$NoDiscover,
    [int]$DiscoverMinMB = 250,
    [string]$SourcesFile = (Join-Path $PSScriptRoot 'cruft-sources.json'),
    [string]$OutDir = "$env:LOCALAPPDATA\MindAttic\Flush"
)

$ErrorActionPreference = 'SilentlyContinue'
$GB = 1GB
$now = Get-Date
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
$sources = (Get-Content -LiteralPath $SourcesFile -Raw | ConvertFrom-Json).sources
if (-not $Groups) { $Groups = $sources | Where-Object default | ForEach-Object group | Sort-Object -Unique }
$guard = '\\(claude|\.net\\MindAttic[^\\]*|[^\\]*(MindAttic|Orchestrator|TermHost)[^\\]*)(\\|$)'
$drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
$freeBefore = @{}; foreach ($d in $drives) { $freeBefore[$d.Name] = $d.AvailableFreeSpace }

$pinned = @{}
foreach ($scope in 'Process', 'User', 'Machine') {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
        if ($k -in 'TEMP', 'TMP') { continue }
        foreach ($v in "$($vars[$k])".Split(';')) {
            if ($v -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $v -PathType Container)) { $pinned[$v.TrimEnd('\')] = $k }
        }
    }
}

function Get-TempKeep([IO.FileSystemInfo]$item) {
    $n = $item.Name
    if ($n -eq 'claude' -or $n -match 'MindAttic|Orchestrator|TermHost') { return $true }
    if ($n -match '^[A-Z][A-Za-z0-9.]*-T\d+') { return $true }
    foreach ($p in $pinned.Keys) { if ($p.StartsWith($item.FullName + '\', 'OrdinalIgnoreCase') -or $p -ieq $item.FullName) { return $true } }
    return $false
}

function Get-Files([string]$path, [ref]$denied) {
    $errs = $null
    $item = Get-Item -LiteralPath $path -Force
    if (-not $item) { return @() }
    if (-not $item.PSIsContainer) { return @($item) }
    $files = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorVariable errs
    if ($errs) { $denied.Value += $errs.Count }
    $files
}

function Measure-Source($src) {
    $age = if ($src.minAgeHours) { [int]$src.minAgeHours } else { 24 }
    $cutoff = $now.AddHours(-$age)
    $r = [pscustomobject]@{ Src = $src; Old = [Collections.Generic.List[IO.FileInfo]]::new(); OldBytes = 0L; RecentBytes = 0L; KeptBytes = 0L; Denied = 0; Dirs = @() }
    $denied = 0
    $paths = @()
    if ($src.kind -eq 'temp') {
        $roots = @($env:TEMP, $env:TMP, (Join-Path $env:LOCALAPPDATA 'Temp'), (Join-Path $env:WINDIR 'Temp'))
        foreach ($d in $drives) { foreach ($n in 'Temp', 'Tmp') { $roots += Join-Path $d.RootDirectory.FullName $n } }
        foreach ($root in $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
                ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath.TrimEnd('\') } | Sort-Object -Unique) {
            $r.Dirs += $root
            foreach ($top in Get-ChildItem -LiteralPath $root -Force) {
                $files = Get-Files $top.FullName ([ref]$denied)
                if (Get-TempKeep $top) { $r.KeptBytes += ($files | Measure-Object Length -Sum).Sum; continue }
                $paths += , @($files)
            }
        }
    } elseif ($src.kind -eq 'recyclebin') {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($d in $drives) {
            $bin = Join-Path $d.RootDirectory.FullName "`$Recycle.Bin\$sid"
            if (Test-Path -LiteralPath $bin) { $r.OldBytes += (Get-Files $bin ([ref]$denied) | Measure-Object Length -Sum).Sum }
        }
        $r.Denied = $denied
        return $r
    } else {
        foreach ($p in $src.paths) {
            foreach ($hit in Resolve-Path -Path ([Environment]::ExpandEnvironmentVariables($p)) -ErrorAction SilentlyContinue) {
                $r.Dirs += $hit.ProviderPath
                $paths += , @(Get-Files $hit.ProviderPath ([ref]$denied))
            }
        }
    }
    foreach ($set in $paths) {
        foreach ($f in $set) {
            if ($f.FullName -match $guard) { $r.KeptBytes += $f.Length }
            elseif ($f.LastWriteTime -lt $cutoff -and $f.CreationTime -lt $cutoff) { $r.Old.Add($f); $r.OldBytes += $f.Length }
            else { $r.RecentBytes += $f.Length }
        }
    }
    $r.Denied = $denied
    $r
}

$results = foreach ($src in $sources) { Measure-Source $src }

"=== Disk cruft (only files past each source's age count; MindAttic-connected files kept) ==="
$results | ForEach-Object {
    [pscustomobject]@{
        Group = $_.Src.group; Source = $_.Src.name
        Default = $(if ($_.Src.default) { 'yes' } else { 'opt-in' }); Admin = $(if ($_.Src.admin) { 'yes' } else { '' })
        ReclaimGB = [math]::Round($_.OldBytes / $GB, 2); Files = $_.Old.Count
        RecentGB = [math]::Round($_.RecentBytes / $GB, 2); KeptGB = [math]::Round($_.KeptBytes / $GB, 2)
        Note = $(if ($_.Denied -gt 0 -and -not $isAdmin) { "$($_.Denied) unreadable: measure as admin" } elseif ($_.Denied) { "$($_.Denied) unreadable" } else { '' })
    } } | Format-Table -AutoSize | Out-String -Width 220
$byGroup = $results | Group-Object { $_.Src.group } | ForEach-Object { "{0} {1:N2} GB" -f $_.Name, (($_.Group | Measure-Object OldBytes -Sum).Sum / $GB) }
"By group: " + ($byGroup -join ' | ')
"Default groups: {0:N2} GB  |  everything: {1:N2} GB" -f (($results | Where-Object { $_.Src.default } | Measure-Object OldBytes -Sum).Sum / $GB), (($results | Measure-Object OldBytes -Sum).Sum / $GB)

if ($Apply) {
    "`n=== Applying groups: $($Groups -join ', ') ==="
    $freed = 0L; $deleted = 0; $skipped = 0
    foreach ($r in $results | Where-Object { $_.Src.group -in $Groups }) {
        if ($r.Src.admin -and -not $isAdmin) { "skip {0}: needs an Administrator window" -f $r.Src.name; continue }
        if ($r.Src.kind -eq 'recyclebin') {
            foreach ($d in $drives) { Clear-RecycleBin -DriveLetter $d.Name.Substring(0, 1) -Force -ErrorAction SilentlyContinue }
            $freed += $r.OldBytes; continue
        }
        foreach ($f in $r.Old) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $f.Length; $deleted++ } catch { $skipped++ }
        }
        foreach ($dir in $r.Dirs) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            Get-ChildItem -LiteralPath $dir -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending |
                Where-Object { $_.FullName -notmatch $guard -and -not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1) -and
                    ($r.Src.kind -ne 'temp' -or -not (Get-TempKeep (Get-Item -LiteralPath (Join-Path $dir ($_.FullName.Substring($dir.Length + 1).Split('\')[0])) -Force))) } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }
    "Deleted {0:N0} files (plus the Recycle Bin if chosen), {1:N2} GB freed; {2:N0} locked/denied files skipped" -f $deleted, ($freed / $GB), $skipped
}

if (-not $NoDiscover) {
    "`n=== Unlisted cruft (Cache/Logs/Dumps-style folders over $DiscoverMinMB MB that no source covers) ==="
    $covered = @($results | ForEach-Object Dirs) | Where-Object { $_ }
    $namePattern = '^(cache|caches|code cache|gpucache|cacheddata|shadercache|dxcache|glcache|logs?|crashdumps|crashpad|crashes|dumps?|reports|temp|tmp|blob_storage|service worker|webcache)$'
    $found = @()
    foreach ($base in $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData) {
        foreach ($dir in Get-ChildItem -LiteralPath $base -Directory -Recurse -Depth 5 -Force) {
            if ($dir.Name -notmatch $namePattern -or $dir.FullName -match $guard) { continue }
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $full = $dir.FullName
            if ($covered | Where-Object { $full.StartsWith($_, 'OrdinalIgnoreCase') -or $_.StartsWith($full + '\', 'OrdinalIgnoreCase') }) { continue }
            if ($pinned.Keys | Where-Object { $_.StartsWith($full, 'OrdinalIgnoreCase') }) { continue }
            if ($found | Where-Object { $full.StartsWith($_.Path + '\', 'OrdinalIgnoreCase') }) { continue }
            $bytes = (Get-ChildItem -LiteralPath $full -Recurse -Force -File | Measure-Object Length -Sum).Sum
            if ($bytes -ge $DiscoverMinMB * 1MB) {
                $newest = Get-ChildItem -LiteralPath $full -Recurse -Force -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $found += [pscustomobject]@{ GB = [math]::Round($bytes / $GB, 2); Newest = $newest.LastWriteTime; Path = $full }
            }
        }
    }
    if ($found) { $found | Sort-Object GB -Descending | Select-Object -First 25 | Format-Table -AutoSize | Out-String -Width 220 }
    else { "none" }
    "To make one a regular source, add it to $SourcesFile."
}

"`n=== Free space ==="
foreach ($d in $drives) {
    $d.Refresh()
    "{0} {1:N1} GB free of {2:N1} GB{3}" -f $d.Name, ($d.AvailableFreeSpace / $GB), ($d.TotalSize / $GB), $(if ($Apply) { " (+{0:N2} GB)" -f (($d.AvailableFreeSpace - $freeBefore[$d.Name]) / $GB) } else { '' })
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$results | ForEach-Object { [pscustomobject]@{ Group = $_.Src.group; Source = $_.Src.name; ReclaimGB = [math]::Round($_.OldBytes / $GB, 3); Files = $_.Old.Count; KeptGB = [math]::Round($_.KeptBytes / $GB, 3) } } |
    Export-Csv (Join-Path $OutDir ("disk-{0}{1}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $(if ($Apply) { '-applied' } else { '' }))) -NoTypeInformation
