# Pester tests for shared/hooks/commit-msg's ticket check (M.ORCH-T1697): a definite "No ticket" refuses; a timeout or
# locked database is retried and then lets the commit through. Run: Invoke-Pester .\tests (only when the user asks for tests).
# A fake `tickets` CLI on PATH stands in for the real one; the hook runs as a real `sh` child process.

BeforeAll {
    $script:Hook = (Resolve-Path (Join-Path $PSScriptRoot '..\shared\hooks\commit-msg')).Path

    function Invoke-Hook([string]$Subject, [string]$FakeBody) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("cm-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        $fake = "#!/bin/sh`n$FakeBody`n"
        [IO.File]::WriteAllText((Join-Path $dir 'tickets'), $fake.Replace("`r`n", "`n"))
        $msg = Join-Path $dir 'MSG'
        [IO.File]::WriteAllText($msg, "$Subject`n")
        $oldPath = $env:PATH
        $env:PATH = "$dir;$env:PATH"
        $env:MINDATTIC_COMMIT_GATE = 'off'; $env:MINDATTIC_TICKET_CHECK_WAIT = '0'; $env:MINDATTIC_TICKET_CHECK_TRIES = '3'
        try {
            $err = sh $script:Hook $msg 2>&1
            return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($err -join "`n") }
        }
        finally {
            $env:PATH = $oldPath
            Remove-Item Env:MINDATTIC_COMMIT_GATE, Env:MINDATTIC_TICKET_CHECK_WAIT, Env:MINDATTIC_TICKET_CHECK_TRIES
            Remove-Item $dir -Recurse -Force
        }
    }
}

Describe 'commit-msg ticket check' {
    It 'lets a commit through when the ticket exists' {
        (Invoke-Hook 'Fix it (M.ORCH-T1)' 'exit 0').Code | Should -Be 0
    }
    It 'refuses when the ticket definitely does not exist' {
        $r = Invoke-Hook 'Fix it (M.ORCH-T1)' 'echo "error: No ticket M.ORCH-T1." >&2; exit 1'
        $r.Code | Should -Be 1
        $r.Text | Should -Match "isn't in the ticket database"
    }
    It 'fails open, with a warning, when the lookup keeps timing out' {
        $r = Invoke-Hook 'Fix it (M.ORCH-T1)' 'echo "database is locked" >&2; exit 1'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'committing anyway'
    }
    It 'retries a timeout and passes when a later try succeeds' {
        $r = Invoke-Hook 'Fix it (M.ORCH-T1)' 'f="$(dirname "$0")/n"; if [ -f "$f" ]; then exit 0; fi; : > "$f"; echo timeout >&2; exit 1'
        $r.Code | Should -Be 0
        $r.Text | Should -Not -Match 'committing anyway'
    }
}
