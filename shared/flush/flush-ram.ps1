#Requires -Version 5.1
# /flush ram (MAT-T165): the quick sweep's measurements. Read-only; it changes nothing.
param([string]$OutDir = "$env:LOCALAPPDATA\MindAttic\Flush")
$ErrorActionPreference = 'SilentlyContinue'
$GB = 1GB
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$os = Get-CimInstance Win32_OperatingSystem
$installed = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum
$usable = $os.TotalVisibleMemorySize * 1KB
$free = $os.FreePhysicalMemory * 1KB
$commitLimit = $os.TotalVirtualMemorySize * 1KB
$commitUsed = $commitLimit - $os.FreeVirtualMemory * 1KB
$uptime = (Get-Date) - $os.LastBootUpTime
$m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory

"=== STEP 1: totals ==="
"Installed {0:N1} GB | usable {1:N1} GB | hw-reserved {2:N2} GB" -f ($installed/$GB), ($usable/$GB), (($installed-$usable)/$GB)
"In use {0:N1} GB | free {1:N1} GB ({2:N0}% used)" -f (($usable-$free)/$GB), ($free/$GB), (100*($usable-$free)/$usable)
"Commit {0:N1} / {1:N1} GB ({2:N0}%) | uptime {3:%d}d {3:hh}h {3:mm}m" -f ($commitUsed/$GB), ($commitLimit/$GB), (100*$commitUsed/$commitLimit), $uptime
"Paged pool {0:N2} GB | nonpaged {1:N2} GB | cache {2:N2} GB | modified {3:N2} GB" -f ($m.PoolPagedBytes/$GB), ($m.PoolNonpagedBytes/$GB), ($m.CacheBytes/$GB), ($m.ModifiedPageListBytes/$GB)
$standby = ($m.StandbyCacheCoreBytes + $m.StandbyCacheNormalPriorityBytes + $m.StandbyCacheReserveBytes)
"Standby {0:N2} GB (harmless, freed on demand)" -f ($standby/$GB)
$mc = Get-Process 'Memory Compression'
if ($mc) { "Memory Compression working set {0:N2} GB" -f ($mc.WorkingSet64/$GB) }

$procs = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, WorkingSetSize, PrivatePageCount, CreationDate
$byPid = @{}; foreach ($p in $procs) { $byPid[[int]$p.ProcessId] = $p }
$roots = 'claude.exe','MindAttic.Launcher.exe','MindAttic.Orchestrator.TermHost.exe','MindAttic.Orchestrator.Desktop.exe'
function Test-Protected([int]$id) {
    for ($i = 0; $i -lt 16 -and $byPid.ContainsKey($id); $i++) {
        $p = $byPid[$id]
        foreach ($r in $roots) { if ($p.Name -like "$r*") { return $true } }
        $parent = [int]$p.ParentProcessId
        if ($parent -eq 0 -or $parent -eq $id) { return $false }
        $id = $parent
    }
    return $false
}
$ours = @(); $theirs = @()
foreach ($p in $procs) { if (Test-Protected ([int]$p.ProcessId)) { $ours += $p } else { $theirs += $p } }

"`n=== STEP 0: MindAttic workload (whitelisted) ==="
"MindAttic workload: {0} processes, {1:N2} GB private, {2:N2} GB working set" -f $ours.Count, (($ours | Measure-Object PrivatePageCount -Sum).Sum/$GB), (($ours | Measure-Object WorkingSetSize -Sum).Sum/$GB)
$ours | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Count=$_.Count; PrivGB=[math]::Round(($_.Group | Measure-Object PrivatePageCount -Sum).Sum/$GB,2) } } |
    Sort-Object PrivGB -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String -Width 200

"=== Everything else, grouped by name (top 30 by private bytes) ==="
$groups = $theirs | Group-Object Name | ForEach-Object {
    [pscustomobject]@{
        Name   = $_.Name
        Count  = $_.Count
        PrivGB = [math]::Round(($_.Group | Measure-Object PrivatePageCount -Sum).Sum/$GB, 2)
        WsGB   = [math]::Round(($_.Group | Measure-Object WorkingSetSize -Sum).Sum/$GB, 2)
        Oldest = ($_.Group | Sort-Object CreationDate | Select-Object -First 1).CreationDate
    } } | Sort-Object PrivGB -Descending
$groups | Select-Object -First 30 | Format-Table -AutoSize | Out-String -Width 200

$windowed = @{}; Get-Process | Where-Object MainWindowHandle -ne 0 | ForEach-Object { $windowed[$_.ProcessName + '.exe'] = $true }
"=== Top 30 with a visible window? (no window = background/tray) ==="
$groups | Select-Object -First 30 | ForEach-Object { "{0,-45} {1}" -f $_.Name, ($(if ($windowed[$_.Name]) { 'window' } else { '-' })) }

$theirPriv = ($theirs | Measure-Object PrivatePageCount -Sum).Sum
$ourPriv = ($ours | Measure-Object PrivatePageCount -Sum).Sum
"`n=== Reconciliation ==="
"Commit {0:N1} GB = MindAttic {1:N1} + others {2:N1} + unexplained {3:N1} GB (pools/driver/file-backed/pagefile-backed sections)" -f ($commitUsed/$GB), ($ourPriv/$GB), ($theirPriv/$GB), (($commitUsed-$ourPriv-$theirPriv)/$GB)

New-Item -ItemType Directory -Force $OutDir | Out-Null
$last = Get-ChildItem -LiteralPath $OutDir -Filter 'ram-*.csv' | Sort-Object Name -Descending | Select-Object -First 1
if ($last) {
    $prev = @{}; Import-Csv $last.FullName | ForEach-Object { $prev[$_.Name] = [double]$_.PrivGB }
    "`n=== Since the last run ({0}): new or grown by 0.2 GB+ ===" -f $last.LastWriteTime
    $delta = $groups | ForEach-Object {
        $was = if ($prev.ContainsKey($_.Name)) { $prev[$_.Name] } else { $null }
        if ($null -eq $was -and $_.PrivGB -ge 0.2) { [pscustomobject]@{ Name = $_.Name; WasGB = 'new'; NowGB = $_.PrivGB } }
        elseif ($null -ne $was -and $_.PrivGB - $was -ge 0.2) { [pscustomobject]@{ Name = $_.Name; WasGB = $was; NowGB = $_.PrivGB } }
    }
    if ($delta) { $delta | Format-Table -AutoSize | Out-String -Width 200 } else { "nothing" }
}
$groups | Export-Csv "$OutDir\ram-$stamp.csv" -NoTypeInformation
"`nSaved $OutDir\groups-$stamp.csv"
