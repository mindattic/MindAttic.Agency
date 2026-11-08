# Pester tests for shared/hooks/test-gate.py (MAT-T121: the no-test GOLDEN RULE hook). Run: Invoke-Pester .\tests
# (only when the user asks for tests - this very hook refuses it otherwise).
#
# The hook is run as a real child process with hook JSON on stdin, exactly as every CLI runs it. Its permission state
# goes to a per-test folder (MINDATTIC_TEST_GATE_DIR), never the live ~/.claude/session-context/test-gate.

BeforeAll {
    $script:Hook = Join-Path $PSScriptRoot '..\shared\hooks\test-gate.py'

    function Invoke-Gate([hashtable]$Payload, [string]$Raw) {
        $json = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { $Payload | ConvertTo-Json -Compress -Depth 5 }
        $out = $json | python $script:Hook
        if ($LASTEXITCODE -ne 0) { throw "test-gate.py exited $LASTEXITCODE" }
        $text = ($out -join "`n").Trim()
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    }

    function Send-Prompt([string]$Session, [string]$Prompt) {
        Invoke-Gate @{ hook_event_name = 'UserPromptSubmit'; session_id = $Session; prompt = $Prompt } | Out-Null
    }

    function Test-Denied([string]$Session, [string]$Command, [string]$AgentId, [string]$Cwd = $env:TEMP) {
        $p = @{ hook_event_name = 'PreToolUse'; session_id = $Session; tool_name = 'Bash'; cwd = $Cwd; tool_input = @{ command = $Command } }
        if ($AgentId) { $p.agent_id = $AgentId }
        $r = Invoke-Gate $p
        return ($null -ne $r -and $r.hookSpecificOutput.permissionDecision -eq 'deny')
    }
}

BeforeEach {
    $env:MINDATTIC_TEST_GATE_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
}

AfterAll {
    Remove-Item Env:\MINDATTIC_TEST_GATE_DIR -ErrorAction SilentlyContinue
}

Describe 'test-gate.py matcher: refuses test runners and soaks, allows builds (MAT-T121)' {
    It 'refuses <cmd>' -ForEach @(
        @{ cmd = 'dotnet test' }
        @{ cmd = 'cd src && dotnet test Foo.csproj --filter Bar' }
        @{ cmd = '"C:/Program Files/dotnet/dotnet.exe" test' }
        @{ cmd = 'pwsh -NoProfile -Command "cd D:/x; dotnet test"' }
        @{ cmd = 'pytest -q' }
        @{ cmd = 'python -m pytest tests' }
        @{ cmd = 'py -3 -m pytest' }
        @{ cmd = 'npm test' }
        @{ cmd = 'npm run test' }
        @{ cmd = 'yarn test' }
        @{ cmd = 'pnpm test' }
        @{ cmd = 'bash -c "npm test"' }
        @{ cmd = 'npx vitest run' }
        @{ cmd = 'npx jest --ci' }
        @{ cmd = 'cargo test' }
        @{ cmd = 'ctest --output-on-failure' }
        @{ cmd = 'go test ./...' }
        @{ cmd = 'pwsh tools/test.ps1' }
        @{ cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File tools\test.ps1 -Compile' }
        @{ cmd = 'Invoke-Pester .\tests' }
        @{ cmd = '"C:/Program Files/Unity/Editor/Unity.exe" -batchmode -runTests -testPlatform EditMode' }
        @{ cmd = 'python tools/harness.py campaign 3' }
        @{ cmd = 'python tools/run_balance.py' }
    ) {
        Test-Denied -Session 's-match' -Command $cmd | Should -BeTrue
    }

    It 'allows <cmd>' -ForEach @(
        @{ cmd = 'dotnet build -c Release' }
        @{ cmd = 'npm run build' }
        @{ cmd = 'cargo build' }
        @{ cmd = 'go build ./...' }
        @{ cmd = 'python -m py_compile x.py' }
        @{ cmd = 'pwsh tools/build.ps1' }
        @{ cmd = 'python tools/harness.py smoke' }
        @{ cmd = 'git commit -m "Run dotnet test now passes"' }
        @{ cmd = "git commit -F - <<'EOF'`ndotnet test passes`nEOF" }
        @{ cmd = 'grep -n test file.txt' }
        @{ cmd = 'tickets ticket show MAT-T121' }
    ) {
        Test-Denied -Session 's-match' -Command $cmd | Should -BeFalse
    }

    It 'says why and what to do instead' {
        $r = Invoke-Gate @{ hook_event_name = 'PreToolUse'; session_id = 's-why'; tool_name = 'Bash'; tool_input = @{ command = 'dotnet test' } }
        $r.hookSpecificOutput.permissionDecisionReason | Should -Match 'GOLDEN RULE'
        $r.hookSpecificOutput.permissionDecisionReason | Should -Match 'build'
        $r.hookSpecificOutput.permissionDecisionReason | Should -Match '/test'
    }

    It "adds a repo's own .agent/test-gate-patterns.json to the shared list" {
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git'), (Join-Path $repo '.agent') | Out-Null
        '{ "patterns": [ { "name": "repo soak", "regex": "mysim\\b" } ] }' | Set-Content -Encoding utf8 (Join-Path $repo '.agent\test-gate-patterns.json')
        Test-Denied -Session 's-repo' -Command 'mysim --seeds 24' -Cwd $repo | Should -BeTrue
        Test-Denied -Session 's-repo' -Command 'mysim --seeds 24' -Cwd $env:TEMP | Should -BeFalse
        Test-Denied -Session 's-repo' -Command 'dotnet test' -Cwd $repo | Should -BeTrue
    }
}

Describe 'test-gate.py permission: only the user''s latest prompt can ask for tests (MAT-T121)' {
    It 'allows tests after the prompt <prompt>' -ForEach @(
        @{ prompt = '/test' }
        @{ prompt = '/tests' }
        @{ prompt = '/run tests' }
        @{ prompt = '/test Unity.GridGame' }
        @{ prompt = '<command-name>/test</command-name>' }
        @{ prompt = 'run the tests' }
        @{ prompt = 'please run tests and fix what fails' }
        @{ prompt = 'rerun the full test suite' }
    ) {
        Send-Prompt 's-ask' $prompt
        Test-Denied -Session 's-ask' -Command 'dotnet test' | Should -BeFalse
    }

    It 'still refuses after the prompt <prompt>' -ForEach @(
        @{ prompt = 'fix the bug' }
        @{ prompt = "don't run the tests" }
        @{ prompt = 'do not run tests, just build' }
        @{ prompt = 'Tests run only when the user says so (`/run tests`)' }
        @{ prompt = '/testing' }
    ) {
        Send-Prompt 's-no' $prompt
        Test-Denied -Session 's-no' -Command 'dotnet test' | Should -BeTrue
    }

    It 'lasts one user turn: the next prompt takes it away' {
        Send-Prompt 's-turn' '/test'
        Test-Denied -Session 's-turn' -Command 'dotnet test' | Should -BeFalse
        Send-Prompt 's-turn' 'now fix the failures'
        Test-Denied -Session 's-turn' -Command 'dotnet test' | Should -BeTrue
    }

    It "is per session: one CLI's /test doesn't open another's" {
        Send-Prompt 's-a' '/test'
        Test-Denied -Session 's-b' -Command 'dotnet test' | Should -BeTrue
    }

    It "lets a subagent inherit its parent turn's permission (same session_id, its own agent_id)" {
        Send-Prompt 's-sub' '/test'
        Test-Denied -Session 's-sub' -AgentId 'agent-1' -Command 'dotnet test' | Should -BeFalse
    }

    It 'keeps a subagent started by a /test turn allowed after the user types something else, and never opens one started by another turn' {
        Send-Prompt 's-snap' '/test'
        Invoke-Gate @{ hook_event_name = 'SubagentStart'; session_id = 's-snap'; agent_id = 'tester' } | Out-Null
        Send-Prompt 's-snap' 'meanwhile, rename the button'
        Invoke-Gate @{ hook_event_name = 'SubagentStart'; session_id = 's-snap'; agent_id = 'builder' } | Out-Null
        Send-Prompt 's-snap' '/test'

        Test-Denied -Session 's-snap' -AgentId 'tester' -Command 'dotnet test' | Should -BeFalse
        Test-Denied -Session 's-snap' -AgentId 'builder' -Command 'dotnet test' | Should -BeTrue
    }
}

Describe 'test-gate.py fails open (MAT-T121)' {
    It 'allows on <name>' -ForEach @(
        @{ name = 'empty stdin'; raw = '' }
        @{ name = 'garbage stdin'; raw = 'not json {' }
        @{ name = 'a JSON array'; raw = '[1,2]' }
        @{ name = 'a tool with no command'; raw = '{"hook_event_name":"PreToolUse","session_id":"x","tool_name":"Write","tool_input":{"content":"dotnet test"}}' }
    ) {
        Invoke-Gate -Raw $raw | Should -BeNullOrEmpty
    }
}
