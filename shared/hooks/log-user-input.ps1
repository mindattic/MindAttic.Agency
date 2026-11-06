
# Logs every user prompt, across every project, to a shared cross-project DB
# (ClaudeActivity.UserInputLog) with a Project column derived from cwd. Fire-and-forget:
# never blocks or fails the actual prompt submission.
try {
    $raw = [Console]::In.ReadToEnd()
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

    Add-Type -AssemblyName System.Data
    $conn = New-Object System.Data.SqlClient.SqlConnection("Server=(localdb)\MSSQLLocalDB;Database=ClaudeActivity;Integrated Security=True;")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "INSERT INTO UserInputLog (ReceivedAtUtc, Project, Cwd, SessionId, Content) VALUES (SYSUTCDATETIME(), @proj, @cwd, @sid, @content)"
    $cmd.Parameters.AddWithValue("@proj", [string]$project) | Out-Null
    $cmd.Parameters.AddWithValue("@cwd", [string]$cwd) | Out-Null
    $cmd.Parameters.AddWithValue("@sid", [string]$sessionId) | Out-Null
    $cmd.Parameters.AddWithValue("@content", [string]$prompt) | Out-Null
    $cmd.ExecuteNonQuery() | Out-Null
    $conn.Close()
}
catch {
    # Non-fatal — never block the user's prompt on a logging failure.
}
exit 0
