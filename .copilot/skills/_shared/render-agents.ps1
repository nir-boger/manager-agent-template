<#
.SYNOPSIS
  Regenerates AGENTS.md from templates/AGENTS.md.tmpl + config + skills.json.

.DESCRIPTION
  Sources of truth:
    - config/agent.json     (agent identity, manager, paths, etc.)
    - config/skills.json    (skills index, triggers, surface tier)
    - config/banner.txt     (ASCII banner, optional)
    - templates/AGENTS.md.tmpl
  Output:
    - AGENTS.md (committed; doctor.ps1 verifies it's in sync with a fresh render)

  Triple-brace placeholders ({{{ banner }}}, {{{ skills_table }}}) are
  substituted BEFORE the Mustache-lite pass so the inner {{ banner }} regex
  doesn't accidentally fire. The skills table is rendered in PS code (not via
  a generic {{#each}}) so the Mustache-lite engine stays small. Only skills
  with show_in_agents=true are included.

.PARAMETER Output
  Override the output path. Defaults to <agent-root>/AGENTS.md.

.PARAMETER Check
  Don't write; instead, fail if the existing AGENTS.md doesn't match a fresh
  render. Used by doctor.ps1.
#>
[CmdletBinding()]
param(
    [string] $Output,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'render-template.ps1')

$AgentRoot   = Resolve-AgentRoot
$AgentConfig = Get-AgentConfig

$templatePath = Join-Path $AgentRoot 'templates\AGENTS.md.tmpl'
if (-not (Test-Path $templatePath)) { throw "Template not found: $templatePath" }
$template = Get-Content -Raw -Encoding UTF8 $templatePath

$skillsPath = Join-Path $AgentRoot 'config\skills.json'
if (-not (Test-Path $skillsPath)) { throw "Manifest not found: $skillsPath" }
$skillsManifest = Get-Content -Raw -Encoding UTF8 $skillsPath | ConvertFrom-Json

# --- Render the skills table (PS code, not generic {{#each}}) -------------
# Skills are grouped by 'category' field. Order + display labels live in
# $categoryOrder below — single source of truth. Skills with show_in_agents=
# false are skipped. Skills without a category fall into 'misc' (rendered last).
$categoryOrder = [ordered]@{
    'sprint-pbis'        = 'Sprint & PBIs'
    'comms'              = 'Comms'
    'codebase-people'    = 'Codebase & people'
    'reviews-dri'        = 'Reviews & DRI'
    'cadence-memory'     = 'Cadence & memory'
    'private-work-tools' = 'Private work tools'
    'personal-life'      = 'Personal life'
    'misc'               = 'Misc'
}

$grouped = @{}
foreach ($s in $skillsManifest.skills) {
    if (-not $s.show_in_agents) { continue }
    $cat = if ($s.category) { $s.category } else { 'misc' }
    if (-not $grouped.ContainsKey($cat)) { $grouped[$cat] = New-Object System.Collections.Generic.List[object] }
    $grouped[$cat].Add($s)
}

$rows = New-Object System.Collections.Generic.List[string]
$first = $true
foreach ($cat in $categoryOrder.Keys) {
    if (-not $grouped.ContainsKey($cat)) { continue }
    if (-not $first) { $rows.Add('') }
    $first = $false
    $rows.Add("### $($categoryOrder[$cat])")
    $rows.Add('')
    $rows.Add('| Skill | Path | Trigger phrases (case-insensitive, partial match OK) |')
    $rows.Add('|---|---|---|')
    foreach ($s in $grouped[$cat]) {
        $name = $s.name
        $path = $s.path
        $triggers = ($s.triggers | ForEach-Object { '"' + $_ + '"' }) -join ', '
        $extra = ''
        if ($s.summary) { $extra = ' &mdash; ' + $s.summary }
        $rows.Add("| ``$name`` | ``$path/SKILL.md`` | $triggers$extra |")
    }
}
# Catch any unknown category not in $categoryOrder.
foreach ($cat in $grouped.Keys) {
    if ($categoryOrder.Contains($cat)) { continue }
    if (-not $first) { $rows.Add('') }
    $first = $false
    $rows.Add("### $cat")
    $rows.Add('')
    $rows.Add('| Skill | Path | Trigger phrases (case-insensitive, partial match OK) |')
    $rows.Add('|---|---|---|')
    foreach ($s in $grouped[$cat]) {
        $name = $s.name
        $path = $s.path
        $triggers = ($s.triggers | ForEach-Object { '"' + $_ + '"' }) -join ', '
        $extra = ''
        if ($s.summary) { $extra = ' &mdash; ' + $s.summary }
        $rows.Add("| ``$name`` | ``$path/SKILL.md`` | $triggers$extra |")
    }
}
$skillsTable = ($rows -join "`n")

# --- Render the banner ----------------------------------------------------
$bannerPath = Join-Path $AgentRoot (Get-AgentField -Path 'agent.banner_path' -Default 'config/banner.txt' -Config $AgentConfig)
$banner = ''
if (Test-Path $bannerPath) {
    $bannerLines = Get-Content $bannerPath -Encoding UTF8
    $indented = $bannerLines | ForEach-Object { '    ' + $_ }
    $banner = ($indented -join "`n")
}

# --- Build context (PSCustomObject -> hashtable) --------------------------
function ConvertTo-RenderHashtable {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject] -or
        ($Obj -is [psobject] -and $Obj.PSObject -and $Obj.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject')) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-RenderHashtable $p.Value
        }
        return $h
    }
    return $Obj
}
$ctx = ConvertTo-RenderHashtable $AgentConfig

# --- Render: triple-brace block placeholders FIRST, then Mustache-lite ---
$rendered = $template
$rendered = $rendered.Replace('{{{ banner }}}',       $banner)
$rendered = $rendered.Replace('{{{ skills_table }}}', $skillsTable)
$rendered = Render-Template -Template $rendered -Context $ctx

if (-not $Output) { $Output = Join-Path $AgentRoot 'AGENTS.md' }

if ($Check) {
    if (-not (Test-Path $Output)) {
        Write-Error "AGENTS.md not found at $Output (regenerate via _shared/render-agents.ps1)."
        exit 1
    }
    $existing = Get-Content -Raw -Encoding UTF8 $Output
    $a = ($existing -replace "`r`n", "`n").TrimEnd("`n")
    $b = ($rendered -replace "`r`n", "`n").TrimEnd("`n")
    if ($a -ne $b) {
        Write-Error "AGENTS.md is out of sync with template + config. Re-run _shared/render-agents.ps1."
        exit 1
    }
    Write-Host "OK - AGENTS.md matches a fresh render."
    return
}

[System.IO.File]::WriteAllText($Output, $rendered, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $Output ($($rendered.Length) chars)"
