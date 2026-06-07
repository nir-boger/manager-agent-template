#Requires -Version 5.1
<#
.SYNOPSIS
    pr-review-request -- seed the p50 (median) baseline from ~6 months of real PRs.

.DESCRIPTION
    Computes the comparison baseline used by the PR status updates that pr-review-request
    posts to the team's Teams channel. Instead of an arithmetic MEAN of a handful of live
    samples (which read as a noisy "~24 min"), this pulls every PR created by the roster
    (you + your directs) in the trailing window (default 180 days) and writes the p50 of:

      * TTFR (time-to-first-review)  -- PR creation -> first NON-AUTHOR thread comment.
                                        ADO exposes no vote timestamp historically, so the
                                        baseline is a "first human comment" approximation;
                                        approve-without-comment PRs contribute no sample.
                                        Eligible-vs-sampled counts are persisted so the gap
                                        is visible.
      * TTM  (time-to-merge)         -- PR creation -> closedDate, COMPLETED PRs only.

    The result is written to the persisted `baseline` block of state/review-stats.json
    (existing rolling samples / reviewers / processed keys are preserved). Get-PrBaseline
    in stats.ps1 prefers this seeded p50; the runner uses it for every comparison line.

.PARAMETER WindowDays
    Trailing window in days. Default 180 (~6 months).

.PARAMETER DryRun
    Compute and print the baseline but do NOT write review-stats.json.

.PARAMETER MaxPrs
    Safety cap on how many distinct PRs to inspect for threads. Default 2000.
#>
param(
    [int]    $WindowDays = 180,
    [switch] $DryRun,
    [int]    $MaxPrs = 2000
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# $PSScriptRoot is .copilot/skills; the skill folder is a child of it.
$skillDir   = Join-Path $PSScriptRoot 'pr-review-request'
$stateDir   = Join-Path $skillDir 'state'
$statsFile  = Join-Path $stateDir 'review-stats.json'

. (Join-Path $skillDir 'stats.ps1')
. (Join-Path $skillDir 'ado-helpers.ps1')

$cfg         = $AgentConfig
$adoOrg      = Get-AgentField -Path 'ado.org'     -Default 'your-ado-org' -Config $cfg
$adoProject  = Get-AgentField -Path 'ado.project' -Default 'One'     -Config $cfg
$reportsRoot = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $cfg) -Config $cfg
$directsJson = Join-Path $reportsRoot 'directs-scope\directs-context.json'

$stamp   = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$logPath = Join-Path $LogDir "pr-baseline-seed-$stamp.log"
function Write-Log { param([string]$Msg) $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg; Write-Host $line; Add-Content -Path $logPath -Value $line -Encoding UTF8 }

Write-Log "seed-baseline starting. window=$WindowDays day(s) dryRun=$($DryRun.IsPresent) org=$adoOrg project=$adoProject"

$sinceUtc = (Get-Date).ToUniversalTime().AddDays(-$WindowDays)
Write-Log "Window start (UTC): $($sinceUtc.ToString('o'))"

# --- Auth + roster (mirrors the runner) ---------------------------------------
$token   = Get-AdoAccessToken
$headers = @{ Authorization = "Bearer $token" }
$self    = Get-AdoSelf -Headers $headers

$roster = New-Object System.Collections.Generic.List[object]
$roster.Add([PSCustomObject]@{ name = $self.displayName; id = $self.id; kind = 'self' })
if (Test-Path $directsJson) {
    $directs = Get-Content -Path $directsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $directs.directs.PSObject.Properties) {
        $value = $entry.Value
        $smtp  = [string]$value.smtp
        $identity = Get-AdoIdentity -Headers $headers -Smtp $smtp -DisplayName ([string]$value.name)
        if (-not $identity) { Write-Log "WARN: could not resolve identity for $smtp"; continue }
        $roster.Add([PSCustomObject]@{ name = [string]$value.name; id = $identity.id; kind = 'direct' })
    }
} else {
    Write-Log "WARN: directs-context.json not found at $directsJson; roster is self-only."
}
Write-Log "Roster: $($roster.Count) member(s)."

# --- Collect distinct PRs in window -------------------------------------------
$prs = @{}
foreach ($member in $roster) {
    $found = Get-PrsByCreatorSince -Headers $headers -IdentityId $member.id -SinceUtc $sinceUtc
    foreach ($pr in $found) { if (-not $prs.ContainsKey("$($pr.id)")) { $prs["$($pr.id)"] = $pr } }
    Write-Log "  $($member.name): $(@($found).Count) PR(s) in window."
}
$allPrs = @($prs.Values | Sort-Object createdAt)
Write-Log "Distinct PRs in window: $($allPrs.Count)."
if ($allPrs.Count -gt $MaxPrs) {
    Write-Log "Safety cap: $($allPrs.Count) > MaxPrs=$MaxPrs; inspecting the $MaxPrs most recent."
    $allPrs = @($allPrs | Sort-Object createdAt -Descending | Select-Object -First $MaxPrs)
}

# --- Compute TTFR / TTM samples -----------------------------------------------
$ttfr = New-Object System.Collections.Generic.List[double]
$ttm  = New-Object System.Collections.Generic.List[double]
$ttfrEligible = 0   # PRs we could in principle have a first-comment for (any PR)
$ttmEligible  = 0   # completed PRs

$idx = 0
foreach ($pr in $allPrs) {
    $idx++
    if (($idx % 50) -eq 0) { Write-Log "  ...processed $idx/$($allPrs.Count) PRs" }

    # TTM: completed PRs only.
    if ($pr.status -eq 'completed' -and $pr.closedAt) {
        $ttmEligible++
        $m = ($pr.closedAt - $pr.createdAt).TotalMinutes
        if ($m -ge 0) { $ttm.Add([double]$m) }
    }

    # TTFR: first non-author comment across threads.
    $ttfrEligible++
    if (-not [string]::IsNullOrWhiteSpace($pr.repoId)) {
        $threads = Get-PrThreadsForPr -Headers $headers -RepoId $pr.repoId -Id $pr.id
        $firstUtc = Get-FirstReviewCommentUtc -Threads $threads -AuthorId $pr.authorId
        if ($firstUtc) {
            $m = ($firstUtc - $pr.createdAt).TotalMinutes
            if ($m -ge 0) { $ttfr.Add([double]$m) }
        }
    }
}

$ttfrP50 = Get-PrMedian -Values $ttfr.ToArray()
$ttmP50  = Get-PrMedian -Values $ttm.ToArray()

Write-Log ("TTFR: {0} sample(s) from {1} PR(s) -> p50 = {2:N1} min ({3})" -f $ttfr.Count, $ttfrEligible, $ttfrP50, (Format-PrDuration $ttfrP50))
Write-Log ("TTM : {0} sample(s) from {1} completed PR(s) -> p50 = {2:N1} min ({3})" -f $ttm.Count, $ttmEligible, $ttmP50, (Format-PrDuration $ttmP50))

if ($DryRun) {
    Write-Log "[dry-run] baseline NOT written. Done."
    return
}

# --- Persist baseline (preserve everything else) ------------------------------
$stats = Read-PrReviewStats -Path $statsFile
if ($ttfr.Count -gt 0) {
    Set-PrBaseline -Stats $stats -Metric 'ttfr' -Minutes $ttfrP50 -SampleCount $ttfr.Count -EligiblePrs $ttfrEligible -WindowDays $WindowDays
} else { Write-Log "WARN: no TTFR samples; leaving ttfr baseline unchanged." }
if ($ttm.Count -gt 0) {
    Set-PrBaseline -Stats $stats -Metric 'ttm' -Minutes $ttmP50 -SampleCount $ttm.Count -EligiblePrs $ttmEligible -WindowDays $WindowDays
} else { Write-Log "WARN: no TTM samples; leaving ttm baseline unchanged." }

Write-PrReviewStats -Path $statsFile -Stats $stats
Write-Log "Wrote baseline to $statsFile. Done."

