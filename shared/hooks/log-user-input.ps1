
# Logs every user prompt, across every project, to a shared cross-project DB
# (ClaudeActivity.UserInputLog) with a Project column derived from cwd. Never blocks or fails the
# actual prompt submission: every path ends in exit 0, and the database work has a hard time limit.
#
# WHERE IT WRITES (MAT-T148) is a setting, %APPDATA%\MindAttic\ClaudeActivity\prompt-log.json:
#     { "Target": "Local" | "Spool" | "Azure", "TimeoutSeconds": 3, "TokenRefreshMinutes": 5,
#       "AzureServer": "...database.windows.net", "Database": "ClaudeActivity", "DrainMax": 200 }
# No file, or no Target, means "Local": (localdb)\MSSQLLocalDB, as before.
#   Azure  the Azure SQL copy, with a service-principal token on SqlConnection.AccessToken. The token
#          (principal from %APPDATA%\MindAttic\Database\providers.json) is cached, DPAPI-encrypted for
#          this Windows user, in %LOCALAPPDATA%\MindAttic\ClaudeActivity\sql-token.bin and fetched again
#          only within TokenRefreshMinutes of its expiry. It is never written anywhere else.
#   Spool  no database at all: the row is only queued. docs/ops/azure-migration/Switch-PromptLog.ps1
#          uses it while the last local rows are pushed to Azure, so identity values cannot collide.
# TIME LIMIT: token + connect + insert (+ draining) share TimeoutSeconds. Whatever cannot be written in
# time, or fails for any reason, is appended to %LOCALAPPDATA%\MindAttic\ClaudeActivity\spool.jsonl with
# its own timestamp, and the next run that reaches the database inserts it (at least once: a run killed
# while draining can insert a queued row twice). So nothing is lost and nothing needs a local SQL Server.
# Do not flip Target by hand before the last local-to-Azure sync: use Switch-PromptLog.ps1.
param([string]$SettingsPath, [string]$StateDir)
try {
    # The hook JSON is UTF-8; [Console]::In would decode it with the OEM codepage on PowerShell 5.1.
    $raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding $false))).ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $prompt = $payload.prompt
    $sessionId = $payload.session_id
    $cwd = $payload.cwd
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

    $project = ""
    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        $project = Split-Path -Path $cwd -Leaf
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $row = @{ at = [datetime]::UtcNow.ToString('o'); proj = [string]$project; cwd = [string]$cwd; sid = [string]$sessionId; content = [string]$prompt }

    # ---- settings (defaults = the behaviour before MAT-T148) ----
    $cfg = @{ Target = 'Local'; TimeoutSeconds = 3; TokenRefreshMinutes = 5; DrainMax = 200
        AzureServer = 'sql-mindattic-f65744.database.windows.net'; Database = 'ClaudeActivity'; LocalServer = '(localdb)\MSSQLLocalDB' }
    if (-not $SettingsPath) { $SettingsPath = Join-Path $env:APPDATA 'MindAttic\ClaudeActivity\prompt-log.json' }
    if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'MindAttic\ClaudeActivity' }
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $file = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { $p = $file.PSObject.Properties[$k]; if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { $cfg[$k] = $p.Value } }
        }
    }
    catch { }
    $limit = [double]$cfg.TimeoutSeconds; if ($limit -le 0) { $limit = 3 }
    function Remaining { [int][Math]::Max(1, [Math]::Ceiling($limit - $clock.Elapsed.TotalSeconds)) }
    function Expired { $clock.Elapsed.TotalSeconds -ge $limit }
    $spool = Join-Path $StateDir 'spool.jsonl'

    # The state folder holds prompts (the queue) and the cached token: this user only.
    function Initialize-StateDir {
        if (Test-Path -LiteralPath $StateDir) { return }
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        try {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            [IO.Directory]::SetAccessControl($StateDir, $acl)
        }
        catch { }
    }
    function Add-Spool([string[]]$lines) {
        if (-not $lines -or $lines.Count -eq 0) { return }
        Initialize-StateDir
        $text = ($lines -join "`n") + "`n"
        for ($i = 0; $i -lt 20; $i++) {          # another CLI's hook may hold the file for a moment
            try { [IO.File]::AppendAllText($spool, $text, (New-Object Text.UTF8Encoding $false)); return } catch { Start-Sleep -Milliseconds 25 }
        }
    }
    function Write-LastError([string]$message) {
        try { Initialize-StateDir; [IO.File]::WriteAllText((Join-Path $StateDir 'last-error.txt'), ("{0} {1}`r`n" -f [datetime]::UtcNow.ToString('s'), $message)) } catch { }
    }
    $line = $row | ConvertTo-Json -Compress

    if ($cfg.Target -eq 'Spool') { Add-Spool @($line); exit 0 }

    try {
        Add-Type -AssemblyName System.Data
        $conn = $null
        if ($cfg.Target -eq 'Azure') {
            # ---- cached service-principal token ----
            Add-Type -AssemblyName System.Security
            Initialize-StateDir
            $tokenFile = Join-Path $StateDir 'sql-token.bin'
            $token = $null
            try {
                if (Test-Path -LiteralPath $tokenFile) {
                    $plain = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($tokenFile), $null, 'CurrentUser'))
                    $cut = $plain.IndexOf('|')
                    $expires = [datetime]::Parse($plain.Substring(0, $cut), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    if ($expires -gt [datetime]::UtcNow.AddMinutes([double]$cfg.TokenRefreshMinutes)) { $token = $plain.Substring($cut + 1) }
                }
            }
            catch { $token = $null }
            if (-not $token) {
                $sp = (Get-Content -LiteralPath (Join-Path $env:APPDATA 'MindAttic\Database\providers.json') -Raw | ConvertFrom-Json).AzureSql
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $req = [Net.HttpWebRequest]::Create("https://login.microsoftonline.com/$($sp.TenantId)/oauth2/v2.0/token")
                $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'; $req.Proxy = $null
                $req.Timeout = (Remaining) * 1000; $req.ReadWriteTimeout = $req.Timeout
                $body = [Text.Encoding]::UTF8.GetBytes(('grant_type=client_credentials&client_id={0}&client_secret={1}&scope={2}' -f [Uri]::EscapeDataString($sp.ClientId), [Uri]::EscapeDataString($sp.ClientSecret), [Uri]::EscapeDataString('https://database.windows.net/.default')))
                $rs = $req.GetRequestStream(); $rs.Write($body, 0, $body.Length); $rs.Close()
                $resp = $req.GetResponse()
                try { $reader = New-Object IO.StreamReader($resp.GetResponseStream()); $answer = $reader.ReadToEnd() | ConvertFrom-Json } finally { $resp.Close() }
                $token = [string]$answer.access_token
                if (-not $token) { throw 'the token endpoint returned no access_token' }
                try {
                    $plain = [datetime]::UtcNow.AddSeconds([double]$answer.expires_in).ToString('o') + '|' + $token
                    $tmp = "$tokenFile.$PID.tmp"
                    [IO.File]::WriteAllBytes($tmp, [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'CurrentUser'))
                    Move-Item -LiteralPath $tmp -Destination $tokenFile -Force
                }
                catch { }
            }
            if (Expired) { throw 'out of time after fetching the token' }
            $conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$($cfg.AzureServer),1433;Database=$($cfg.Database);Encrypt=True;Connect Timeout=$(Remaining);ConnectRetryCount=0;Pooling=False;Application Name=log-user-input")
            $conn.AccessToken = $token
        }
        else {
            $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$($cfg.LocalServer);Database=$($cfg.Database);Integrated Security=True;Connect Timeout=$(Remaining);Pooling=False;")
        }
        $conn.Open()
        try {
            $insert = {
                param($r)
                $cmd = $conn.CreateCommand()
                $cmd.CommandTimeout = Remaining
                $cmd.CommandText = "INSERT INTO UserInputLog (ReceivedAtUtc, Project, Cwd, SessionId, Content) VALUES (@at, @proj, @cwd, @sid, @content)"
                $at = $cmd.Parameters.Add('@at', [Data.SqlDbType]::DateTime2)
                $at.Value = [datetime]::Parse([string]$r.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                $cmd.Parameters.AddWithValue("@proj", [string]$r.proj) | Out-Null
                $cmd.Parameters.AddWithValue("@cwd", [string]$r.cwd) | Out-Null
                $cmd.Parameters.AddWithValue("@sid", [string]$r.sid) | Out-Null
                $cmd.Parameters.AddWithValue("@content", [string]$r.content) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
            if (Expired) { throw 'out of time after connecting' }
            & $insert $row
            $line = $null                                    # written: nothing to queue for this prompt

            # ---- drain what earlier runs queued, while there is time left ----
            $claims = @()
            if ((Test-Path -LiteralPath $spool) -and -not (Expired)) {
                $claim = Join-Path $StateDir ("spool-{0}-{1}.draining" -f $PID, [datetime]::UtcNow.Ticks)
                try {
                    Move-Item -LiteralPath $spool -Destination $claim -ErrorAction Stop; $claims += $claim   # the rename is the claim: one hook wins
                    # The rename keeps the spool's old write time; stamp it now so another run doesn't take a fresh claim for a dead one.
                    try { [IO.File]::SetLastWriteTimeUtc($claim, [datetime]::UtcNow) } catch { }
                } catch { }
            }
            # a claim left behind by a run that died while draining
            $claims += @(Get-ChildItem -LiteralPath $StateDir -Filter 'spool-*.draining' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-5) -and $claims -notcontains $_.FullName } | ForEach-Object { $_.FullName })
            $done = 0
            foreach ($claim in $claims) {
                $queued = @([IO.File]::ReadAllLines($claim) | Where-Object { $_.Trim() })
                $left = @()
                for ($i = 0; $i -lt $queued.Count; $i++) {
                    if ((Expired) -or $done -ge [int]$cfg.DrainMax) { $left = @($queued[$i..($queued.Count - 1)]); break }
                    $q = $null
                    try { $q = $queued[$i] | ConvertFrom-Json } catch { }
                    if (-not $q -or -not $q.content) { continue }                     # a torn line can never be inserted: drop it
                    try { & $insert $q; $done++ }
                    catch { $left = @($queued[$i..($queued.Count - 1)]); break }
                }
                Add-Spool $left
                Remove-Item -LiteralPath $claim -Force -ErrorAction SilentlyContinue
            }
        }
        finally { $conn.Close() }
    }
    catch {
        Write-LastError $_.Exception.Message
        if ($line) { Add-Spool @($line) }
    }
}
catch {
    # Non-fatal — never block the user's prompt on a logging failure.
}
exit 0
