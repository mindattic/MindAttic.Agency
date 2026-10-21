<#
.SYNOPSIS
    Builds a repo's DocFX documentation site: README.md is the home page, docs/**/*.md are articles,
    and an optional API reference comes from the repo's C# sources.

.DESCRIPTION
    The one copy of the MindAttic docs-site engine. Nothing per-repo is committed except the thin
    .github/workflows/docs.yml caller (see adopt-docs-site.ps1); this script stages the Markdown into
    a scratch folder, generates toc.yml and docfx.json there, and (with -Build/-Serve) runs DocFX.

    Staging rewrites relative links: a link to another published page stays a page link (README.md
    becomes index.md), a link to an image is copied alongside, and a link to anything that isn't on
    the site (source files, folders, excluded Markdown) points at the file on GitHub instead.

    Not published: docs/USER_STORIES.md, docs/AMENDMENTS.md and docs/BIBLE.digest.md (generated
    ticket log and digests), and any Markdown outside README.md and docs/.

    Runs on Windows PowerShell 5.1 and PowerShell 7 (the GitHub runner).

.EXAMPLE
    powershell -File shared\docs-site\build-docs-site.ps1 -Root D:\Projects\MindAttic\MindAttic.Legion -Api -Serve
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Out,
    [string]$Repo,
    [string]$Owner = 'mindattic',
    [string]$Branch = 'main',
    [switch]$Api,
    [switch]$Build,
    [switch]$Serve,
    [string]$Docfx = 'docfx'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
if (-not $Repo) { $Repo = Split-Path -Leaf $Root }
if (-not $Out) { $Out = Join-Path ([IO.Path]::GetTempPath()) "docfx-$Repo" }
$Template = Join-Path $PSScriptRoot 'template'

$ExcludedDocs = @('USER_STORIES.md', 'AMENDMENTS.md', 'BIBLE.digest.md')
$AssetExt = @('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.bmp', '.mp4', '.webm', '.pdf')
$BlobBase = "https://github.com/$Owner/$Repo"

function ToSlash([string]$p) { $p -replace '\\', '/' }

function RepoRel([string]$full) {
    ToSlash ($full.Substring($Root.Length).TrimStart('\', '/'))
}

function NormalizeRel([string]$rel) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($seg in ($rel -split '/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1)
        } else { $parts.Add($seg) }
    }
    $parts -join '/'
}

function RelativeTo([string]$fromDir, [string]$to) {
    $f = @(if ($fromDir) { $fromDir -split '/' })
    $t = @($to -split '/')
    $i = 0
    while ($i -lt $f.Count -and $i -lt ($t.Count - 1) -and $f[$i] -eq $t[$i]) { $i++ }
    $up = @(for ($j = $i; $j -lt $f.Count; $j++) { '..' })
    (@($up) + @($t[$i..($t.Count - 1)])) -join '/'
}

function FirstHeading([string]$path) {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^#\s+(.+?)\s*#*\s*$') { return $Matches[1].Trim() }
    }
    [IO.Path]::GetFileNameWithoutExtension($path)
}

# Published pages: repo-relative source path -> staged path.
$pages = [ordered]@{}
$readme = Join-Path $Root 'README.md'
if (Test-Path -LiteralPath $readme) { $pages['README.md'] = 'index.md' }
$docsDir = Join-Path $Root 'docs'
if (Test-Path -LiteralPath $docsDir) {
    Get-ChildItem -LiteralPath $docsDir -Recurse -File -Filter *.md |
        Where-Object { $ExcludedDocs -notcontains $_.Name -and (RepoRel $_.FullName) -notmatch '(^|/)(node_modules|bin|obj)/' } |
        Sort-Object FullName |
        ForEach-Object { $r = RepoRel $_.FullName; $pages[$r] = $r }
}

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Path $Out | Out-Null

$script:copied = @{}
function CopyAsset([string]$rel) {
    if ($script:copied.ContainsKey($rel)) { return }
    $dest = Join-Path $Out $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root $rel) -Destination $dest
    $script:copied[$rel] = $true
}

function RewriteTarget([string]$target, [string]$srcRel, [string]$stagedRel) {
    if ($target -match '^(?i)([a-z][a-z0-9+.-]*:|#|/|~)') { return $target }
    $suffix = ''
    $m = [regex]::Match($target, '[#?].*$')
    if ($m.Success) { $suffix = $m.Value; $target = $target.Substring(0, $m.Index) }
    if (-not $target) { return $suffix }
    $srcDir = if ($srcRel.Contains('/')) { $srcRel.Substring(0, $srcRel.LastIndexOf('/')) } else { '' }
    $rel = NormalizeRel ((@($srcDir, [Uri]::UnescapeDataString($target)) | Where-Object { $_ }) -join '/')
    if ($null -eq $rel) { return $null }
    $stagedDir = if ($stagedRel.Contains('/')) { $stagedRel.Substring(0, $stagedRel.LastIndexOf('/')) } else { '' }

    if ($pages.Contains($rel)) { return (RelativeTo $stagedDir $pages[$rel]) + $suffix }
    $full = Join-Path $Root $rel
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ($AssetExt -contains [IO.Path]::GetExtension($rel).ToLowerInvariant()) {
            CopyAsset $rel
            return (RelativeTo $stagedDir $rel) + $suffix
        }
        return "$BlobBase/blob/$Branch/$rel$suffix"
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        if ($rel -eq '') { return "$BlobBase$suffix" }
        return "$BlobBase/tree/$Branch/$rel$suffix"
    }
    $target + $suffix
}

$mdLink = [regex]'(!?\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?)([^)\s>]+)(>?(?:\s+(?:"[^"]*"|''[^'']*''))?\s*\))'
$refDef = [regex]'^(\s{0,3}\[[^\]]+\]:\s*<?)(\S+?)(>?(\s.*)?)$'
$htmlAttr = [regex]'(\b(?:src|href)\s*=\s*")([^"]+)(")'
$anchorId = [regex]'\{#([^}\s]+)\}'

# A link that leaves the repo (e.g. ../MindAttic.HouseRules.md) has no public page; keep its text only.
function MdLinkEval($m, $sr, $st) {
    $t = RewriteTarget $m.Groups[3].Value $sr $st
    if ($null -eq $t) { return $m.Groups[2].Value }
    $m.Groups[1].Value + $t + $m.Groups[4].Value
}
function KeepEval($m, $sr, $st) {
    $t = RewriteTarget $m.Groups[2].Value $sr $st
    if ($null -eq $t) { $t = $m.Groups[2].Value }
    $m.Groups[1].Value + $t + $m.Groups[3].Value
}

foreach ($srcRel in $pages.Keys) {
    $stagedRel = $pages[$srcRel]
    $lines = [IO.File]::ReadAllLines((Join-Path $Root $srcRel))
    # Codex front matter is internal metadata, not page content.
    if ($lines.Count -gt 1 -and $lines[0] -eq '---') {
        $end = [Array]::IndexOf($lines, '---', 1)
        if ($end -gt 0) { $lines = @($lines | Select-Object -Skip ($end + 1)) }
    }
    $fence = $null
    $outLines = foreach ($line in $lines) {
        if ($line -match '^\s{0,3}(`{3,}|~{3,})') {
            $tick = $Matches[1]
            if (-not $fence) { $fence = $tick } elseif ($tick.StartsWith($fence.Substring(0, 3))) { $fence = $null }
            $line; continue
        }
        if ($fence) { $line; continue }
        $sr = $srcRel; $st = $stagedRel
        $line = $mdLink.Replace($line, { param($m) MdLinkEval $m $sr $st })
        $line = $refDef.Replace($line, { param($m) KeepEval $m $sr $st })
        $line = $htmlAttr.Replace($line, { param($m) KeepEval $m $sr $st })
        # BIBLE-style "{#id}" anchors (on headings or list items) become inline anchors DocFX keeps.
        $anchorId.Replace($line, '<a id="$1"></a>')
    }
    $dest = Join-Path $Out $stagedRel
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    [IO.File]::WriteAllText($dest, (($outLines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

# DocFX copies only template files it already knows (logo.svg), so the favicon is staged as a resource.
Copy-Item -LiteralPath (Join-Path $Template 'favicon.svg') -Destination (Join-Path $Out 'favicon.svg')

if (-not $pages.Contains('README.md')) {
    [IO.File]::WriteAllText((Join-Path $Out 'index.md'), "# $Repo`n`nThis repository has no README.md yet.`n", (New-Object Text.UTF8Encoding $false))
}

function YamlStr([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# docs/toc.yml mirrors the docs/ folder tree; each page is named by its first H1.
$docPages = @($pages.Keys | Where-Object { $_ -ne 'README.md' })
function TocLines([string]$dirRel, [int]$indent) {
    $pad = ' ' * $indent
    $here = @($docPages | Where-Object { (Split-Path -Parent ($_ -replace '/', '\')) -replace '\\', '/' -eq $dirRel })
    foreach ($p in $here) {
        "$pad- name: $(YamlStr (FirstHeading (Join-Path $Root $p)))"
        "$pad  href: $(RelativeTo 'docs' $p)"
    }
    $subs = @($docPages | Where-Object { $_.StartsWith("$dirRel/") } |
        ForEach-Object { $_.Substring($dirRel.Length + 1).Split('/')[0] } |
        Where-Object { $_ -notlike '*.md' } | Sort-Object -Unique)
    foreach ($s in $subs) {
        "$pad- name: $(YamlStr $s)"
        "$pad  items:"
        TocLines "$dirRel/$s" ($indent + 4)
    }
}

$nav = @('- name: Home', '  href: index.md')
if ($docPages.Count) {
    [IO.File]::WriteAllText((Join-Path $Out 'docs/toc.yml'), ((@(TocLines 'docs' 0) -join "`n") + "`n"))
    $nav += @('- name: Docs', '  href: docs/')
}
if ($Api) { $nav += @('- name: API', '  href: api/') }
[IO.File]::WriteAllText((Join-Path $Out 'toc.yml'), (($nav -join "`n") + "`n"))

$footer = "<a href=`"$BlobBase`">$Repo on GitHub</a> &middot; built by the MindAttic.Agency docs pipeline from README.md and docs/"
$config = [ordered]@{}
if ($Api) {
    # Read the .cs sources directly rather than the .csproj files: a project load needs a NuGet
    # restore, and most MindAttic packages only exist in the local C:\LocalNuGet feed, not in CI.
    $config.metadata = @([ordered]@{
        src    = @([ordered]@{
            src     = (ToSlash $Root)
            files   = @('**/*.cs')
            exclude = @('**/*Test*/**', '**/*Tests/**', '**/bin/**', '**/obj/**', '**/node_modules/**', '**/Library/**', '**/Temp/**')
        })
        output                 = 'api'
        # Without a restore, external types (Microsoft.Extensions, Unity, the game DLLs) don't
        # resolve; the repo's own types still document fine and show external ones by name.
        allowCompilationErrors = $true
    })
}
$config.build = [ordered]@{
    content        = @([ordered]@{ files = @('**/*.md', '**/toc.yml', 'api/**.yml'); exclude = @('_site/**') })
    resource       = @([ordered]@{ files = @($AssetExt | ForEach-Object { "**/*$_" }); exclude = @('_site/**') })
    output         = '_site'
    template       = @('default', 'modern', (ToSlash $Template))
    globalMetadata = [ordered]@{
        _appName             = $Repo
        _appTitle            = $Repo
        _appFooter           = $footer
        _appLogoPath         = 'logo.svg'
        _appFaviconPath      = 'favicon.svg'
        _enableSearch        = $true
        _disableContribution = $true
    }
    sitemap        = [ordered]@{ baseUrl = "https://$Owner.github.io/$Repo/" }
}
[IO.File]::WriteAllText((Join-Path $Out 'docfx.json'), ($config | ConvertTo-Json -Depth 10))

Write-Host "[docs-site] staged $($pages.Count) page(s), $($script:copied.Count) asset(s) for $Repo -> $Out"

if ($Build -or $Serve) {
    $docfxArgs = @((Join-Path $Out 'docfx.json'))
    if ($Serve) { $docfxArgs += '--serve' }
    & $Docfx @docfxArgs
    if ($LASTEXITCODE) { throw "docfx exited with $LASTEXITCODE" }
    Write-Host "[docs-site] site: $(Join-Path $Out '_site')"
}
