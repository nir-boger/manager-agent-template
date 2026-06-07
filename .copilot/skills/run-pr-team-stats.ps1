#Requires -Version 5.1
<#!
.SYNOPSIS
    Generate PR team statistics for the current directs + self.

.DESCRIPTION
    Pulls ADO PR data for the current team roster (directs from
    reports/directs-scope/directs-context.json + the authenticated user)
    and writes a markdown report under reports/pr-team-stats/.

.PARAMETER IncludeKustoDmTeamAll
    Restrict the report to PRs whose reviewer list includes
    'Your Team'.

.PARAMETER DaysBack
    Look-back window in days (default: 180).
#>
param(
    [switch] $IncludeKustoDmTeamAll,
    [int]    $DaysBack = 180
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$cfg          = $AgentConfig
$adoOrg       = Get-AgentField -Path 'ado.org'     -Default 'your-ado-org' -Config $cfg
$adoProject   = Get-AgentField -Path 'ado.project' -Default 'One'     -Config $cfg
$reportsRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $cfg) -Config $cfg
$directsJson  = Join-Path $reportsRoot 'directs-scope\directs-context.json'
$outDir       = Join-Path $reportsRoot 'pr-team-stats'

function Write-ReportLog {
    param([string]$Message)
    Write-Host "$(Get-Date -Format o) $Message"
}

function Get-AdoAccessToken {
    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $token) { throw 'Failed to acquire ADO token via az CLI. Run "az login" first.' }
    return $token
}

function Invoke-AdoRest {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $Url,
        [string] $Method = 'GET'
    )
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers
}

function Get-AdoSelf {
    param([Parameter(Mandatory)] [hashtable] $Headers)
    $url = "https://dev.azure.com/$adoOrg/_apis/connectionData"
    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    if (-not $resp.authenticatedUser) { throw 'connectionData did not return authenticatedUser.' }
    return [PSCustomObject]@{
        id            = [string]$resp.authenticatedUser.id
        displayName   = [string]$resp.authenticatedUser.providerDisplayName
        uniqueName    = [string]$resp.authenticatedUser.uniqueName
        provider      = [string]$resp.authenticatedUser.providerDisplayName
    }
}

function Get-AdoIdentity {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $Smtp,
        [Parameter(Mandatory)] [string] $DisplayName
    )
    $url = "https://vssps.dev.azure.com/$adoOrg/_apis/identities?searchFilter=MailAddress&filterValue=$([uri]::EscapeDataString($Smtp))&api-version=7.1"
    try {
        $resp = Invoke-AdoRest -Headers $Headers -Url $url
    } catch {
        $resp = $null
    }
    if ($resp -and $resp.value -and $resp.value.Count -gt 0) {
        $hit = $resp.value[0]
        return [PSCustomObject]@{
            id          = [string]$hit.id
            displayName = [string]$hit.providerDisplayName
            uniqueName  = [string]$hit.uniqueName
            mail        = [string]$hit.mailAddress
        }
    }

    $url2 = "https://vssps.dev.azure.com/$adoOrg/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($DisplayName))&api-version=7.1"
    try {
        $resp2 = Invoke-AdoRest -Headers $Headers -Url $url2
    } catch {
        return $null
    }
    if (-not $resp2.value -or $resp2.value.Count -eq 0) { return $null }

    $needle = $DisplayName.Trim().ToLowerInvariant()
    $candidates = @($resp2.value | Where-Object {
        ($_.providerDisplayName -and $_.providerDisplayName.Trim().ToLowerInvariant() -eq $needle) -or
        ($_.customDisplayName -and $_.customDisplayName.Trim().ToLowerInvariant() -eq $needle)
    })
    if ($candidates.Count -eq 0) { $candidates = @($resp2.value) }

    $picked = $null
    foreach ($c in $candidates) {
        $mail = if ($c.mailAddress) { [string]$c.mailAddress } else { '' }
        if ($mail -match '@microsoft\.com$') { $picked = $c; break }
    }
    if (-not $picked) { $picked = $candidates[0] }

    return [PSCustomObject]@{
        id          = [string]$picked.id
        displayName = [string]$picked.providerDisplayName
        uniqueName  = [string]$picked.uniqueName
        mail        = [string]$picked.mailAddress
    }
}

function Get-PrSearchUrl {
    param(
        [Parameter(Mandatory)] [string] $IdentityId,
        [Parameter(Mandatory)] [string] $Status
    )
    return "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/pullrequests?searchCriteria.creatorId=$IdentityId&searchCriteria.status=$Status&`$top=100&api-version=7.1"
}

function Get-PullRequestsByCreator {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $IdentityId,
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [int] $DaysBack
    )
    $url = Get-PrSearchUrl -IdentityId $IdentityId -Status $Status
    try {
        $resp = Invoke-AdoRest -Headers $Headers -Url $url
    } catch {
        Write-ReportLog "WARN: PR search failed for creator=${IdentityId} status=${Status}: $($_.Exception.Message)"
        return @()
    }

    if (-not $resp.value) { return @() }
    $cutoff = (Get-Date).AddDays(-1 * $DaysBack)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($pr in @($resp.value)) {
        try {
            $created = [DateTime]::Parse([string]$pr.creationDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        } catch { continue }
        if ($created -lt $cutoff) { continue }

        $items.Add([PSCustomObject]@{
            id              = [int]$pr.pullRequestId
            repoId          = [string]$pr.repository.id
            repoName        = [string]$pr.repository.name
            title           = [string]$pr.title
            status          = [string]$pr.status
            createdAt       = $created
            closedAt        = if ($pr.closedDate) { [DateTime]::Parse([string]$pr.closedDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } else { $null }
            completedAt     = if ($pr.closedDate) { [DateTime]::Parse([string]$pr.closedDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } else { $null }
            authorId        = [string]$pr.createdBy.id
            authorName      = [string]$pr.createdBy.displayName
            authorUnique    = [string]$pr.createdBy.uniqueName
            reviewers       = @($pr.reviewers)
            reviewerNames   = @($pr.reviewers | ForEach-Object { [string]$_.displayName })
            reviewerUniques = @($pr.reviewers | ForEach-Object { [string]$_.uniqueName })
        })
    }
    return $items.ToArray()
}

function Get-FirstReviewDelayMinutes {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [int] $PrId,
        [Parameter(Mandatory)] [DateTime] $CreatedAt,
        [Parameter(Mandatory)] [string] $AuthorUnique
    )

    $url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/repositories/$RepoId/pullRequests/$PrId/threads?api-version=7.1"
    try {
        $resp = Invoke-AdoRest -Headers $Headers -Url $url
    } catch {
        return $null
    }

    $botPattern = '(?i)\b(bot|policy|build service|collection build|guardian|component governance|automation|service account|codeflow|semmle|credscan|microsoft\.visualstudio\.services)\b'

    $earliest = $null
    foreach ($thread in @($resp.value)) {
        foreach ($comment in @($thread.comments)) {
            if ($comment.commentType -eq 'system') { continue }
            if ([string]::IsNullOrWhiteSpace($comment.publishedDate)) { continue }
            $author = if ($comment.author -and $comment.author.uniqueName) { [string]$comment.author.uniqueName } else { '' }
            $authorDisplay = if ($comment.author -and $comment.author.displayName) { [string]$comment.author.displayName } else { '' }
            # Skip the PR author's own comments.
            if ([string]::Equals($author, $AuthorUnique, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            # Human-only: skip groups/containers, known bot/service accounts, and non-user identities.
            if ($comment.author -and $comment.author.isContainer -eq $true) { continue }
            if ($authorDisplay -match $botPattern -or $author -match $botPattern) { continue }
            if ($author -notmatch '@' -and $author -notmatch '\\') { continue }
            try {
                $ts = [DateTime]::Parse([string]$comment.publishedDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            } catch { continue }
            if ($earliest -eq $null -or $ts -lt $earliest) { $earliest = $ts }
        }
    }

    if ($null -eq $earliest) { return $null }
    return [int](($earliest - $CreatedAt).TotalMinutes)
}

function Get-WeekKey {
    param([DateTime]$DateTime)
    $d = $DateTime.Date
    $day = [int]$d.DayOfWeek
    if ($day -eq 0) { $day = 7 }
    $monday = $d.AddDays(1 - $day)
    return $monday.ToString('yyyy-MM-dd')
}

function Get-NormalizedToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '')
}

function Test-IsTeamMemberReviewer {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Reviewer,
        [Parameter(Mandatory)] [object[]]$TeamMembers
    )

    $reviewerKeys = @(
        (Get-NormalizedToken ([string]$Reviewer.displayName)),
        (Get-NormalizedToken ([string]$Reviewer.uniqueName)),
        (Get-NormalizedToken ([string]$Reviewer.mailAddress))
    ) | Where-Object { $_ }

    foreach ($member in $TeamMembers) {
        $memberKeys = @(
            (Get-NormalizedToken ([string]$member.name)),
            (Get-NormalizedToken ([string]$member.displayName)),
            (Get-NormalizedToken ([string]$member.smtp)),
            (Get-NormalizedToken ([string]$member.mail)),
            (Get-NormalizedToken ([string]$member.uniqueName))
        ) | Where-Object { $_ }

        $aliasReviewer = Get-NormalizedToken (([string]$Reviewer.uniqueName -split '@')[0])
        if ([string]::IsNullOrWhiteSpace($aliasReviewer)) { $aliasReviewer = Get-NormalizedToken (([string]$Reviewer.mailAddress -split '@')[0]) }

        $aliasMember = Get-NormalizedToken (([string]$member.uniqueName -split '@')[0])
        if ([string]::IsNullOrWhiteSpace($aliasMember)) { $aliasMember = Get-NormalizedToken (([string]$member.mail -split '@')[0]) }
        if ([string]::IsNullOrWhiteSpace($aliasMember)) { $aliasMember = Get-NormalizedToken (([string]$member.smtp -split '@')[0]) }

        if (($reviewerKeys | Where-Object { $memberKeys -contains $_ }).Count -gt 0) { return $true }
        if ($aliasReviewer -and $aliasMember -and $aliasReviewer -eq $aliasMember) { return $true }
        if ((Get-NormalizedToken ([string]$Reviewer.displayName)) -and (Get-NormalizedToken ([string]$member.name)) -and (Get-NormalizedToken ([string]$Reviewer.displayName)) -eq (Get-NormalizedToken ([string]$member.name))) { return $true }
    }

    return $false
}

function Get-TeamReviewerNames {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Pr,
        [Parameter(Mandatory)] [object[]]$TeamMembers
    )

    $names = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($reviewer in @($Pr.reviewers)) {
        if (-not (Test-IsTeamMemberReviewer -Reviewer $reviewer -TeamMembers $TeamMembers)) { continue }
        $display = [string]$reviewer.displayName
        if ([string]::IsNullOrWhiteSpace($display)) { $display = [string]$reviewer.uniqueName }
        if ($seen.Add($display)) { $names.Add($display) }
    }

    return $names.ToArray()
}

function Test-HasTeamReviewGroup {
    param([PSCustomObject]$Pr)
    return @($Pr.reviewers | Where-Object {
        ([string]$_.displayName -eq 'Your Team') -or ([string]$_.uniqueName -like '*\\Your Team')
    }).Count -gt 0
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$token = Get-AdoAccessToken
$headers = @{ Authorization = "Bearer $token" }
$self = Get-AdoSelf -Headers $headers
$team = New-Object System.Collections.Generic.List[object]
$team.Add([PSCustomObject]@{ name = $self.displayName; displayName = $self.displayName; smtp = $self.uniqueName; mail = $self.uniqueName; uniqueName = $self.uniqueName; id = $self.id; kind = 'self' })

if (Test-Path $directsJson) {
    $directs = Get-Content -Path $directsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $directs.directs.PSObject.Properties) {
        $value = $entry.Value
        $smtp = [string]$value.smtp
        $identity = Get-AdoIdentity -Headers $headers -Smtp $smtp -DisplayName ([string]$value.name)
        if (-not $identity) { Write-ReportLog "WARN: could not resolve identity for $smtp"; continue }
        $team.Add([PSCustomObject]@{ name = [string]$value.name; displayName = [string]$identity.displayName; smtp = $smtp; mail = [string]$identity.mail; uniqueName = [string]$identity.uniqueName; id = $identity.id; kind = 'direct' })
    }
}

$allPrs = New-Object System.Collections.Generic.List[object]
foreach ($member in $team) {
    Write-ReportLog "Gathering PRs for $($member.name) ($($member.id))"
    foreach ($status in @('active','completed')) {
        $prs = Get-PullRequestsByCreator -Headers $headers -IdentityId $member.id -Status $status -DaysBack $DaysBack
        foreach ($pr in $prs) {
            if ($IncludeKustoDmTeamAll -and -not (Test-HasTeamReviewGroup -Pr $pr)) { continue }
            $firstReviewMinutes = Get-FirstReviewDelayMinutes -Headers $headers -RepoId $pr.repoId -PrId $pr.id -CreatedAt $pr.createdAt -AuthorUnique $pr.authorUnique
            $teamReviewerNames = @(Get-TeamReviewerNames -Pr $pr -TeamMembers $team)
            $teamReviewerUniques = @($pr.reviewers | Where-Object { Test-IsTeamMemberReviewer -Reviewer $_ -TeamMembers $team } | ForEach-Object { [string]$_.uniqueName })
            $allPrs.Add([PSCustomObject]@{
                authorName      = $pr.authorName
                authorUnique    = $pr.authorUnique
                repoName        = $pr.repoName
                prId            = $pr.id
                title           = $pr.title
                status          = $pr.status
                createdAt       = $pr.createdAt
                closedAt        = $pr.closedAt
                completedAt     = $pr.completedAt
                completionDays  = if ($pr.closedAt) { [math]::Round((($pr.closedAt - $pr.createdAt).TotalDays), 2) } else { $null }
                firstReviewMinutes = $firstReviewMinutes
                reviewerNames   = @($pr.reviewerNames)
                reviewerUniques = @($pr.reviewerUniques)
                reviewerCount   = @($pr.reviewerNames).Count
                teamReviewerNames = $teamReviewerNames
                teamReviewerUniques = $teamReviewerUniques
                teamReviewerCount = $teamReviewerNames.Count
                hasKustoDmTeamAll = (Test-HasTeamReviewGroup -Pr $pr)
            })
        }
    }
}

$allPrs = @($allPrs | Sort-Object createdAt)
$reportPath = Join-Path $outDir ("pr-team-stats-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".md")
$rawPath = Join-Path $outDir ("pr-team-stats-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".json")

$weekly = @($allPrs | Group-Object { Get-WeekKey -DateTime $_.createdAt } | ForEach-Object {
    [PSCustomObject]@{
        week = $_.Name
        count = $_.Count
    }
}) | Sort-Object week

$completionByWeek = @($allPrs | Where-Object { $_.completionDays -ne $null } | Group-Object { Get-WeekKey -DateTime $_.closedAt } | ForEach-Object {
    [PSCustomObject]@{
        week = $_.Name
        averageDays = [math]::Round((($_.Group | Measure-Object -Property completionDays -Average).Average), 2)
        count = $_.Count
    }
}) | Sort-Object week

$firstReviewByWeek = @($allPrs | Where-Object { $_.firstReviewMinutes -ne $null } | Group-Object { Get-WeekKey -DateTime $_.createdAt } | ForEach-Object {
    [PSCustomObject]@{
        week = $_.Name
        averageHours = [math]::Round(((($_.Group | Measure-Object -Property firstReviewMinutes -Average).Average) / 60.0), 1)
        count = $_.Count
    }
}) | Sort-Object week

$distinctTeamReviewersByWeek = @($allPrs | Group-Object { "{0}|{1}" -f (Get-WeekKey -DateTime $_.createdAt), ($_.teamReviewerNames -join "`u{1F}") } | ForEach-Object {
    $parts = $_.Name -split '\|', 2
    $reviewers = @($parts[1] -split "`u{1F}")
    [PSCustomObject]@{
        week = $parts[0]
        reviewers = $reviewers
    }
})

$distinctTeamReviewersSummary = New-Object System.Collections.Generic.List[object]
foreach ($weekGroup in @($distinctTeamReviewersByWeek | Group-Object week)) {
    $unique = @($weekGroup.Group.reviewers | Where-Object { $_ } | Sort-Object -Unique)
    $distinctTeamReviewersSummary.Add([PSCustomObject]@{
        week = $weekGroup.Name
        distinctReviewerCount = $unique.Count
        reviewers = $unique
    })
}
$distinctTeamReviewersSummary = @($distinctTeamReviewersSummary | Sort-Object week)

$report = @()
$report += '# PR team stats report'
$report += ''
$report += "Generated: $(Get-Date -Format o)"
$report += "Team members included: $($team.Count)"
if ($IncludeKustoDmTeamAll) { $report += 'Filter: PRs whose reviewer list includes Your Team' } else { $report += 'Filter: all PRs for the team roster' }
$report += ''
$report += '## Hours waiting for first human review per week'
$report += ''
$report += '| Week | PR count | Avg hours to first human review |'
$report += '|---|---:|---:|'
foreach ($row in $firstReviewByWeek) { $report += "| $($row.week) | $($row.count) | $($row.averageHours) |" }
$report += ''
$report += '## Notes'
$report += ''
$report += '- First human review is the earliest non-system PR thread comment from a real team-external-or-internal person (bots, policy/build service accounts, and groups are excluded), measured from PR creation.'
$report += ''

$report | Set-Content -Path $reportPath -Encoding UTF8
$allPrs | ConvertTo-Json -Depth 8 | Set-Content -Path $rawPath -Encoding UTF8

$weeklyJson = $weekly | ConvertTo-Json -Depth 6 -Compress
$completionByWeekJson = $completionByWeek | ConvertTo-Json -Depth 6 -Compress
$firstReviewByWeekJson = $firstReviewByWeek | ConvertTo-Json -Depth 6 -Compress
$distinctTeamReviewersSummaryJson = $distinctTeamReviewersSummary | ConvertTo-Json -Depth 6 -Compress
$htmlPath = Join-Path $outDir ("pr-team-stats-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".html")
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PR Team Stats</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3"></script>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #111827; background: #fff; }
    h1, h2 { color: #111827; }
    .subtle { color: #4b5563; font-size: 13px; }
    .card { border: 1px solid #e5e7eb; border-radius: 12px; padding: 16px; margin: 18px 0; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,0.04); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
    canvas { max-height: 320px; }
    table { border-collapse: collapse; width: 100%; margin-top: 10px; font-size: 13px; }
    th, td { border: 1px solid #e5e7eb; padding: 8px 10px; text-align: left; }
    th { background: #f9fafb; }
  </style>
</head>
<body>
  <h1>PR Team Stats</h1>
  <p class="subtle">Generated: $(Get-Date -Format o)</p>
  <p class="subtle">Team members included: $($team.Count)</p>
  <p class="subtle">Filter: $(if ($IncludeKustoDmTeamAll) { 'PRs whose reviewer list includes Your Team' } else { 'all PRs for the team roster' })</p>
  <p class="subtle">Hours measured from PR creation to the first review comment by a real person (bots, policy/build service accounts, and groups excluded).</p>

  <div class="card">
    <h2>Hours waiting for first human review (per week)</h2>
    <canvas id="reviewDelayChart"></canvas>
  </div>

  <script>
    const firstReviewByWeek = $firstReviewByWeekJson;

    const palette = ['#2563eb','#16a34a','#f59e0b','#ef4444','#8b5cf6','#06b6d4','#84cc16','#e11d48','#0ea5e9','#f97316'];

    new Chart(document.getElementById('reviewDelayChart'), {
      type: 'line',
      data: {
        labels: firstReviewByWeek.map(x => x.week),
        datasets: [{ label: 'Avg hours to first human review', data: firstReviewByWeek.map(x => x.averageHours), borderColor: palette[3], backgroundColor: 'rgba(239,68,68,0.15)', fill: true, tension: 0.25 }]
      },
      options: { responsive: true, scales: { y: { beginAtZero: true, title: { display: true, text: 'Hours' } } } }
    });
  </script>
</body>
</html>
"@

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-ReportLog "Wrote $reportPath"
Write-ReportLog "Wrote $rawPath"
Write-ReportLog "Wrote $htmlPath"

