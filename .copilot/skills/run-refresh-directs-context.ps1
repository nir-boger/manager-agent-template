#Requires -Version 5.1
<#
.SYNOPSIS
    Refresh ADO context (recent PRs + active work items) and persona
    highlights for each direct report. Writes a single JSON file the
    Board reads at snapshot time.

.DESCRIPTION
    For each direct resolved via nirvana-board/directs.py:
      1. Identify the direct's ADO descriptor (by SMTP via connectionData
         identity lookup or by display-name match against pull-request
         data).
      2. Pull PRs where the direct is the creator OR a reviewer, both
         status=active and status=completed within $RecentDays (default
         14).
      3. Run a WIQL query for work items assigned to the direct's SMTP
         that are NOT in (Closed, Done, Resolved, Removed).
      4. Parse the direct's persona markdown and extract bullets from
         the "Recent Topics & Projects" and "Strengths & Interests"
         sections as `persona_highlights`.

    The output JSON is keyed by direct slug:
      {
        "generated_at": "<iso>",
        "directs": {
          "maya-Teammate4": {
            "smtp": "someone@example.com",
            "name": "Teammate4",
            "recent_prs": [{"id":..,"title":..,"url":..,"status":..,"role":"author|reviewer","repo":..,"author":..,"created":..}],
            "active_work_items": [{"id":..,"title":..,"url":..,"state":..,"type":..}],
            "persona_highlights": ["...", "..."]
          },
          ...
        }
      }

.PARAMETER RecentDays
    PR look-back window in days. Default 14.

.PARAMETER OnlySlug
    If provided, refresh ONLY this direct (testing / focused refresh).

.PARAMETER DryRun
    Resolve directs and persona highlights only; skip ADO calls (useful
    when az is not logged in).
#>

param(
    [int]    $RecentDays = 14,
    [string] $OnlySlug   = '',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$cfg          = $AgentConfig
$adoOrg       = Get-AgentField -Path 'ado.org'     -Default 'your-ado-org' -Config $cfg
$adoProject   = Get-AgentField -Path 'ado.project' -Default 'One'     -Config $cfg
$reportsRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $cfg) -Config $cfg
$personasDir  = Resolve-AgentPath '.copilot/skills/team-personas/people' -Config $cfg
$scopeBoardMd = Join-Path $reportsRoot 'directs-scope\scope-board.md'
$outFile      = Join-Path $reportsRoot 'directs-scope\directs-context.json'
$boardDir     = Join-Path $AgentRoot '.copilot\skills\nirvana-board'

$orgBase = "https://dev.azure.com/$adoOrg"

function Write-RefreshLog {
    param([string] $Message)
    Write-Host "$((Get-Date).ToString('o'))  $Message"
}

# --- ADO helpers --------------------------------------------------------

function Get-AdoAccessToken {
    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $token) {
        throw "Failed to acquire ADO token via az CLI. Run 'az login' first."
    }
    return $token
}

function Invoke-AdoRest {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $Url,
        [string] $Method = 'GET',
        [object] $Body   = $null
    )
    if ($Body) {
        $json = ($Body | ConvertTo-Json -Depth 8 -Compress)
        return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -Body $json -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers
}

function Get-AdoIdentitySearch {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [ValidateSet('MailAddress','General')] [string] $Filter,
        [Parameter(Mandatory)] [string] $Value
    )
    $url = "https://vssps.dev.azure.com/$adoOrg/_apis/identities?searchFilter=$Filter&filterValue=$([uri]::EscapeDataString($Value))&api-version=7.1"
    try {
        return (Invoke-AdoRest -Headers $Headers -Url $url)
    } catch {
        return $null
    }
}

function Resolve-AdoIdentity {
    <#
    .SYNOPSIS
        Resolve a direct's ADO identity ID + canonical mail.
    .DESCRIPTION
        Persona files carry the friendly first.last form of the SMTP
        (e.g. someone@example.com) which Outlook routes happily
        but which ADO's MailAddress index does NOT carry - ADO uses the
        short mail-nickname form (e.g. someone@example.com). So we
        search by MailAddress first; on miss, fall back to General
        (display-name) search and pick the entry whose providerDisplayName
        matches the direct's name. We return BOTH the identity id (for
        PR queries) AND the canonical mail (for WIQL [System.AssignedTo]
        comparisons, which compare against the unique_name).
    .OUTPUTS
        Hashtable @{ Id = '<guid>'; Mail = '<canonical-smtp>' } or $null on miss.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $Smtp,
        [Parameter(Mandatory)] [string]    $DisplayName
    )

    $resp = Get-AdoIdentitySearch -Headers $Headers -Filter 'MailAddress' -Value $Smtp
    if ($resp -and $resp.value -and $resp.value.Count -gt 0) {
        $hit = $resp.value[0]
        $mail = if ($hit.properties -and $hit.properties.Mail -and $hit.properties.Mail.'$value') { [string]$hit.properties.Mail.'$value' } else { $Smtp }
        return @{ Id = [string]$hit.id; Mail = $mail }
    }

    # Fallback: search by display name. Pick the best match against the
    # direct's name we already know, prefer entries with a @microsoft.com mail.
    $resp2 = Get-AdoIdentitySearch -Headers $Headers -Filter 'General' -Value $DisplayName
    if (-not $resp2 -or -not $resp2.value -or $resp2.value.Count -eq 0) { return $null }
    $needle = $DisplayName.Trim().ToLowerInvariant()
    $candidates = @($resp2.value | Where-Object {
        ($_.providerDisplayName -and ($_.providerDisplayName.Trim().ToLowerInvariant() -eq $needle)) -or
        ($_.customDisplayName  -and ($_.customDisplayName.Trim().ToLowerInvariant()  -eq $needle))
    })
    if ($candidates.Count -eq 0) { $candidates = @($resp2.value) }
    $picked = $null
    foreach ($c in $candidates) {
        $cmail = if ($c.properties -and $c.properties.Mail -and $c.properties.Mail.'$value') { [string]$c.properties.Mail.'$value' } else { '' }
        if ($cmail -match '@microsoft\.com$') { $picked = $c; break }
    }
    if (-not $picked) { $picked = $candidates[0] }
    $pickedMail = if ($picked.properties -and $picked.properties.Mail -and $picked.properties.Mail.'$value') { [string]$picked.properties.Mail.'$value' } else { $Smtp }
    return @{ Id = [string]$picked.id; Mail = $pickedMail }
}

function Get-RecentPrs {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $IdentityId,
        [Parameter(Mandatory)] [int]       $DaysBack
    )
    $results = New-Object System.Collections.Generic.List[object]
    $cutoff = (Get-Date).AddDays(-1 * $DaysBack)
    foreach ($role in @('creatorId', 'reviewerId')) {
        foreach ($status in @('active', 'completed')) {
            $url = "$orgBase/$adoProject/_apis/git/pullrequests?searchCriteria.$role=$IdentityId&searchCriteria.status=$status&`$top=50&api-version=7.1"
            try {
                $resp = Invoke-AdoRest -Headers $Headers -Url $url
            } catch {
                Write-RefreshLog "WARN: PR query failed (role=$role status=$status id=$IdentityId): $($_.Exception.Message)"
                continue
            }
            if (-not $resp.value) { continue }
            foreach ($pr in $resp.value) {
                try {
                    $created = [datetime]::Parse([string]$pr.creationDate, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                } catch { continue }
                if ($created -lt $cutoff) { continue }
                $repoName = if ($pr.repository -and $pr.repository.name) { [string]$pr.repository.name } else { '' }
                $prUrl = "$orgBase/$adoProject/_git/$repoName/pullrequest/$($pr.pullRequestId)"
                $roleLabel = if ($role -eq 'creatorId') { 'author' } else { 'reviewer' }
                $authorName = if ($pr.createdBy -and $pr.createdBy.displayName) { [string]$pr.createdBy.displayName } else { '' }
                $results.Add([PSCustomObject]@{
                    id      = [int]$pr.pullRequestId
                    title   = [string]$pr.title
                    url     = $prUrl
                    status  = [string]$pr.status
                    role    = $roleLabel
                    repo    = $repoName
                    author  = $authorName
                    created = $created.ToString('o')
                })
            }
        }
    }
    # Dedupe by (id, role) and sort newest-first.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($r in ($results | Sort-Object { $_.created } -Descending)) {
        $k = "$($r.id)|$($r.role)"
        if ($seen.Add($k)) { $unique.Add($r) }
    }
    return $unique.ToArray()
}

function Get-ActiveWorkItems {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $Smtp
    )
    $wiql = @{
        query = "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType] FROM WorkItems WHERE [System.AssignedTo] = '$Smtp' AND [System.State] NOT IN ('Closed','Done','Resolved','Removed','Cut') ORDER BY [System.ChangedDate] DESC"
    }
    $url = "$orgBase/$adoProject/_apis/wit/wiql?`$top=50&api-version=7.1"
    try {
        $resp = Invoke-AdoRest -Headers $Headers -Url $url -Method POST -Body $wiql
    } catch {
        Write-RefreshLog "WARN: WIQL query failed for smtp=$Smtp : $($_.Exception.Message)"
        return @()
    }
    if (-not $resp.workItems -or $resp.workItems.Count -eq 0) { return @() }
    $ids = $resp.workItems | ForEach-Object { [int]$_.id } | Select-Object -First 50
    if ($ids.Count -eq 0) { return @() }
    $idsCsv = ($ids -join ',')
    $batchUrl = "$orgBase/$adoProject/_apis/wit/workitems?ids=$idsCsv&fields=System.Id,System.Title,System.State,System.WorkItemType&api-version=7.1"
    try {
        $batch = Invoke-AdoRest -Headers $Headers -Url $batchUrl
    } catch {
        Write-RefreshLog "WARN: workitem batch failed: $($_.Exception.Message)"
        return @()
    }
    if (-not $batch.value) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($wi in $batch.value) {
        $fields = $wi.fields
        $wiId   = [int]$wi.id
        $out.Add([PSCustomObject]@{
            id    = $wiId
            title = [string]$fields.'System.Title'
            url   = "$orgBase/$adoProject/_workitems/edit/$wiId"
            state = [string]$fields.'System.State'
            type  = [string]$fields.'System.WorkItemType'
        })
    }
    return $out.ToArray()
}

function Get-PersonaHighlights {
    param(
        [Parameter(Mandatory)] [string] $Slug
    )
    $path = Join-Path $personasDir "$Slug.md"
    if (-not (Test-Path $path)) { return @() }
    $text = Get-Content -Path $path -Raw -Encoding UTF8
    # Extract bullet content from "Recent Topics & Projects" and
    # "Strengths & Interests" sections. We strip the leading "- "
    # marker and any leading bold lead-in (e.g. "**Title.**") for the
    # short rendered preview.
    $sections = @('Recent Topics & Projects','Strengths & Interests','Recent signals','Recent highlights')
    $highlights = New-Object System.Collections.Generic.List[string]
    foreach ($sec in $sections) {
        $pattern = "(?ms)^##\s+" + [regex]::Escape($sec) + "\s*\r?\n(.+?)(?=^##\s|\z)"
        $m = [regex]::Match($text, $pattern)
        if (-not $m.Success) { continue }
        $body = $m.Groups[1].Value
        foreach ($ln in ($body -split "`n")) {
            $t = $ln.Trim()
            if (-not $t.StartsWith('-')) { continue }
            $bullet = $t.Substring(1).Trim()
            if ($bullet -match '^\*\*(.+?)\*\*\s*[\.:]\s*(.+)$') {
                $title = $matches[1].Trim()
                $rest = $matches[2].Trim()
                $bullet = "$title - $rest"
            }
            # Drop parenthetical citation noise (msg_NN, evt_NN, chat ID NN).
            $bullet = [regex]::Replace($bullet, '\s*\([^)]*(msg_|evt_|chat ID|2026-\d{2}-\d{2})[^)]*\)', '')
            $bullet = $bullet.Trim()
            if ($bullet.Length -lt 8) { continue }
            if ($bullet.Length -gt 220) { $bullet = $bullet.Substring(0, 217) + '...' }
            $highlights.Add($bullet)
            if ($highlights.Count -ge 6) { break }
        }
        if ($highlights.Count -ge 6) { break }
    }
    return $highlights.ToArray()
}

function Get-RecentWins {
    param(
        [Parameter(Mandatory)] [string] $Slug,
        [Parameter(Mandatory)] [int]    $DaysBack
    )
    $path = Join-Path $reportsRoot "one-on-ones\$Slug.md"
    if (-not (Test-Path $path)) { return @() }
    $py = @"
# -*- coding: utf-8 -*-
import sys, json
from pathlib import Path
sys.path.insert(0, r'$boardDir')
import markdown_io as mio
text = Path(r'$path').read_text(encoding='utf-8')
items = mio.parse_one_on_one(text)
wins = []
for it in items:
    if it.get('status') != 'closed': continue
    closed = it.get('closed_on') or ''
    summary = it.get('summary') or it.get('title') or ''
    wins.append({'id': it['id'], 'title': it['title'], 'closed_on': closed, 'summary': summary, 'why': it.get('why_matters','')})
sys.stdout.write(json.dumps(wins, ensure_ascii=False))
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("refresh-wins-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
    [System.IO.File]::WriteAllText($tmp, $py, [System.Text.UTF8Encoding]::new($false))
    try {
        $raw = & python $tmp 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-RefreshLog "WARN: wins parse failed for slug=$Slug exit=${LASTEXITCODE}: $raw"
            return @()
        }
        $all = @($raw | ConvertFrom-Json)
        $cutoff = (Get-Date).AddDays(-1 * $DaysBack).Date
        $filtered = @()
        foreach ($w in $all) {
            $closedStr = [string]$w.closed_on
            [datetime] $d = [datetime]::MinValue
            if ([DateTime]::TryParse($closedStr, [ref] $d)) {
                if ($d.Date -ge $cutoff) { $filtered += $w }
            }
        }
        # Sort newest first, cap 6.
        $sorted = @($filtered | Sort-Object { [DateTime]$_.closed_on } -Descending | Select-Object -First 6)
        return $sorted
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

function Get-PersonalNotes {
    param(
        [Parameter(Mandatory)] [string] $Slug
    )
    $path = Join-Path $reportsRoot "one-on-ones\$Slug.md"
    if (-not (Test-Path $path)) { return '' }
    $py = @"
# -*- coding: utf-8 -*-
import sys
from pathlib import Path
sys.path.insert(0, r'$boardDir')
import markdown_io as mio
text = Path(r'$path').read_text(encoding='utf-8')
sys.stdout.write(mio.parse_personal_notes(text))
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("refresh-notes-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
    [System.IO.File]::WriteAllText($tmp, $py, [System.Text.UTF8Encoding]::new($false))
    try {
        $raw = & python $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        if ($null -eq $raw) { return '' }
        $joined = ($raw | ForEach-Object { [string]$_ }) -join "`n"
        return $joined.Trim()
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

function Get-UpcomingMilestones {
    param(
        [Parameter(Mandatory)] [string] $Slug,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [int]    $LookaheadDays
    )
    $path = Join-Path $personasDir "$Slug.md"
    if (-not (Test-Path $path)) { return @() }
    $text = Get-Content -Path $path -Raw -Encoding UTF8
    # Birthday: MM/DD (recurring annual). Some entries may use YYYY-MM-DD.
    $bdayLine = [regex]::Match($text, '(?im)^-\s*\*\*Birthday:\*\*\s*(.+?)\s*$')
    $hiredLine = [regex]::Match($text, '(?im)^-\s*\*\*Hired:\*\*\s*(\d{4}-\d{2}-\d{2})\s*$')
    $today = (Get-Date).Date
    $horizon = $today.AddDays($LookaheadDays)
    $out = New-Object System.Collections.Generic.List[object]
    if ($bdayLine.Success) {
        $raw = $bdayLine.Groups[1].Value.Trim()
        $bday = $null
        # Try MM/DD or M/D
        if ($raw -match '^(\d{1,2})\/(\d{1,2})$') {
            $mo = [int]$matches[1]; $da = [int]$matches[2]
            try { $bday = (Get-Date -Year $today.Year -Month $mo -Day $da).Date } catch {}
        } elseif ($raw -match '^\d{4}-(\d{2})-(\d{2})$') {
            $mo = [int]$matches[1]; $da = [int]$matches[2]
            try { $bday = (Get-Date -Year $today.Year -Month $mo -Day $da).Date } catch {}
        }
        if ($bday) {
            if ($bday -lt $today) { $bday = $bday.AddYears(1) }
            if ($bday -le $horizon) {
                $days = ($bday - $today).Days
                $out.Add([PSCustomObject]@{
                    type = 'birthday'
                    name = $Name
                    date = $bday.ToString('yyyy-MM-dd')
                    days_until = $days
                    label = "$Name's birthday ($($bday.ToString('MMM d')))"
                })
            }
        }
    }
    if ($hiredLine.Success) {
        $hiredStr = $hiredLine.Groups[1].Value
        [datetime] $hired = [datetime]::MinValue
        if ([DateTime]::TryParse($hiredStr, [ref] $hired)) {
            $hired = $hired.Date
            # Next anniversary >= today.
            $thisYear = (Get-Date -Year $today.Year -Month $hired.Month -Day $hired.Day).Date
            if ($thisYear -lt $today) { $thisYear = $thisYear.AddYears(1) }
            if ($thisYear -le $horizon) {
                $years = $thisYear.Year - $hired.Year
                $days  = ($thisYear - $today).Days
                $out.Add([PSCustomObject]@{
                    type = 'work_anniversary'
                    name = $Name
                    date = $thisYear.ToString('yyyy-MM-dd')
                    days_until = $days
                    years = $years
                    label = "$Name's $years-year work anniversary ($($thisYear.ToString('MMM d')))"
                })
            }
        }
    }
    return @($out | Sort-Object { $_.days_until })
}

# --- Resolve directs (reuse the Python resolver) ------------------------

function Resolve-Directs {
    $pyTmp = Join-Path ([IO.Path]::GetTempPath()) ("refresh-directs-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
    $py = @"
import sys, json
from pathlib import Path
sys.path.insert(0, r'$boardDir')
from directs import resolve_directs
res = resolve_directs(Path(r'$scopeBoardMd'), Path(r'$personasDir'))
sys.stdout.write(json.dumps(res, ensure_ascii=False))
"@
    [System.IO.File]::WriteAllText($pyTmp, $py, [System.Text.UTF8Encoding]::new($false))
    try {
        $raw = & python $pyTmp 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "directs resolver failed: $raw" }
        return ($raw | ConvertFrom-Json)
    } finally {
        Remove-Item -Path $pyTmp -ErrorAction SilentlyContinue
    }
}

# --- Main ---------------------------------------------------------------

$directs = @(Resolve-Directs)
if ($directs.Count -eq 0) {
    Write-RefreshLog "ERROR: 0 directs resolved. Aborting."
    exit 1
}
Write-RefreshLog "refresh-directs-context: $($directs.Count) direct(s) resolved."

$headers = $null
if (-not $DryRun) {
    try {
        $token = Get-AdoAccessToken
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    } catch {
        Write-RefreshLog "WARN: ADO token unavailable - skipping ADO calls. ($($_.Exception.Message))"
        $headers = $null
    }
}

$result = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    directs      = [ordered]@{}
}

# Preserve any existing data for directs we don't refresh in this run.
if ((Test-Path $outFile) -and $OnlySlug) {
    try {
        $existing = Get-Content -Path $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($existing.directs) {
            foreach ($prop in $existing.directs.PSObject.Properties) {
                $result.directs[$prop.Name] = $prop.Value
            }
        }
    } catch {
        Write-RefreshLog "WARN: could not parse existing $outFile - starting fresh."
    }
}

foreach ($d in $directs) {
    if ($OnlySlug -and ($d.slug -ne $OnlySlug)) { continue }
    Write-RefreshLog "refreshing slug=$($d.slug) smtp=$($d.smtp)"
    $highlights    = @(Get-PersonaHighlights -Slug $d.slug)
    $wins          = @(Get-RecentWins -Slug $d.slug -DaysBack $RecentDays)
    $personalNotes = (Get-PersonalNotes -Slug $d.slug)
    $milestones    = @(Get-UpcomingMilestones -Slug $d.slug -Name $d.name -LookaheadDays 14)
    $prs = @()
    $wis = @()
    if ($headers -and $d.smtp) {
        $identity = Resolve-AdoIdentity -Headers $headers -Smtp $d.smtp -DisplayName $d.name
        if ($identity) {
            $prs = @(Get-RecentPrs -Headers $headers -IdentityId $identity.Id -DaysBack $RecentDays)
            $wiqlMail = if ($identity.Mail) { $identity.Mail } else { $d.smtp }
            $wis = @(Get-ActiveWorkItems -Headers $headers -Smtp $wiqlMail)
            if ($wiqlMail -ne $d.smtp) {
                Write-RefreshLog "  resolved ADO canonical mail: persona=$($d.smtp) -> ado=$wiqlMail (display-name fallback)"
            }
        } else {
            Write-RefreshLog "  no ADO identity for smtp=$($d.smtp) / display='$($d.name)' - skipping PR query"
            # Best-effort WIQL with the persona SMTP - may still hit if ADO indexed both forms.
            $wis = @(Get-ActiveWorkItems -Headers $headers -Smtp $d.smtp)
        }
    }
    $result.directs[$d.slug] = [ordered]@{
        smtp                = $d.smtp
        name                = $d.name
        recent_prs          = $prs
        active_work_items   = $wis
        persona_highlights  = $highlights
        recent_wins         = $wins
        personal_notes      = $personalNotes
        upcoming_milestones = $milestones
    }
    Write-RefreshLog "  prs=$($prs.Count) wis=$($wis.Count) highlights=$($highlights.Count) wins=$($wins.Count) notes_len=$($personalNotes.Length) milestones=$($milestones.Count)"
}

$outDir = Split-Path -Parent $outFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$json = ($result | ConvertTo-Json -Depth 8)
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))
Write-RefreshLog "wrote $outFile ($(($json).Length) bytes)"

