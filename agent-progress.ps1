<#
.SYNOPSIS
  What every recent Claude Code subagent is doing, and roughly how far along it is.

.DESCRIPTION
  Reads the subagent transcripts Claude Code writes under
  ~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl (one JSON object per line) and,
  for each agent active within -Since minutes, reports its ticket, worktree, what it is doing right
  now, elapsed time, tool calls, and an estimated percent done.

  The percent is an estimate, not a measurement. A ticket agent (its prompt says "Work on ticket
  X") is placed on the ticket-work milestones it has reached: explore 5-20, edit 20-55, test 55-80,
  commit 85, push 95, ticket closed 99, finished 100. Within explore/edit/test it creeps up with
  each tool call and never moves backwards. Any other agent has no milestones, so its percent
  only grows with tool calls and stops at 90 until it finishes; it is marked with a "~".

  Covers every session and every project, so one CLI can see the subagents of the others too.
  Windows PowerShell 5.1 compatible (JavaScriptSerializer, raised length limit, since transcript
  lines that carry whole files can exceed ConvertFrom-Json's limit).

.PARAMETER Since
  Minutes: only agents whose transcript changed within this window. Default 120.

.PARAMETER DoneWithin
  Minutes: finished agents are listed only if they finished within this window. Default 30.

.PARAMETER Running
  Hide agents that have finished.

.PARAMETER Session
  Only agents of sessions whose id starts with this.

.PARAMETER Json
  Emit JSON instead of the text report.
#>
[CmdletBinding()]
param(
  [int]$Since = 120,
  [int]$DoneWithin = 30,
  [switch]$Running,
  [string]$Session,
  [switch]$Json,
  [string]$ClaudeRoot = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = [int]::MaxValue

# A transcript untouched this long while not finished is shown as stalled rather than working.
$stallMinutes = 10
$now = Get-Date
$cutoff = $now.AddMinutes(-$Since)

function Get-Field($dict, [string]$name) {
  if ($dict -is [System.Collections.IDictionary] -and $dict.ContainsKey($name)) { return $dict[$name] }
  return $null
}

function Limit([string]$text, [int]$max) {
  if ([string]::IsNullOrEmpty($text)) { return '' }
  $one = ($text -replace '\s+', ' ').Trim()
  if ($one.Length -le $max) { return $one }
  return $one.Substring(0, $max - 1) + '…'
}

# One line describing a tool call, the way a person would say it.
function Describe-Tool([string]$name, $toolInput) {
  $file = Get-Field $toolInput 'file_path'
  $leaf = if ($file) { Split-Path $file -Leaf } else { '' }
  switch -Regex ($name) {
    '^(Bash|PowerShell)$' {
      $d = Get-Field $toolInput 'description'
      if ($d) { return Limit $d 70 }
      return Limit ('run: ' + (Get-Field $toolInput 'command')) 70
    }
    '^Write$'        { return "write $leaf" }
    '^(Edit|MultiEdit|NotebookEdit)$' { return "edit $leaf" }
    '^Read$'         { return "read $leaf" }
    '^Grep$'         { return Limit ('search for ' + (Get-Field $toolInput 'pattern')) 70 }
    '^Glob$'         { return Limit ('find ' + (Get-Field $toolInput 'pattern')) 70 }
    '^(Agent|Task)$' { return Limit ('subagent: ' + (Get-Field $toolInput 'description')) 70 }
    '^Skill$'        { return '/' + (Get-Field $toolInput 'skill') }
    default          { return $name }
  }
}

# Milestones a ticket agent passes, in order, with the percent band each one covers.
$bands = @(
  @{ Name = 'exploring'; Lo = 5;  Hi = 20 },
  @{ Name = 'editing';   Lo = 20; Hi = 55 },
  @{ Name = 'testing';   Lo = 55; Hi = 80 },
  @{ Name = 'committed'; Lo = 85; Hi = 85 },
  @{ Name = 'pushed';    Lo = 95; Hi = 95 },
  @{ Name = 'closing';   Lo = 99; Hi = 99 }
)
$testPattern = '(?i)\b(dotnet\s+(test|build)|-runTests|npm\s+(run\s+)?test|pytest|cargo\s+test|go\s+test|run-spike|Invoke-Pester|msbuild)\b'

function Get-Milestone([string]$name, $toolInput, [string]$ticket) {
  if ($name -in @('Write', 'Edit', 'MultiEdit', 'NotebookEdit')) { return 1 }
  if ($name -in @('Bash', 'PowerShell')) {
    $cmd = [string](Get-Field $toolInput 'command')
    # Require the agent's own ticket right after "close" so closing a different (duplicate/sibling)
    # ticket, or a command that merely mentions the phrase (a grep, a commit message), doesn't count.
    if ($ticket -and $cmd -match ('(?i)(tickets|workflow)\s+ticket\s+close\s+' + [regex]::Escape($ticket) + '\b')) { return 5 }
    if ($cmd -match 'git\s+push') { return 4 }
    if ($cmd -match 'git\s+commit') { return 3 }
    if ($cmd -match $testPattern) { return 2 }
  }
  if ($name -eq 'Skill' -and (Get-Field $toolInput 'skill') -eq 'commit') { return 3 }
  return 0
}

function Read-Agent([IO.FileInfo]$file) {
  $metaPath = [IO.Path]::ChangeExtension($file.FullName, $null).TrimEnd('.') + '.meta.json'
  $meta = if (Test-Path -LiteralPath $metaPath) { $serializer.DeserializeObject([IO.File]::ReadAllText($metaPath)) } else { $null }
  $sessionDir = $file.Directory.Parent
  $agent = [ordered]@{
    id = $file.BaseName -replace '^agent-', ''
    session = $sessionDir.Name
    project = $sessionDir.Parent.Name
    description = Get-Field $meta 'description'
    type = Get-Field $meta 'agentType'
    ticket = $null; worktree = $null
    started = $null; lastActivity = $file.LastWriteTime
    toolCalls = 0; milestone = -1; phaseCalls = 0
    doing = ''; finished = $false
  }

  $first = $true
  $lastStop = $null
  $lastKind = $null
  foreach ($line in [IO.File]::ReadLines($file.FullName)) {
    # Only the opening prompt and assistant turns matter; skip the rest without parsing it.
    if (-not $first -and $line.IndexOf('"type":"assistant"') -lt 0) { continue }
    try { $o = $serializer.DeserializeObject($line) } catch { continue }
    $msg = Get-Field $o 'message'
    $ts = Get-Field $o 'timestamp'
    if ($first) {
      $first = $false
      if ($ts) { $agent.started = [datetime]$ts }
      $prompt = [string](Get-Field $msg 'content')
      if ($prompt -match 'Work on ticket\s+([A-Z][A-Z0-9.]*-T\d+)') { $agent.ticket = $Matches[1] }
      if ($prompt -match 'git worktree of [^(]+\(([^,]+),') { $agent.worktree = $Matches[1].Trim() }
      continue
    }
    if ((Get-Field $o 'type') -ne 'assistant') { continue }
    $lastStop = Get-Field $msg 'stop_reason'
    foreach ($part in @(Get-Field $msg 'content')) {
      $kind = Get-Field $part 'type'
      if ($kind -eq 'text' -or $kind -eq 'tool_use') { $lastKind = $kind }
      if ((Get-Field $part 'type') -ne 'tool_use') { continue }
      $name = [string](Get-Field $part 'name')
      $toolInput = Get-Field $part 'input'
      $agent.toolCalls++
      $agent.doing = Describe-Tool $name $toolInput
      $m = Get-Milestone $name $toolInput $agent.ticket
      if ($m -gt $agent.milestone) { $agent.milestone = $m; $agent.phaseCalls = 0 }
      $agent.phaseCalls++
    }
  }
  if ($agent.milestone -lt 0) { $agent.milestone = 0 }
  # end_turn is not always recorded on the final reply, so a closing text reply with nothing after
  # it for a minute counts too; a working agent follows its text with a tool call within seconds.
  $quiet = ((Get-Date) - $file.LastWriteTime).TotalMinutes -ge 1
  # Once the transcript shows the agent's own ticket closed (milestone 5, "closing"), it is done at
  # 100% no matter what read-only command ran afterward (e.g. a ticket verify after the close) —
  # only an agent that is still short of that milestone can be stalled.
  $agent.finished = ($lastStop -eq 'end_turn') -or ($lastKind -eq 'text' -and $quiet) -or ($agent.milestone -ge 5)
  return $agent
}

function Get-Percent($agent) {
  if ($agent.finished) { return 100 }
  if (-not $agent.ticket) { return [int][math]::Floor(90 * (1 - [math]::Exp(-$agent.toolCalls / 15.0))) }
  $band = $bands[$agent.milestone]
  return [int][math]::Floor($band.Lo + ($band.Hi - $band.Lo) * (1 - [math]::Exp(-$agent.phaseCalls / 8.0)))
}

function Get-WorktreeState([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
  # status, not diff: a new file the agent hasn't staged yet is work too.
  $changed = @(git -C $path status --porcelain 2>$null | Where-Object { $_ }).Count
  $ahead = (git -C $path rev-list --count origin/main..HEAD 2>$null | Out-String).Trim()
  $parts = @()
  if ($ahead -and $ahead -ne '0') { $parts += "$ahead commit(s) not on main" }
  if ($changed -gt 0) { $parts += "$changed file(s) changed, uncommitted" }
  return ($parts -join '; ')
}

# Dot-sourcing (the tests do) only loads the functions above.
if ($MyInvocation.InvocationName -eq '.') { return }

$projectsDir = Join-Path $ClaudeRoot 'projects'
$files = @(Get-ChildItem -Path $projectsDir -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue } |
  Where-Object { -not $Session -or $_.Name.StartsWith($Session) } |
  ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'subagents') -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue } |
  Where-Object { $_.LastWriteTime -ge $cutoff })

$agents = foreach ($f in $files) {
  $a = Read-Agent $f
  $idle = ($now - $a.lastActivity).TotalMinutes
  $a.state = if ($a.finished) { 'done' } elseif ($idle -ge $stallMinutes) { 'stalled?' } else { 'working' }
  $a.percent = Get-Percent $a
  $a.estimated = -not $a.ticket -and -not $a.finished
  $a.phase = if ($a.finished) { 'finished' } elseif ($a.ticket) { $bands[$a.milestone].Name } else { 'working' }
  $a.worktreeState = if ($a.finished) { '' } else { Get-WorktreeState $a.worktree }
  $show = if ($a.finished) { -not $Running -and $idle -lt $DoneWithin } else { $true }
  if ($show) { [pscustomobject]$a }
}
$agents = @($agents | Sort-Object @{ Expression = { $_.state -eq 'done' } }, @{ Expression = { $_.lastActivity }; Descending = $true })

if ($Json) {
  # PowerShell 5.1 would write dates as \/Date(ms)\/; ISO 8601 is what every reader expects.
  $rows = foreach ($a in $agents) {
    $r = $a.PSObject.Copy()
    $r.started = if ($a.started) { ([datetime]$a.started).ToString('o') } else { $null }
    $r.lastActivity = $a.lastActivity.ToString('o')
    $r
  }
  ConvertTo-Json -InputObject @($rows) -Depth 4
  exit 0
}

if ($agents.Count -eq 0) {
  "No subagents active in the last $Since minutes."
  exit 0
}

function Format-Span([timespan]$t) {
  if ($t.TotalHours -ge 1) { return '{0}h{1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
  if ($t.TotalMinutes -ge 1) { return '{0}m{1:00}s' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds }
  return '{0}s' -f [int]$t.TotalSeconds
}

function Bar([int]$pct) {
  $filled = [int][math]::Round($pct / 10)
  return ('█' * $filled) + ('░' * (10 - $filled))
}

$working = @($agents | Where-Object { $_.state -ne 'done' }).Count
"Subagents: $working running (active in the last $Since min), $($agents.Count - $working) finished in the last $DoneWithin min"
''
foreach ($a in $agents) {
  $label = if ($a.ticket) { $a.ticket } else { Limit $a.description 40 }
  $pct = if ($a.estimated) { "~$($a.percent)%" } else { "$($a.percent)%" }
  $elapsed = if ($a.started) { Format-Span ($a.lastActivity - [datetime]$a.started) } else { '?' }
  $idle = Format-Span ($now - $a.lastActivity)
  '{0} {1,5}  {2}  [{3}]' -f (Bar $a.percent), $pct, $label, $a.state
  if ($a.ticket -and $a.description -and $a.description -notmatch [regex]::Escape($a.ticket)) { "    $(Limit $a.description 80)" }
  '    phase: {0} · {1} tool calls · ran {2} · last activity {3} ago' -f $a.phase, $a.toolCalls, $elapsed, $idle
  if (-not $a.finished -and $a.doing) { "    now: $($a.doing)" }
  if ($a.worktreeState) { "    worktree: $($a.worktreeState)" }
  "    session $($a.session.Substring(0, 8)) · $($a.project)"
  ''
}
'Percent is an estimate from milestones (explore → edit → test → commit → push → close); "~" means no milestones, by tool calls only.'
