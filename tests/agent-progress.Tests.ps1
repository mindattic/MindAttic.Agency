# Pester tests for agent-progress.ps1 (the /progress report). Run: Invoke-Pester .\tests
#
# agent-progress.ps1 is invoked as a real child process (as /progress does), not dot-sourced: its
# Read-Agent loop uses `continue` inside a `foreach`, which is legal PowerShell but trips Pester's
# own scriptblock instrumentation when the function is dot-sourced and called from inside an It
# block (https://github.com/pester/Pester/issues/2669). Running the script end to end is also a
# more faithful test of the actual /progress behavior (discovery, parsing, percent, JSON output).
#
# Fixture transcripts live under tests/fixtures/<case>/projects/<project>/<session>/subagents/, the
# same layout agent-progress.ps1 reads under ~/.claude/projects (each case's fixtures folder is
# passed in as -ClaudeRoot). Each test stamps the transcript file's LastWriteTime itself so the
# "how long has it been idle" math is deterministic regardless of when the fixture was checked out.

BeforeAll {
    $script:AgentProgress = Join-Path $PSScriptRoot '..\agent-progress.ps1'
    $script:Pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Invoke-AgentProgress([string]$Case, [string]$FileName, [double]$IdleMinutes) {
        $claudeRoot = Join-Path $PSScriptRoot "fixtures\$Case"
        $jsonlPath = Get-ChildItem -Path $claudeRoot -Recurse -Filter $FileName | Select-Object -First 1 -ExpandProperty FullName
        (Get-Item -LiteralPath $jsonlPath).LastWriteTime = (Get-Date).AddMinutes(-$IdleMinutes)

        $out = & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File $script:AgentProgress `
            -ClaudeRoot $claudeRoot -Since 200 -DoneWithin 200 -Json
        if ($LASTEXITCODE -ne 0) { throw "agent-progress.ps1 exited $LASTEXITCODE`n$out" }
        $rows = @(($out -join [Environment]::NewLine) | ConvertFrom-Json)
        return $rows | Select-Object -First 1
    }
}

Describe 'agent-progress.ps1: ticket-closed-then-read-only-command (MAT-T16)' {
    It 'is finished at 100%, not stalled, when the last tool call is a ticket verify after the ticket close' {
        # Mirrors the M.COMP-T33 report: closed, then a "workflow/tickets ticket verify" ran 1h40m
        # before /progress was run. MAT-T15 alone (end_turn / trailing text) does not cover this,
        # because the transcript's last turn is a tool call, not a text reply.
        $agent = Invoke-AgentProgress -Case 'close-then-verify' -FileName 'agent-abc123.jsonl' -IdleMinutes 100

        $agent.ticket | Should -Be 'M.COMP-T33'
        $agent.milestone | Should -Be 5
        $agent.finished | Should -BeTrue
        $agent.state | Should -Be 'done'
        $agent.percent | Should -Be 100
    }

    It 'is finished even moments after the close, before any idle time has passed' {
        $agent = Invoke-AgentProgress -Case 'close-then-verify' -FileName 'agent-abc123.jsonl' -IdleMinutes 0.1

        $agent.finished | Should -BeTrue
        $agent.state | Should -Be 'done'
    }
}

Describe 'agent-progress.ps1: does not over-fix a genuinely stalled agent' {
    It 'still reports stalled when the agent has not reached the ticket-close milestone' {
        # Same idle time as the close-then-verify case, but this agent never closed its ticket —
        # its last tool call was a test run. It must still be flagged stalled.
        $agent = Invoke-AgentProgress -Case 'mid-test-stalled' -FileName 'agent-def456.jsonl' -IdleMinutes 100

        $agent.ticket | Should -Be 'M.COMP-T40'
        $agent.milestone | Should -Be 2
        $agent.finished | Should -BeFalse
        $agent.state | Should -Be 'stalled?'
    }

    It 'does not finish an agent that closed a different (e.g. duplicate) ticket, not its own' {
        # A close match with no ticket check would let any matching command finish the agent, even
        # mid-edit. The agent's own ticket is M.COMP-T50; the close it ran was for M.COMP-T49.
        $agent = Invoke-AgentProgress -Case 'closes-a-different-ticket' -FileName 'agent-ghi789.jsonl' -IdleMinutes 100

        $agent.ticket | Should -Be 'M.COMP-T50'
        $agent.milestone | Should -Be 1
        $agent.finished | Should -BeFalse
        $agent.state | Should -Be 'stalled?'
    }
}
