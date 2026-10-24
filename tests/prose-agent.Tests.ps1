# Pester tests for prose-agent.ps1's shareable handoff codes (/quicksave, /quickload <code>). Run: Invoke-Pester .\tests
#
# The runner is invoked as a real child process (as the global commands do), with -RepoRoot and
# -RegistryRoot pointed into TestDrive so nothing touches the real registry or any repo's .agent folder.

BeforeAll {
    $script:Runner = Join-Path $PSScriptRoot '..\prose-agent.ps1'
    $script:Pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Invoke-Runner([string[]]$RunnerArgs) {
        $out = & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File $script:Runner @RunnerArgs
        $script:LastExit = $LASTEXITCODE
        return ($out -join [Environment]::NewLine)
    }

    function Save-Handoff([string]$Repo, [string]$Registry, [string]$Task) {
        $json = Invoke-Runner @('save', '-RepoRoot', $Repo, '-RegistryRoot', $Registry, '-Task', $Task, '-Decisions', 'd1', '-State', 's1', '-Next', 'n1', '-Json')
        if ($script:LastExit -ne 0) { throw "save exited $script:LastExit`n$json" }
        return ($json | ConvertFrom-Json)
    }
}

Describe 'quicksave shareable code' {
    BeforeEach {
        $script:Registry = Join-Path $TestDrive ('registry-' + [guid]::NewGuid().ToString('N'))
        $script:RepoA = Join-Path $TestDrive ('RepoA-' + [guid]::NewGuid().ToString('N'))
        $script:RepoB = Join-Path $TestDrive ('RepoB-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:RepoA, $script:RepoB -Force | Out-Null
    }

    It 'picks an adjective-animal code from the word lists and records the handoff in the registry' {
        $saved = Save-Handoff $script:RepoA $script:Registry 'build the thing'
        $saved.code | Should -Match '^[a-z]+-[a-z]+$'
        $adj, $animal = $saved.code -split '-'
        Get-Content (Join-Path $PSScriptRoot '..\shared\handoff-words\adjectives.txt') | Should -Contain $adj
        Get-Content (Join-Path $PSScriptRoot '..\shared\handoff-words\animals.txt') | Should -Contain $animal

        $entry = Get-Content (Join-Path $script:Registry "$($saved.code).json") -Raw | ConvertFrom-Json
        $entry.code | Should -Be $saved.code
        $entry.task | Should -Be 'build the thing'
        $entry.decisions | Should -Be 'd1'
        $entry.state | Should -Be 's1'
        $entry.next | Should -Be 'n1'
        $entry.repo.path | Should -Be $script:RepoA
    }

    It 'never reuses a code that is still unconsumed' {
        $codes = @(1..25 | ForEach-Object { (Save-Handoff $script:RepoA $script:Registry "task $_").code })
        @($codes | Select-Object -Unique).Count | Should -Be 25
        @(Get-ChildItem $script:Registry -Filter '*.json' -File).Count | Should -Be 25
    }

    It 'regenerates on collision with an unconsumed code and refuses when every code is taken' {
        # A private copy of the runner with a 1 x 2 word list, so the only two codes are known.
        $tiny = Join-Path $TestDrive ('tiny-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $tiny 'shared\handoff-words') -Force | Out-Null
        Copy-Item $script:Runner (Join-Path $tiny 'prose-agent.ps1')
        Set-Content (Join-Path $tiny 'shared\handoff-words\adjectives.txt') 'lively'
        Set-Content (Join-Path $tiny 'shared\handoff-words\animals.txt') "oxen`nyaks"
        New-Item -ItemType Directory -Path $script:Registry -Force | Out-Null
        Set-Content (Join-Path $script:Registry 'lively-oxen.json') '{"code":"lively-oxen","task":"taken"}'

        $saveArgs = @('save', '-RepoRoot', $script:RepoA, '-RegistryRoot', $script:Registry, '-Task', 't', '-Next', 'n', '-Json')
        $out = & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tiny 'prose-agent.ps1') @saveArgs
        $LASTEXITCODE | Should -Be 0
        (($out -join "`n") | ConvertFrom-Json).code | Should -Be 'lively-yaks'
        (Get-Content (Join-Path $script:Registry 'lively-oxen.json') -Raw | ConvertFrom-Json).task | Should -Be 'taken'

        $out = & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tiny 'prose-agent.ps1') @saveArgs 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'No free handoff code'
    }

    It 'records the repo a worktree belongs to, and its branch' {
        $main = Join-Path $TestDrive ('main-' + [guid]::NewGuid().ToString('N'))
        $wt = Join-Path $TestDrive ('wt-' + [guid]::NewGuid().ToString('N'))
        git init -q -b main $main
        git -C $main -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
        git -C $main worktree add -q -b feature-x $wt
        $saved = Save-Handoff $wt $script:Registry 'in a worktree'
        $saved.repo.worktree | Should -BeTrue
        $saved.repo.branch | Should -Be 'feature-x'
        $saved.repo.name | Should -Be (Split-Path -Leaf $main)
    }

    It 'quickload by code loads that exact handoff from another folder and consumes it' {
        $first = Save-Handoff $script:RepoA $script:Registry 'first task'
        $null = Save-Handoff $script:RepoA $script:Registry 'second task'

        $out = Invoke-Runner @('load', $first.code, '-RepoRoot', $script:RepoB, '-RegistryRoot', $script:Registry)
        $script:LastExit | Should -Be 0
        $out | Should -Match 'Task: first task'
        $out | Should -Match ([regex]::Escape("Code: $($first.code)"))
        $out | Should -Match ([regex]::Escape($script:RepoA))

        Test-Path (Join-Path $script:Registry "$($first.code).json") | Should -BeFalse
        @(Get-ChildItem (Join-Path $script:Registry 'consumed') -Filter "$($first.code).*.json").Count | Should -Be 1
        # The other repo's local save is untouched; the saving repo's live save (the second task) too.
        Test-Path (Join-Path $script:RepoB '.agent\agent-session.json') | Should -BeFalse
        (Get-Content (Join-Path $script:RepoA '.agent\agent-session.json') -Raw | ConvertFrom-Json).task | Should -Be 'second task'
    }

    It 'loading a consumed code again recalls the same handoff read-only' {
        $saved = Save-Handoff $script:RepoA $script:Registry 'recall me'
        $null = Invoke-Runner @('load', $saved.code, '-RepoRoot', $script:RepoB, '-RegistryRoot', $script:Registry)
        $out = Invoke-Runner @('load', $saved.code, '-RepoRoot', $script:RepoB, '-RegistryRoot', $script:Registry)
        $script:LastExit | Should -Be 0
        $out | Should -Match 'already loaded'
        $out | Should -Match 'Task: recall me'
    }

    It 'an unknown code fails plainly' {
        $out = Invoke-Runner @('load', 'nonexistent-yetis', '-RepoRoot', $script:RepoB, '-RegistryRoot', $script:Registry)
        $script:LastExit | Should -Be 1
        $out | Should -Match "No handoff with code 'nonexistent-yetis'"
    }

    It 'a plain local load also consumes the code of the save it restores' {
        $saved = Save-Handoff $script:RepoA $script:Registry 'local task'
        $out = Invoke-Runner @('load', '-RepoRoot', $script:RepoA, '-RegistryRoot', $script:Registry)
        $out | Should -Match 'Task: local task'
        Test-Path (Join-Path $script:Registry "$($saved.code).json") | Should -BeFalse
        Test-Path (Join-Path $script:RepoA '.agent\agent-session.json.001') | Should -BeTrue
    }

    It 'loading by code in the saving repo also archives the matching local save' {
        $saved = Save-Handoff $script:RepoA $script:Registry 'same repo'
        $null = Invoke-Runner @('load', $saved.code, '-RepoRoot', $script:RepoA, '-RegistryRoot', $script:Registry)
        Test-Path (Join-Path $script:RepoA '.agent\agent-session.json') | Should -BeFalse
        Test-Path (Join-Path $script:RepoA '.agent\agent-session.json.001') | Should -BeTrue
    }

    It 'handoffs lists only unconsumed codes' {
        $a = Save-Handoff $script:RepoA $script:Registry 'kept'
        $b = Save-Handoff $script:RepoB $script:Registry 'loaded'
        $null = Invoke-Runner @('load', $b.code, '-RepoRoot', $script:RepoB, '-RegistryRoot', $script:Registry)
        $rows = @((Invoke-Runner @('handoffs', '-RegistryRoot', $script:Registry, '-Json')) | ConvertFrom-Json)
        @($rows | ForEach-Object { $_.code }) | Should -Be @($a.code)
    }
}
