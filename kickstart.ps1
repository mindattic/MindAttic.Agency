#Requires -Version 5.1
<#
.SYNOPSIS
    Wakes a sleeping Azure web app and its serverless SQL database (MAT-T166, /kickstart).

.DESCRIPTION
    MindAttic's Azure apps run with Always On off: an app unloads after ~20 idle minutes and a serverless
    database pauses after its auto-pause delay. Visiting the site wakes both eventually; this does it up front
    and waits until both answer, so the first real visit is fast.

      kickstart.ps1                 list every web app with its state and its database's status
      kickstart.ps1 <name>          wake one app (exact name, or a unique partial match: gadfly -> mindattic-gadfly)
      kickstart.ps1 all             wake every app
      kickstart.ps1 -Database a,b   wake only these Azure SQL databases (by name, on any server az can see);
                                    no web app is looked at. Used by MindAttic.Launcher's backup (M.LNCH-T137).
      kickstart.ps1 -ListDatabases  list every Azure SQL database with its server and status; wakes nothing.
      add -Json                     to any of the above for one JSON document on stdout instead of text
                                    (MindAttic.Launcher's Azure menu reads it, M.LNCH-T136):
                                      list:      [{ name, state, rg, url, database: { server, fqdn, name, status, sku } | null }]
                                      wake:      { apps: [{ name, state, url, app, db, database }], urls: [...] }
                                      -Database: [{ server, fqdn, name, status, sku, result, online }]
                                      -ListDatabases: [{ server, fqdn, name, status, sku }]

    The app is woken by GETs to its site (/healthz if it answers, else /). The database is found from the
    app's connection strings (Server=...;Database=...), else by a database whose name matches the app's
    name, and is woken by opening one Entra-authenticated connection (SELECT 1) with the signed-in az
    account's token. Read-only: it changes no setting, secret or resource. Nothing is printed from any
    connection string but the server and database names.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name = '',
    [int]$TimeoutSeconds = 180,
    [string[]]$Database,
    [switch]$ListDatabases,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-Json([string[]]$AzArgs) {
    $out = & az @AzArgs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return ($out | Out-String | ConvertFrom-Json)
}

function Out-Json($value) { ConvertTo-Json -InputObject $value -Depth 6 -Compress }

$dbs = @()
foreach ($srv in @(Get-Json @('sql', 'server', 'list', '--query', '[].{name:name, rg:resourceGroup, fqdn:fullyQualifiedDomainName}'))) {
    if (-not $srv) { continue }
    foreach ($d in @(Get-Json @('sql', 'db', 'list', '-g', $srv.rg, '-s', $srv.name, '--query', "[?name!='master'].{name:name, status:status, sku:currentSku.name}"))) {
        if ($d) { $dbs += [pscustomobject]@{ Server = $srv.name; Rg = $srv.rg; Fqdn = $srv.fqdn; Name = $d.name; Status = $d.status; Sku = $d.sku } }
    }
}

function Find-Database($app) {
    # 1. The app's own connection strings / settings, when they hold plain Server=...;Database=... values.
    $values = @()
    $cs = Get-Json @('webapp', 'config', 'connection-string', 'list', '-g', $app.rg, '-n', $app.name)
    if ($cs) { $values += @($cs | ForEach-Object { $_.value.value }) }
    $st = Get-Json @('webapp', 'config', 'appsettings', 'list', '-g', $app.rg, '-n', $app.name)
    if ($st) { $values += @($st | ForEach-Object { $_.value }) }
    foreach ($v in $values) {
        if (-not $v -or $v -notmatch '(?i)(Database|Initial Catalog)\s*=\s*([^;]+)') { continue }
        $dbName = $Matches[2].Trim()
        $server = if ($v -match '(?i)(Server|Data Source)\s*=\s*(tcp:)?([^;,]+)') { $Matches[3].Trim() } else { '' }
        $hit = $dbs | Where-Object { $_.Name -eq $dbName -and ($server -eq '' -or $server -like "$($_.Server)*") } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    # 2. A database named like the app (mindattic-gadfly -> Gadfly).
    $short = ($app.name -replace '^mindattic-', '')
    return $dbs | Where-Object { $_.Name -ieq $app.name -or $_.Name -ieq $short } | Select-Object -First 1
}

function Wake-Database($db) {
    $token = (& az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv 2>$null)
    if (-not $token) { return 'no token (az login?)' }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $started = Get-Date
    while ($true) {
        $c = New-Object System.Data.SqlClient.SqlConnection ("Server=tcp:$($db.Fqdn),1433;Database=$($db.Name);Encrypt=True;Connect Timeout=60")
        $c.AccessToken = $token
        try {
            $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = 'SELECT 1'; [void]$cmd.ExecuteScalar()
            return ('online ({0:0}s)' -f ((Get-Date) - $started).TotalSeconds)
        } catch {
            # A paused serverless database refuses the first connections while it resumes (error 40613).
            if ((Get-Date) -gt $deadline) { return "not reachable after $TimeoutSeconds s: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
            Start-Sleep -Seconds 5
        } finally { $c.Dispose() }
    }
}

function Wake-App($app) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $started = Get-Date
    while ($true) {
        foreach ($path in '/healthz', '/') {
            try {
                $r = Invoke-WebRequest -Uri "https://$($app.host)$path" -UseBasicParsing -TimeoutSec 120 -MaximumRedirection 5
                if ($r.StatusCode -lt 500) { return ('up, {0} -> {1} ({2:0}s)' -f $path, $r.StatusCode, ((Get-Date) - $started).TotalSeconds) }
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($code -and $code -lt 500 -and $code -ne 404) { return ('up, {0} -> {1} ({2:0}s)' -f $path, $code, ((Get-Date) - $started).TotalSeconds) }
            }
        }
        if ((Get-Date) -gt $deadline) { return "no answer after $TimeoutSeconds s" }
        Start-Sleep -Seconds 5
    }
}

function DbInfo($db) {
    if (-not $db) { return $null }
    [ordered]@{ server = $db.Server; fqdn = $db.Fqdn; name = $db.Name; status = $db.Status; sku = $db.Sku }
}

if ($ListDatabases) {
    if ($Json) { Out-Json @($dbs | Sort-Object Server, Name | ForEach-Object { DbInfo $_ }); return }
    foreach ($db in $dbs | Sort-Object Server, Name) { '{0,-28} {1,-32} {2,-10} {3}' -f $db.Server, $db.Name, $db.Status, $db.Sku }
    return
}

# -Database: wake databases only (M.LNCH-T137). No web app list is needed, so none is read.
if ($Database) {
    $wanted = @($Database | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $dbs.Count) { throw "kickstart: 'az sql server list' found no databases; is az signed in (az login)?" }
    $rows = @()
    foreach ($w in $wanted) {
        $hits = @($dbs | Where-Object { $_.Name -ieq $w })
        if (-not $hits.Count) {
            if ($Json) { $rows += [ordered]@{ server = $null; fqdn = $null; name = $w; status = 'missing'; sku = $null; result = 'no Azure SQL database by that name'; online = $false } }
            else { "${w}: no Azure SQL database by that name" }
            continue
        }
        foreach ($db in $hits) {
            if (-not $Json) { "$($db.Server)/$($db.Name): waking (was $($db.Status))" }
            $result = Wake-Database $db
            if ($Json) { $info = DbInfo $db; $info.result = $result; $info.online = ($result -like 'online*'); $rows += $info }
            else { "  db:  $result" }
        }
    }
    if ($Json) { Out-Json @($rows) }
    return
}

$apps = Get-Json @('webapp', 'list', '--query', '[].{name:name, rg:resourceGroup, host:defaultHostName, state:state}')
if (-not $apps) { throw "kickstart: 'az webapp list' returned nothing; is az signed in (az login)?" }

if (-not $Name) {
    $list = @()
    foreach ($a in $apps | Sort-Object name) {
        $db = Find-Database $a
        if ($Json) { $list += [ordered]@{ name = $a.name; state = $a.state; rg = $a.rg; url = "https://$($a.host)"; database = (DbInfo $db) }; continue }
        $dbText = if ($db) { "$($db.Server)/$($db.Name): $($db.Status)" } else { '(no database found)' }
        '{0,-24} {1,-8} https://{2}   db {3}' -f $a.name, $a.state, $a.host, $dbText
    }
    if ($Json) { Out-Json @($list) }
    return
}

$targets = if ($Name -ieq 'all') { $apps } else {
    $exact = @($apps | Where-Object { $_.name -ieq $Name })
    if ($exact.Count) { $exact } else { @($apps | Where-Object { $_.name -like "*$Name*" }) }
}
if (-not $targets -or @($targets).Count -eq 0) { throw "kickstart: no web app matches '$Name'. Apps: $(($apps.name | Sort-Object) -join ', ')" }
if ($Name -ine 'all' -and @($targets).Count -gt 1) { throw "kickstart: '$Name' matches several apps: $((@($targets).name) -join ', '). Use the full name." }

$ready = @()
$woken = @()
foreach ($a in @($targets)) {
    if ($a.state -ne 'Running') {
        $msg = "the app is $($a.state) (stopped in Azure, not just asleep); start it with: az webapp start -g $($a.rg) -n $($a.name)"
        if ($Json) { $woken += [ordered]@{ name = $a.name; state = $a.state; url = "https://$($a.host)"; app = $msg; db = $null; database = $null } }
        else { "$($a.name): $msg" }
        continue
    }
    $db = Find-Database $a
    if (-not $Json) { "$($a.name): waking https://$($a.host)" + $(if ($db) { " and database $($db.Server)/$($db.Name) (was $($db.Status))" } else { ' (no database found)' }) }
    $appResult = Wake-App $a
    $dbResult = if ($db) { Wake-Database $db } else { '-' }
    if ($Json) { $woken += [ordered]@{ name = $a.name; state = $a.state; url = "https://$($a.host)"; app = $appResult; db = $(if ($db) { $dbResult } else { $null }); database = (DbInfo $db) } }
    else {
        "  app: $appResult"
        if ($db) { "  db:  $dbResult" }
    }
    $ready += "https://$($a.host)"
}
if ($Json) { Out-Json ([ordered]@{ apps = @($woken); urls = @($ready) }); return }
if ($ready.Count) {
    ''
    'Open:'
    $ready
}
