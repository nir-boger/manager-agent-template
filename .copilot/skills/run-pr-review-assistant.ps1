# PR review assistant runner.
#
# Scans ADO project=One for PRs where Nir is a reviewer (status=Active, non-draft,
# not authored by Nir). Diffs against state/seen.json to find unreviewed
# (PR, iteration) pairs. Picks the OLDEST such pair (one per tick) and spawns
# the copilot agent (via the shared Invoke-CopilotAgent helper) to run the
# pr-review-assistant skill end-to-end (fetch diff,
# code-review sub-agent, post comments to ADO, write report, email Nir).
#
# Scheduled by:  DM-PrReviewAssistant  (every 5 min, 24/7).
#
# Manual flags:
#   -PRId <id>    review exactly this PR (skips the scan; for on-demand mode)
#   -DryRun       compute + log; no copilot-cli invocation, no state writes
#   -Force        ignore seen.json (re-review even if (pr,iter) already processed)
#   -AsOfDate     override "today" for testing (YYYY-MM-DD)
#   -MaxPerRun    cap on PRs processed per tick (default: 1)

[CmdletBinding()]
param(
    [int]    $PRId,
    [switch] $DryRun,
    [switch] $Force,
    [string] $AsOfDate,
    [int]    $MaxPerRun = 1
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')

$skillDir       = Join-Path $AgentRoot '.copilot\skills\pr-review-assistant'
$stateDir       = Join-Path $skillDir 'state'
$rulesDir       = Join-Path $skillDir 'rules'
$seenStatePath  = Join-Path $stateDir 'seen.json'
$cutoffPath     = Join-Path $stateDir 'cutoff.txt'
$skillMd        = Join-Path $skillDir 'SKILL.md'
$reportsRoot    = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) -Config $AgentConfig
$reviewsRoot    = Join-Path $reportsRoot 'pr-reviews'

New-Item -ItemType Directory -Force -Path $stateDir    | Out-Null
New-Item -ItemType Directory -Force -Path $reviewsRoot | Out-Null

# Pure helpers (Read-SeenState, Test-PrIterationSeen, Add-SeenRecord,
# Resolve-PrReviewReportPath, Build-PrReviewAgentPrompt) live in helpers.ps1
# so the tests can dot-source them without pulling in REST / COM / copilot-cli.
. (Join-Path $skillDir 'helpers.ps1')

$now      = if ($AsOfDate) { [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null).Date.AddHours(10) } else { Get-Date }
$nowKey   = $now.ToString('yyyy-MM-dd_HHmm')
$logFile  = Join-Path $LogDir ("pr-review-assistant-" + $nowKey + ".log")

$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$adoOrg        = Get-AgentField -Path 'ado.org'                   -Default 'your-ado-org'                 -Config $AgentConfig
$adoProject    = Get-AgentField -Path 'ado.project'               -Default 'One'                     -Config $AgentConfig
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- ADO REST helpers ----------------------------------------------------

function Get-AdoAccessToken {
    # Resource ID 499b84ac-1321-427f-aa17-267ca6975798 = Azure DevOps.
    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $token) { throw "Failed to acquire ADO token via az CLI. Run 'az login' first." }
    return $token
}

function Get-AdoSelfId {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $OrgBaseUrl)
    # connectionData rejects api-version=7.1 with 400; either omit the version or use the 6.0-preview.1 form.
    $url = "$OrgBaseUrl/_apis/connectionData"
    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    if (-not $resp.authenticatedUser -or -not $resp.authenticatedUser.id) {
        throw "ADO connectionData did not return authenticatedUser.id"
    }
    return [string]$resp.authenticatedUser.id
}

function Get-AdoSelfDisplayName {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $OrgBaseUrl)
    $url = "$OrgBaseUrl/_apis/connectionData"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    } catch {
        return $null
    }
    if (-not $resp.authenticatedUser) { return $null }
    $name = [string]$resp.authenticatedUser.providerDisplayName
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string]$resp.authenticatedUser.customDisplayName
    }
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

function Get-PullRequestThreads {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $OrgBaseUrl,
        [Parameter(Mandatory)] [string]    $Project,
        [Parameter(Mandatory)] [string]    $RepoId,
        [Parameter(Mandatory)] [int]       $PrId
    )
    $url = "$OrgBaseUrl/$Project/_apis/git/repositories/$RepoId/pullRequests/$PrId/threads?api-version=7.1"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    } catch {
        return @()
    }
    if (-not $resp.value) { return @() }
    return @($resp.value)
}

function Get-ActivePullRequestsForReviewer {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $OrgBaseUrl,
        [Parameter(Mandatory)] [string]    $Project,
        [Parameter(Mandatory)] [string]    $ReviewerId
    )
    $url = "$OrgBaseUrl/$Project/_apis/git/pullrequests?searchCriteria.reviewerId=$ReviewerId&searchCriteria.status=active&`$top=200&api-version=7.1"
    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    if (-not $resp.value) { return @() }
    return @($resp.value)
}

function Get-LatestIterationId {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $OrgBaseUrl,
        [Parameter(Mandatory)] [string]    $Project,
        [Parameter(Mandatory)] [string]    $RepoId,
        [Parameter(Mandatory)] [int]       $PrId
    )
    $url = "$OrgBaseUrl/$Project/_apis/git/repositories/$RepoId/pullRequests/$PrId/iterations?api-version=7.1"
    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    if (-not $resp.value -or $resp.value.Count -eq 0) { return 0 }
    $maxId = 0
    foreach ($it in $resp.value) {
        $iid = [int]$it.id
        if ($iid -gt $maxId) { $maxId = $iid }
    }
    return $maxId
}

# --- copilot-cli invocation -----------------------------------------------

function Invoke-CopilotReview {
    param(
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [int]    $IterationId,
        [Parameter(Mandatory)] [string] $RepoName,
        [Parameter(Mandatory)] [string] $ReportPath,
        [Parameter(Mandatory)] [bool]   $IsOnDemand,
        [Parameter(Mandatory)] [bool]   $MigrationMode
    )
    $prompt = Build-PrReviewAgentPrompt `
        -PrId $PrId `
        -IterationId $IterationId `
        -RepoName $RepoName `
        -ReportPath $ReportPath `
        -IsOnDemand $IsOnDemand `
        -MigrationMode $MigrationMode `
        -SkillMdPath $skillMd `
        -AdoOrg $adoOrg `
        -AdoProject $adoProject `
        -ManagerEmail $mgrEmail `
        -SubjectPrefix $subjectPrefix `
        -DmRulesPaths (Get-DmReviewRulesPaths -RulesDir $rulesDir)

    Write-Log "Invoking copilot-cli for PR $PrId iter $IterationId (repo=$RepoName, ondemand=$IsOnDemand, migration=$MigrationMode)."
    $r = Invoke-CopilotAgent -Prompt $prompt -LogFile $logFile -Model 'claude-opus-4.8' -AppendLog
    if (-not $r.Ran) {
        Write-Log "  ERROR: 'copilot' CLI not found in PATH; cannot review PR $PrId."
        return $false
    }
    if ($r.ExitCode -ne 0) {
        Write-Log "  WARN: copilot-cli exited with code $($r.ExitCode) (continuing; report-file presence is the source of truth)."
    }
    return (Test-Path $ReportPath)
}

# --- Resolve report path --------------------------------------------------

function Resolve-ReportPath {
    param(
        [Parameter(Mandatory)] [int] $PrId,
        [Parameter(Mandatory)] [int] $IterationId
    )
    return (Resolve-PrReviewReportPath -ReviewsRoot $reviewsRoot -PrId $PrId -IterationId $IterationId)
}

# --- Single-instance lock -------------------------------------------------

$lockPath = Join-Path $LogDir 'pr-review-assistant.lock'
if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    # Each headless review can take several minutes; allow up to 20 min before
    # breaking the lock. (Scheduler fires every 5 min -- overlap is the norm.)
    if ($lockAge.TotalMinutes -lt 20) {
        Write-Log "Another instance is running (lock age $([int]$lockAge.TotalMinutes)m). Exiting silently."
        exit 0
    }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {

# --- Main flow -----------------------------------------------------------

$migrationMode = [bool](Test-MigrationMode)
if ($migrationMode) {
    Write-Log "Migration-mode is ACTIVE -- copilot review will be told to skip ADO writes / email / state."
}

$isOnDemand = [bool]$PRId
$orgBase    = "https://dev.azure.com/$adoOrg"

if ($isOnDemand) {
    # On-demand path: caller already named the PR. Skip the broad scan; just
    # resolve repo + latest iteration, then dispatch.
    Write-Log "On-demand review requested: PR $PRId"
    try {
        $token   = Get-AdoAccessToken
        $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    } catch {
        Write-Log "  ERROR: $($_.Exception.Message)"
        return
    }

    # Fetch PR details directly (PR id is org-unique in ADO; query the project endpoint).
    $prUrl = "$orgBase/$adoProject/_apis/git/pullrequests/$PRId" + "?api-version=7.1"
    try {
        $pr = Invoke-RestMethod -Method GET -Uri $prUrl -Headers $headers
    } catch {
        Write-Log "  ERROR: failed to fetch PR $PRId via ADO REST: $($_.Exception.Message)"
        return
    }

    if (-not $pr) { Write-Log "  ERROR: PR $PRId not found in project $adoProject."; return }
    $repoId   = [string]$pr.repository.id
    $repoName = [string]$pr.repository.name

    $iterId = Get-LatestIterationId -Headers $headers -OrgBaseUrl $orgBase -Project $adoProject -RepoId $repoId -PrId $PRId
    if ($iterId -le 0) { Write-Log "  ERROR: PR $PRId has no iterations (?). Aborting."; return }

    $seen = @(Read-SeenState -Path $seenStatePath)
    if ((Test-PrIterationSeen -Records $seen -PrId $PRId -IterationId $iterId) -and -not $Force) {
        Write-Log "PR $PRId iter $iterId already reviewed (seen.json). Use -Force to re-review."
        return
    }

    $reportPath = Resolve-ReportPath -PrId $PRId -IterationId $iterId
    Write-Log "Report path: $reportPath"

    if ($DryRun) {
        Write-Log "[DryRun] would invoke review for PR $PRId iter $iterId (repo=$repoName). Exiting."
        return
    }

    $ok = Invoke-CopilotReview `
        -PrId $PRId `
        -IterationId $iterId `
        -RepoName $repoName `
        -ReportPath $reportPath `
        -IsOnDemand $true `
        -MigrationMode $migrationMode

    if ($ok -and -not $migrationMode) {
        Add-SeenRecord -Path $seenStatePath -PrId $PRId -IterationId $iterId -ReviewedAtIso $now.ToString('o')
        Write-Log "Marked PR $PRId iter $iterId seen."
    } elseif ($migrationMode) {
        Write-Log "  [migration-mode] Skipping seen.json update."
    } else {
        Write-Log "  WARN: copilot review did not produce a report file; NOT marking seen (next manual run will retry)."
    }
    return
}

# --- Scheduled scan path -------------------------------------------------

try {
    $token   = Get-AdoAccessToken
    $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
} catch {
    Write-Log "  ERROR: $($_.Exception.Message)"
    return
}

try {
    $selfId = Get-AdoSelfId -Headers $headers -OrgBaseUrl $orgBase
} catch {
    Write-Log "  ERROR: could not resolve self id from ADO: $($_.Exception.Message)"
    return
}
Write-Log "Self id: $selfId"
$selfDisplayName = Get-AdoSelfDisplayName -Headers $headers -OrgBaseUrl $orgBase
if ([string]::IsNullOrWhiteSpace($selfDisplayName)) {
    Write-Log "  WARN: could not resolve self displayName from ADO; the cutoff rescue (late reviewer-add) will be disabled this tick."
} else {
    Write-Log "Self displayName: $selfDisplayName"
}

try {
    $prs = Get-ActivePullRequestsForReviewer -Headers $headers -OrgBaseUrl $orgBase -Project $adoProject -ReviewerId $selfId
} catch {
    Write-Log "  ERROR: ADO PR list failed: $($_.Exception.Message)"
    return
}
Write-Log "ADO returned $($prs.Count) active PR(s) where I'm a reviewer."

# Client-side filters: drop drafts and self-authored.
$candidates = @()
foreach ($pr in $prs) {
    if ($pr.isDraft) { continue }
    if ($pr.createdBy.id -eq $selfId) { continue }
    $candidates += $pr
}
Write-Log "After draft + self-authored filter: $($candidates.Count) candidate(s)."

# Auto-review cutoff: the scheduled scan only acts on PRs created on/after this
# instant. Set in state/cutoff.txt. On-demand reviews (-PRId) bypass this gate.
# Rescue rule: a PR whose creationDate is BEFORE the cutoff is still kept if
# Nir was added as a reviewer on/after the cutoff (otherwise late assignments
# to older PRs get silently dropped).
$cutoff = Get-PrAutoCutoff -Path $cutoffPath
if ($cutoff) {
    $beforeCutoff = $candidates.Count
    $styles       = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $kept            = New-Object System.Collections.Generic.List[object]
    $droppedByCutoff = 0
    $rescued         = 0
    foreach ($pr in $candidates) {
        try {
            $created = [DateTime]::Parse([string]$pr.creationDate, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        } catch {
            $kept.Add($pr) | Out-Null
            continue
        }
        if ($created -ge $cutoff) {
            $kept.Add($pr) | Out-Null
            continue
        }
        # Created before cutoff -- attempt the late-reviewer-add rescue.
        $addedAt = $null
        if (-not [string]::IsNullOrWhiteSpace($selfDisplayName)) {
            try {
                $repoId = [string]$pr.repository.id
                $threads = Get-PullRequestThreads -Headers $headers -OrgBaseUrl $orgBase -Project $adoProject -RepoId $repoId -PrId ([int]$pr.pullRequestId)
                $addedAt = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName $selfDisplayName
            } catch {
                $addedAt = $null
            }
        }
        if ($addedAt -and $addedAt -ge $cutoff) {
            Write-Log "  PR $($pr.pullRequestId) created $($created.ToString('o')) is before cutoff, but I was added as reviewer at $($addedAt.ToString('o')) -- rescuing."
            $kept.Add($pr) | Out-Null
            $rescued++
        } else {
            $droppedByCutoff++
        }
    }
    $candidates = @($kept)
    Write-Log "After auto-review cutoff filter (>= $($cutoff.ToString('o'))): $($candidates.Count) candidate(s) (dropped $droppedByCutoff older PR(s), rescued $rescued via late reviewer-add)."
} else {
    Write-Log "No auto-review cutoff configured (state/cutoff.txt missing or 'none')."
}

if ($candidates.Count -eq 0) {
    Write-Log "Nothing to review. Exiting."
    return
}

# Resolve latest iteration for each, find first unseen one (oldest by PR creation).
$seen = @(Read-SeenState -Path $seenStatePath)
$candidates = @($candidates | Sort-Object -Property creationDate)

$processed = 0
foreach ($pr in $candidates) {
    if ($processed -ge $MaxPerRun) { break }
    $prId   = [int]$pr.pullRequestId
    $repoId   = [string]$pr.repository.id
    $repoName = [string]$pr.repository.name
    try {
        $iterId = Get-LatestIterationId -Headers $headers -OrgBaseUrl $orgBase -Project $adoProject -RepoId $repoId -PrId $prId
    } catch {
        Write-Log "  WARN: iterations lookup failed for PR $prId : $($_.Exception.Message). Skipping."
        continue
    }
    if ($iterId -le 0) {
        Write-Log "  PR $prId has no iterations; skipping."
        continue
    }
    if (-not $Force -and (Test-PrIterationSeen -Records $seen -PrId $prId -IterationId $iterId)) {
        # Already reviewed this iteration; skip silently.
        continue
    }

    Write-Log "Picked PR $prId (repo=$repoName) iter $iterId for review."
    $reportPath = Resolve-ReportPath -PrId $prId -IterationId $iterId
    Write-Log "Report path: $reportPath"

    if ($DryRun) {
        Write-Log "[DryRun] would invoke review for PR $prId iter $iterId. Skipping."
        $processed++
        continue
    }

    $ok = Invoke-CopilotReview `
        -PrId $prId `
        -IterationId $iterId `
        -RepoName $repoName `
        -ReportPath $reportPath `
        -IsOnDemand $false `
        -MigrationMode $migrationMode

    if ($ok -and -not $migrationMode) {
        Add-SeenRecord -Path $seenStatePath -PrId $prId -IterationId $iterId -ReviewedAtIso (Get-Date).ToString('o')
        Write-Log "Marked PR $prId iter $iterId seen."
    } elseif ($migrationMode) {
        Write-Log "  [migration-mode] Skipping seen.json update for PR $prId."
    } else {
        Write-Log "  WARN: copilot review did not produce a report file for PR $prId; NOT marking seen."
    }
    $processed++
}

Write-Log "Done. Processed $processed PR(s) this tick."

}
finally {
    Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
}

