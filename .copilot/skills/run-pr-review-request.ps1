#Requires -Version 5.1
<#
.SYNOPSIS
    pr-review-request runner - posts a Teams channel "please review" message for each
    NEW pull request created by a direct report (or Nir himself), from now onward.

.DESCRIPTION
    See .copilot/skills/pr-review-request/SKILL.md for the full spec.

    Each tick:
      1. Ensure a baseline timestamp exists (state/baseline.txt). Only PRs created at/after
         the baseline are eligible -> honours "from PRs starting from now" (no backfill).
      2. Resolve the roster (self + directs from directs-context.json) to ADO identity ids.
      3. Query ADO for each member's ACTIVE PRs created at/after the baseline.
      4. For every eligible PR not already in state/posted.json, post ONE Teams message
         (via the post-to-teams Outlook -> Power Automate flow) asking the team to review it,
         then record the PR id idempotently.

.PARAMETER DryRun
    Resolve and report what would be posted, but do NOT send Teams emails and do NOT mutate
    state/posted.json.

.PARAMETER WhatIf
    Alias for DryRun semantics.

.PARAMETER Force
    Ignore state/posted.json (re-post eligible PRs). Still respects the baseline.

.PARAMETER ResetBaseline
    Rewrite state/baseline.txt to the current time before scanning (use to "start from now"
    again). Combine with care -- it discards the previous cutoff.
#>
param(
    [switch] $DryRun,
    [switch] $WhatIf,
    [switch] $Force,
    [switch] $ResetBaseline
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')
. (Join-Path $PSScriptRoot '_shared\signature.ps1')   # top-level scope (see ooo-mode scoping memory)

# Compact one-line Nirvana sign-off for PR status updates. Nir asked status updates to be
# signed (2026-06-03), overriding the usual "Teams posts are unsigned" convention for this
# skill only. Uses the canonical HTML footer (hr + Nirvana brand) so it matches the footer
# on Nirvana's other messages -- never hand-rolled.
function Get-UpdateSignoffHtml {
    try { return [string](Get-NirvanaSignature) }
    catch { return '<hr><p style="color:#666;"><em>Sent on Nir''s behalf by <strong>Nir</strong>vana &mdash; Nir''s agent.</em></p>' }
}

$cfg          = $AgentConfig
$adoOrg       = Get-AgentField -Path 'ado.org'     -Default 'your-ado-org' -Config $cfg
$adoProject   = Get-AgentField -Path 'ado.project' -Default 'One'     -Config $cfg
$reportsRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $cfg) -Config $cfg
$directsJson  = Join-Path $reportsRoot 'directs-scope\directs-context.json'

$skillDir     = Join-Path $PSScriptRoot 'pr-review-request'
$stateDir     = Join-Path $skillDir 'state'
$baselineFile = Join-Path $stateDir 'baseline.txt'
$postedFile   = Join-Path $stateDir 'posted.json'
$statsFile    = Join-Path $stateDir 'review-stats.json'
$tuConfigFile = Join-Path $skillDir 'thread-updates.config.json'

. (Join-Path $skillDir 'stats.ps1')       # stats & gamification helpers (pure; top-level scope)
. (Join-Path $skillDir 'ado-helpers.ps1') # shared ADO auth/identity/REST helpers (top-level scope)

# Thread-updates feature config (default OFF). See pr-review-request/THREAD-UPDATES.md.
$tu = [PSCustomObject]@{ enabled = $false; updateSubjectPrefix = '[Nirvana][PR Status Update]'; detectFirstReviewVia = 'votes+comments' }
if (Test-Path $tuConfigFile) {
    try {
        $tuRaw = Get-Content -Path $tuConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $tuRaw) {
            if ($tuRaw.PSObject.Properties['enabled'])              { $tu.enabled              = [bool]$tuRaw.enabled }
            if ($tuRaw.PSObject.Properties['updateSubjectPrefix'])  { $tu.updateSubjectPrefix  = [string]$tuRaw.updateSubjectPrefix }
            if ($tuRaw.PSObject.Properties['detectFirstReviewVia']) { $tu.detectFirstReviewVia = [string]$tuRaw.detectFirstReviewVia }
        }
    } catch { Write-Host "WARN: thread-updates.config.json unreadable; thread updates disabled. $($_.Exception.Message)" }
}

$teamsTrigger = 'someone@example.com'   # post-to-teams flow requires From+To = Nir
$maxPerTick   = 10                          # safety cap against accidental flooding

$dry = ($DryRun.IsPresent -or $WhatIf.IsPresent)

$logDate = (Get-Date).ToString('yyyy-MM-dd')
$logPath = Join-Path $reportsRoot ("pr-review-request\{0}.md" -f $logDate)
New-Item -ItemType Directory -Force -Path (Split-Path $logPath -Parent) | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Write-Log {
    param([string]$Message)
    Write-Host "$(Get-Date -Format o) $Message"
}

# ---------------------------------------------------------------------------
# 1) Baseline -- written FIRST, before any Outlook/ADO dependency, so a tick that
#    later skips (Outlook down) can never lose the "from now" cutoff.
# ---------------------------------------------------------------------------
function Get-IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

# ConvertTo-UtcDate lives in ado-helpers.ps1 (dot-sourced above).

if ($ResetBaseline -and -not $dry) {
    Set-Content -Path $baselineFile -Value (Get-IsoNow) -Encoding ASCII
    Write-Log "Baseline reset."
}
if (-not (Test-Path $baselineFile)) {
    if ($dry) {
        Write-Log "[dry-run] baseline.txt missing; would initialize to now ($(Get-IsoNow))."
    } else {
        Set-Content -Path $baselineFile -Value (Get-IsoNow) -Encoding ASCII
        Write-Log "Initialized baseline.txt to now ($(Get-IsoNow)). No backfill of older PRs."
    }
}

$baselineRaw = if (Test-Path $baselineFile) { (Get-Content -Path $baselineFile -Raw).Trim() } else { Get-IsoNow }
try {
    $baseline = [DateTime]::Parse($baselineRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
} catch {
    Write-Log "WARN: could not parse baseline '$baselineRaw'; defaulting to now."
    $baseline = (Get-Date).ToUniversalTime()
}
Write-Log "Baseline (UTC): $($baseline.ToString('o')). Only PRs created at/after this are eligible."

# ---------------------------------------------------------------------------
# Preflight (does not block baseline init above)
# ---------------------------------------------------------------------------
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isElevated) {
    Write-Log "ABORT: PowerShell is elevated; Outlook COM will fail. Relaunch as a standard user."
    exit 1
}
if (-not $dry -and -not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    Write-Log "Outlook is not running. Skipping this tick (PRs remain eligible next tick)."
    exit 0
}

# ---------------------------------------------------------------------------
# 2) ADO auth + roster resolution
#    Auth/identity/REST helpers (Get-AdoAccessToken, Invoke-AdoRest, Get-AdoSelf,
#    Get-AdoIdentity, ConvertTo-UtcDate) are shared with seed-baseline.ps1 and live
#    in ado-helpers.ps1 (dot-sourced above). PR-query helpers stay local below.
# ---------------------------------------------------------------------------
function Get-ActivePrsByCreator {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $IdentityId)
    $url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/pullrequests?searchCriteria.creatorId=$IdentityId&searchCriteria.status=active&`$top=100&api-version=7.1"
    try { $resp = Invoke-AdoRest -Headers $Headers -Url $url } catch {
        Write-Log "WARN: PR search failed for creator=${IdentityId}: $($_.Exception.Message)"
        return @()
    }
    if (-not $resp.value) { return @() }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($pr in @($resp.value)) {
        try {
            $created = [DateTime]::Parse([string]$pr.creationDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        } catch { continue }
        $items.Add([PSCustomObject]@{
            id         = [int]$pr.pullRequestId
            repoName   = [string]$pr.repository.name
            repoId     = [string]$pr.repository.id
            title      = [string]$pr.title
            createdAt  = $created
            isDraft    = [bool]$pr.isDraft
            authorName = [string]$pr.createdBy.displayName
        })
    }
    return $items.ToArray()
}

# ---------------------------------------------------------------------------
# 3) posted.json (idempotency) -- atomic read/write
# ---------------------------------------------------------------------------
function Read-Posted {
    if (-not (Test-Path $postedFile)) { return @{} }
    try {
        $raw = Get-Content -Path $postedFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $arr = $raw | ConvertFrom-Json
        $map = @{}
        foreach ($r in @($arr)) { if ($null -ne $r.id) { $map["$($r.id)"] = $r } }
        return $map
    } catch {
        Write-Log "WARN: posted.json unreadable; treating as empty. $($_.Exception.Message)"
        return @{}
    }
}

function Write-Posted {
    param([hashtable] $Map)
    $list = @($Map.Values | Sort-Object { [int]$_.id })
    $json = if ($list.Count -eq 0) { '[]' } else { ($list | ConvertTo-Json -Depth 5) }
    if ($list.Count -eq 1) { $json = "[" + $json + "]" }   # ConvertTo-Json drops the array for single items
    $tmp = "$postedFile.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $postedFile -Force
}

function HtmlEnc { param([string]$S) [System.Net.WebUtility]::HtmlEncode([string]$S) }

function Send-TeamsReviewRequest {
    param([PSCustomObject] $Pr)
    $repoSeg = [uri]::EscapeDataString($Pr.repoName)
    $prUrl   = "https://dev.azure.com/$adoOrg/$adoProject/_git/$repoSeg/pullrequest/$($Pr.id)"
    $titleE  = HtmlEnc $Pr.title
    $authorE = HtmlEnc $Pr.authorName
    $repoE   = HtmlEnc $Pr.repoName
    $urlE    = HtmlEnc $prUrl

    $subject = "NirvanaTeams Review request: PR $($Pr.id) by $($Pr.authorName) | PRCorr:$($Pr.repoId)_$($Pr.id)"
    $html = @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">
  <p>&#128269; <b>New PR needs a review</b></p>
  <p><b><a href="$urlE">$titleE</a></b></p>
  <p>Author: <b>$authorE</b> &middot; Repo: $repoE &middot; PR #$($Pr.id)</p>
  <p>Please grab it and leave a review when you get a chance. &#128591;</p>
</div>
"@

    $ol   = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)   # olMailItem
    $mail.To       = $teamsTrigger
    $mail.Subject  = $subject
    $mail.HTMLBody = $html
    $mail.Send()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
    return @{ subject = $subject; url = $prUrl }
}

# ---------------------------------------------------------------------------
# 4) Thread updates (feature-flagged) -- detect first-review / completion and
#    emit a PR Status Update email. See pr-review-request/THREAD-UPDATES.md.
#    The runner does NOT track the Teams message id: it just emits an update
#    email with subject "<prefix>[<prId>" (no trailing ']') + the body verbatim;
#    Nir's Power Automate flow correlates to the original thread by PR id.
# ---------------------------------------------------------------------------
function Get-Prop { param($Obj, [string]$Name) if ($Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name } return $null }

function Get-PrById {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [int] $Id)
    $url = "https://dev.azure.com/$adoOrg/_apis/git/pullrequests/$Id`?api-version=7.1"
    try { return Invoke-AdoRest -Headers $Headers -Url $url } catch {
        Write-Log "WARN: Get-PrById failed for PR #${Id}: $($_.Exception.Message)"
        return $null
    }
}

function Get-PrThreads {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $RepoId, [Parameter(Mandatory)] [int] $Id)
    $url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/repositories/$RepoId/pullRequests/$Id/threads?api-version=7.1"
    try { $resp = Invoke-AdoRest -Headers $Headers -Url $url } catch { return @() }
    if (-not $resp.value) { return @() }
    return @($resp.value)
}

# First human review signal = the first non-author, non-group reviewer who has voted, or
# (when enabled) the first non-author non-system commenter. Returns an object carrying the
# reviewer's display name + a normalized outcome, or $null when no review has happened yet.
# Vote map: 10 approved, 5 approved-with-suggestions, -5 waiting, -10 changes-requested.
function Get-FirstReviewSignal {
    param(
        [Parameter(Mandatory)] $Pr,
        [string] $AuthorId,
        [object[]] $Threads = @(),
        [string] $DetectVia = 'votes+comments'
    )
    foreach ($rv in @($Pr.reviewers)) {
        if ([bool](Get-Prop $rv 'isContainer')) { continue }
        $rid = [string](Get-Prop $rv 'id')
        if ($rid -and $AuthorId -and $rid -eq $AuthorId) { continue }
        $vote = [int](Get-Prop $rv 'vote')
        if ($vote -ne 0) {
            $outcome = switch ($vote) {
                10      { 'approved' }
                5       { 'approved-suggestions' }
                -5      { 'waiting' }
                -10     { 'rejected' }
                default { 'reviewed' }
            }
            return [PSCustomObject]@{ Actor = [string](Get-Prop $rv 'displayName'); ActorId = $rid; Outcome = $outcome }
        }
    }
    if ($DetectVia -match 'comments') {
        foreach ($t in @($Threads)) {
            foreach ($c in @($t.comments)) {
                $ct = [string](Get-Prop $c 'commentType')
                if ($ct -and $ct -ne 'text' -and $ct -ne 'codeChange') { continue }   # skip 'system'
                $auth = Get-Prop $c 'author'
                $aid  = [string](Get-Prop $auth 'id')
                if ($aid -and $AuthorId -and $aid -eq $AuthorId) { continue }
                if (-not [string]::IsNullOrWhiteSpace($aid)) {
                    return [PSCustomObject]@{ Actor = [string](Get-Prop $auth 'displayName'); ActorId = $aid; Outcome = 'commented' }
                }
            }
        }
    }
    return $null
}

# Compatibility shim: boolean "has a first review happened?" built on Get-FirstReviewSignal.
function Test-FirstReviewed {
    param(
        [Parameter(Mandatory)] $Pr,
        [string] $AuthorId,
        [object[]] $Threads = @(),
        [string] $DetectVia = 'votes+comments'
    )
    return ($null -ne (Get-FirstReviewSignal -Pr $Pr -AuthorId $AuthorId -Threads $Threads -DetectVia $DetectVia))
}

# Render the first-review Teams update body, naming the reviewer + their outcome.
function Get-FirstReviewBody {
    param(
        [Parameter(Mandatory)] [int] $PrId,
        [string] $Title,
        [Parameter(Mandatory)] $Signal,
        [string] $ExtraHtml = ''
    )
    $who = HtmlEnc ([string]$Signal.Actor)
    $t   = HtmlEnc ([string]$Title)
    switch ([string]$Signal.Outcome) {
        'approved'             { $glyph = '&#9989;';   $lead = "<b>Approved</b> by $who" }
        'approved-suggestions' { $glyph = '&#9989;';   $lead = "<b>Approved with suggestions</b> by $who" }
        'waiting'              { $glyph = '&#9203;';   $lead = "<b>Waiting for author</b> &mdash; $who left feedback" }
        'rejected'             { $glyph = '&#9940;';   $lead = "<b>Changes requested</b> by $who" }
        'commented'            { $glyph = '&#128172;'; $lead = "<b>Reviewed</b> by $who" }
        default                { $glyph = '&#128064;'; $lead = "<b>In review</b> &mdash; reviewed by $who" }
    }
    $extra = if (-not [string]::IsNullOrWhiteSpace($ExtraHtml)) { [string]$ExtraHtml } else { '' }
    return "<div style=`"font-family:Segoe UI,Arial,sans-serif;font-size:14px;`">$glyph $lead &middot; PR #$PrId &mdash; $t$extra$(Get-UpdateSignoffHtml)</div>"
}

# Emit a PR Status Update trigger email. Subject is "<Prefix>[<PrId>" with NO trailing ']'
# so Nir's flow can extract the PR id via last(split(Subject,'[')). Body is reposted verbatim.
function Send-TeamsThreadReply {
    param(
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [string] $Html,
        [Parameter(Mandatory)] [string] $Prefix
    )
    $subject = "$Prefix[$PrId"
    $ol   = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    $mail.To       = $teamsTrigger
    $mail.Subject  = $subject
    $mail.HTMLBody = $Html
    $mail.Send()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
}

# Read review-stats.json defensively: a corrupt file returns $null (so we skip stats
# this tick rather than overwrite history with an empty object).
function Get-ReviewStatsSafe {
    try { return Read-PrReviewStats -Path $statsFile }
    catch {
        Write-Log "  WARN: review-stats.json unreadable ($($_.Exception.Message)); proceeding without stats this tick."
        return $null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
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

# Collect eligible PRs (active, created at/after baseline, not draft), de-duped by id.
$eligible = @{}
foreach ($member in $roster) {
    foreach ($pr in (Get-ActivePrsByCreator -Headers $headers -IdentityId $member.id)) {
        if ($pr.createdAt -lt $baseline) { continue }
        if ($pr.isDraft) { continue }                 # drafts post when published (still active + unseen)
        if (-not $eligible.ContainsKey("$($pr.id)")) { $eligible["$($pr.id)"] = $pr }
    }
}
Write-Log "Eligible new PRs (active, post-baseline, non-draft): $($eligible.Count)."

$posted = Read-Posted
$toPost = @($eligible.Values | Where-Object { $Force.IsPresent -or -not $posted.ContainsKey("$($_.id)") } | Sort-Object createdAt)

if ($toPost.Count -gt $maxPerTick) {
    Write-Log "Safety cap: $($toPost.Count) candidates exceeds $maxPerTick; posting the $maxPerTick oldest this tick, rest next tick."
    $toPost = @($toPost | Select-Object -First $maxPerTick)
}

$sent = 0
foreach ($pr in $toPost) {
    $label = "PR #$($pr.id) '$($pr.title)' by $($pr.authorName) [$($pr.repoName)]"
    if ($dry) {
        Write-Log "[dry-run] would post review request for $label"
        continue
    }
    if (Test-MigrationMode) {
        Write-Log "[migration-mode] would post review request for $label (state unchanged)"
        continue
    }
    try {
        $res = Send-TeamsReviewRequest -Pr $pr
    } catch {
        Write-Log "ERROR sending Teams request for $label : $($_.Exception.Message)"
        continue
    }
    # Record idempotency ONLY after a successful send.
    $posted["$($pr.id)"] = [PSCustomObject]@{
        id              = $pr.id
        repo            = $pr.repoName
        repoId          = $pr.repoId
        author          = $pr.authorName
        title           = $pr.title
        prUrl           = $res.url
        createdAt       = $pr.createdAt.ToString('o')
        postedAt        = (Get-IsoNow)
        threadState     = 'posted'
        firstReviewedAt = $null
        terminalState   = $null
        terminalAt      = $null
    }
    Write-Posted -Map $posted
    Add-Content -Path $logPath -Value ("- {0} posted PR #{1} repo={2} author=`"{3}`" title=`"{4}`"" -f (Get-Date -Format 'HH:mm'), $pr.id, $pr.repoName, $pr.authorName, $pr.title) -Encoding UTF8
    Write-Log "POSTED: review request for $label -> $($res.subject)"
    $sent++
}

Write-Log "Done. eligible=$($eligible.Count) candidates=$($toPost.Count) sent=$sent dry=$dry force=$($Force.IsPresent)"

# ---------------------------------------------------------------------------
# Track pass: reply in-thread on first-review / completion. Feature-flagged.
# ---------------------------------------------------------------------------
if (-not $tu.enabled) {
    Write-Log "Thread updates disabled (thread-updates.config.json enabled=false). Skipping track pass."
} elseif ($dry) {
    Write-Log "[dry-run] thread updates enabled, but track pass is skipped in dry-run."
} elseif (Test-MigrationMode) {
    Write-Log "[migration-mode] thread updates skipped (state unchanged)."
} else {
    $tracked = @($posted.Values | Where-Object {
        $st = [string](Get-Prop $_ 'threadState')
        $st -and $st -ne 'completed' -and $st -ne 'abandoned'
    })
    Write-Log "Track pass: $($tracked.Count) PR(s) not yet terminal. detectVia=$($tu.detectFirstReviewVia)"
    $replies = 0
    foreach ($e in $tracked) {
        $eid   = [int](Get-Prop $e 'id')
        $repoId= [string](Get-Prop $e 'repoId')
        if ([string]::IsNullOrWhiteSpace($repoId)) {
            Write-Log "  PR #${eid}: no repoId on record (pre-v2 entry); not trackable. Skipping."
            continue
        }
        $title = [string](Get-Prop $e 'title')

        # 1) Fetch the PR by id (works even after it leaves the active-creator query).
        $pr = Get-PrById -Headers $headers -Id $eid
        if (-not $pr) { continue }
        $status   = [string]$pr.status
        $authorId = [string]$pr.createdBy.id

        # 2) Terminal first.
        if ($status -eq 'completed' -or $status -eq 'abandoned') {
            $stats      = Get-ReviewStatsSafe
            $statsDirty = $false
            $mergeBlock = ''

            if ($status -eq 'completed' -and $stats) {
                $createdUtc = $null
                try { $createdUtc = ConvertTo-UtcDate ([string](Get-Prop $e 'createdAt')) } catch { $createdUtc = $null }
                if ($createdUtc) {
                    # Prefer ADO's real completion time; fall back to detection time.
                    $closedUtc = (Get-Date).ToUniversalTime()
                    $cd = [string]$pr.closedDate
                    if (-not [string]::IsNullOrWhiteSpace($cd)) { try { $closedUtc = ConvertTo-UtcDate $cd } catch { } }
                    $ttmMin = ($closedUtc - $createdUtc).TotalMinutes
                    if ($ttmMin -lt 0) { $ttmMin = 0 }

                    $baseTtm   = Get-PrBaseline -Stats $stats -Metric 'ttm'
                    $mergeLine = Get-PrMergeLineHtml -Minutes $ttmMin -BaselineMinutes $baseTtm
                    $mergeBlock = "<br>$mergeLine"

                    $ttmKey = "ttm:$eid"
                    if (-not (Test-PrEventProcessed -Stats $stats -Key $ttmKey)) {
                        Add-PrStatSample -Stats $stats -Metric 'ttm' -Minutes $ttmMin
                        Add-PrProcessedEvent -Stats $stats -Key $ttmKey
                        $statsDirty = $true
                    }

                    # Fast PR: merged before we ever announced a first review. Credit the
                    # reviewer (gamification fairness) even though no in-review message went out.
                    if (([string](Get-Prop $e 'threadState') -eq 'posted') -and -not (Test-PrEventProcessed -Stats $stats -Key "fr:$eid")) {
                        $threadsC = @()
                        if ($tu.detectFirstReviewVia -match 'comments') { $threadsC = Get-PrThreads -Headers $headers -RepoId $repoId -Id $eid }
                        $sigC = Get-FirstReviewSignal -Pr $pr -AuthorId $authorId -Threads $threadsC -DetectVia $tu.detectFirstReviewVia
                        if ($sigC) {
                            $rkC = if (-not [string]::IsNullOrWhiteSpace([string]$sigC.ActorId)) { [string]$sigC.ActorId } else { ([string]$sigC.Actor).Trim().ToLowerInvariant() }
                            [void](Add-PrReviewerCredit -Stats $stats -ReviewerKey $rkC -DisplayName ([string]$sigC.Actor) -When (Get-Date))
                            Add-PrProcessedEvent -Stats $stats -Key "fr:$eid"
                            $statsDirty = $true
                        }
                    }
                }
            }

            $body = if ($status -eq 'completed') {
                "<div style=`"font-family:Segoe UI,Arial,sans-serif;font-size:14px;`">&#9989; <b>Completed</b> &middot; PR #$eid &mdash; $(HtmlEnc $title) has been merged. Thanks all! &#128591;$mergeBlock$(Get-UpdateSignoffHtml)</div>"
            } else {
                "<div style=`"font-family:Segoe UI,Arial,sans-serif;font-size:14px;`">&#128683; <b>Closed</b> &middot; PR #$eid &mdash; $(HtmlEnc $title) was abandoned (closed without merging).$(Get-UpdateSignoffHtml)</div>"
            }

            # Persist stats BEFORE the send so a crash before posted.json advances cannot
            # double-count on the next tick (the processed keys make a resend a no-op).
            if ($statsDirty) {
                Optimize-PrReviewStats -Stats $stats
                try { Write-PrReviewStats -Path $statsFile -Stats $stats } catch { Write-Log "  PR #${eid}: WARN could not persist review-stats: $($_.Exception.Message)" }
            }

            try {
                Send-TeamsThreadReply -PrId $eid -Html $body -Prefix $tu.updateSubjectPrefix
            } catch { Write-Log "  PR #${eid}: ERROR sending terminal update: $($_.Exception.Message)"; continue }
            $e.threadState   = $status
            $e.terminalState = $status
            $e.terminalAt    = (Get-IsoNow)
            Write-Posted -Map $posted
            Add-Content -Path $logPath -Value ("- {0} thread-update PR #{1} -> {2}" -f (Get-Date -Format 'HH:mm'), $eid, $status) -Encoding UTF8
            Write-Log "  PR #${eid}: sent '$status' update email."
            $replies++
            continue
        }

        # 3) Else first review (only from 'posted').
        if ([string](Get-Prop $e 'threadState') -eq 'posted') {
            $threads = @()
            if ($tu.detectFirstReviewVia -match 'comments') { $threads = Get-PrThreads -Headers $headers -RepoId $repoId -Id $eid }
            $signal = Get-FirstReviewSignal -Pr $pr -AuthorId $authorId -Threads $threads -DetectVia $tu.detectFirstReviewVia
            if ($signal) {
                $extra = ''
                $stats = Get-ReviewStatsSafe
                if ($stats) {
                    $createdUtc = $null
                    try { $createdUtc = ConvertTo-UtcDate ([string](Get-Prop $e 'createdAt')) } catch { $createdUtc = $null }
                    if ($createdUtc) {
                        $ttfrMin = ((Get-Date).ToUniversalTime() - $createdUtc).TotalMinutes
                        if ($ttfrMin -lt 0) { $ttfrMin = 0 }
                        $baseTtfr = Get-PrBaseline -Stats $stats -Metric 'ttfr'   # p50 baseline, NOT the mean
                        $speed   = Get-PrSpeedLineHtml -Minutes $ttfrMin -BaselineMinutes $baseTtfr
                        $gamify  = ''
                        $frKey   = "fr:$eid"
                        if (-not (Test-PrEventProcessed -Stats $stats -Key $frKey)) {
                            $rk   = if (-not [string]::IsNullOrWhiteSpace([string]$signal.ActorId)) { [string]$signal.ActorId } else { ([string]$signal.Actor).Trim().ToLowerInvariant() }
                            $cred = Add-PrReviewerCredit -Stats $stats -ReviewerKey $rk -DisplayName ([string]$signal.Actor) -When (Get-Date)
                            $gamify = Get-PrReviewerCallout -DisplayName ([string]$signal.Actor) -DailyCount $cred.DailyCount -WeeklyCount $cred.WeeklyCount -Total $cred.Total -IsWeekTop $cred.IsWeekTop
                            Add-PrStatSample -Stats $stats -Metric 'ttfr' -Minutes $ttfrMin
                            Add-PrProcessedEvent -Stats $stats -Key $frKey
                            Optimize-PrReviewStats -Stats $stats
                            try { Write-PrReviewStats -Path $statsFile -Stats $stats } catch { Write-Log "  PR #${eid}: WARN could not persist review-stats: $($_.Exception.Message)" }
                        }
                        $extra = "<br>$speed"
                        if ($gamify) { $extra += "<br>$gamify" }
                    }
                }
                $body = Get-FirstReviewBody -PrId $eid -Title $title -Signal $signal -ExtraHtml $extra
                try {
                    Send-TeamsThreadReply -PrId $eid -Html $body -Prefix $tu.updateSubjectPrefix
                } catch { Write-Log "  PR #${eid}: ERROR sending in-review update: $($_.Exception.Message)"; continue }
                $e.threadState     = 'first-reviewed'
                $e.firstReviewedAt = (Get-IsoNow)
                Write-Posted -Map $posted
                Add-Content -Path $logPath -Value ("- {0} thread-update PR #{1} -> first-reviewed ({2} by {3})" -f (Get-Date -Format 'HH:mm'), $eid, $signal.Outcome, $signal.Actor) -Encoding UTF8
                Write-Log "  PR #${eid}: sent first-review update email ($($signal.Outcome) by $($signal.Actor))."
                $replies++
            }
        }
    }
    Write-Log "Track pass done. replies=$replies"
}

