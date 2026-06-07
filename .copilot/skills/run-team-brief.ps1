# Sends Nir a fancy HTML brief of what his direct reports did:
#   -Mode daily   (default)  what the team did, for a target day (18:30 IST, same-day)
#   -Mode weekly             work-week highlights (Sun..Thu), Thursday 17:00 IST
#
# Data sources (all LOCAL, no live ADO):
#   - reports/directs-scope/directs-context.json  (per-direct PRs / work items / wins)
#   - .copilot/skills/team-personas/people/<alias>.md  ("## Daily observations")
#
# Rendering reuses _shared/investigation-email.ps1 (hero / TL;DR / stat-grid /
# per-person cards). Sending mirrors the email-team Outlook COM recipe
# (migration-mode guard, config recipient, never throws).
#
# Backfill-on-resume: the Cloud PC is suspended on weekends, so a Sunday/Monday
# run may owe several days. Daily mode covers [last-sent+1 .. target] in ONE
# consolidated email (cap 7 days). State only advances on a successful send.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-team-brief.ps1 -Mode daily
# Flags: -Date yyyy-MM-dd, -Force (ignore state / single day), -DryRun (render only,
#        no send, no state), -NoEmail (render + log, no send, no state), -Preview (open html).
#
# Scheduled by: DM-TeamBriefDaily (18:30 IST) and DM-TeamWeeklyHighlights (Thu 17:00 IST).

[CmdletBinding()]
param(
    [ValidateSet('daily', 'weekly')] [string] $Mode = 'daily',
    [string] $Date,
    [switch] $Force,
    [switch] $DryRun,
    [switch] $NoEmail,
    [switch] $Enrich,
    [switch] $Preview
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_shared\config.ps1')
. (Join-Path $PSScriptRoot '_shared\signature.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')
. (Join-Path $PSScriptRoot '_shared\investigation-email.ps1')
. (Join-Path $PSScriptRoot 'team-brief\helpers.ps1')

# --- Paths -------------------------------------------------------------------
$skillDir   = Join-Path $AgentRoot '.copilot\skills\team-brief'
$stateDir   = Join-Path $skillDir 'state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$peopleDir  = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$directsCtx = Join-Path $AgentRoot 'reports\directs-scope\directs-context.json'
$outDir     = Join-Path $AgentRoot 'reports\team-brief'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$stamp   = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$logFile = Join-Path $LogDir "team-brief-$Mode-$stamp.log"
function Write-Log { param([string]$m) $line = "{0} {1}" -f (Get-Date).ToString('o'), $m; Add-Content -Path $logFile -Value $line; Write-Host $line }

Write-Log "team-brief start mode=$Mode date=$Date force=$Force dryrun=$DryRun noemail=$NoEmail"

# --- Load directs-context ----------------------------------------------------
if (-not (Test-Path $directsCtx)) { Write-Log "ERROR: directs-context not found at $directsCtx"; throw "directs-context.json missing" }
$ctx = Get-Content $directsCtx -Raw | ConvertFrom-Json
$directs = $ctx.directs
$ctxGenLabel = ''
if ($ctx.generated_at) {
    try { $ctxGenLabel = ([datetime]$ctx.generated_at).ToString('MMM d, HH:mm') } catch { $ctxGenLabel = [string]$ctx.generated_at }
}
$totalDirects = @($directs.PSObject.Properties.Name).Count
Write-Log "Loaded directs-context: $totalDirects directs (generated $ctxGenLabel)."

$tz = Get-IsraelTimeZone

# --- State helpers -----------------------------------------------------------
$stateFile = Join-Path $stateDir ("$Mode-sent.json")
function Read-BriefState {
    if (-not (Test-Path $stateFile)) { return [pscustomobject]@{ records = @() } }
    try { return (Get-Content $stateFile -Raw | ConvertFrom-Json) } catch { return [pscustomobject]@{ records = @() } }
}
function Write-BriefState { param($State) ($State | ConvertTo-Json -Depth 6) | Set-Content -Path $stateFile -Encoding UTF8 }
function Get-SentKeys { param($State) @($State.records | ForEach-Object { $_.key }) }

$state = Read-BriefState
$sentKeys = Get-SentKeys -State $state

# --- Compute window ----------------------------------------------------------
if ($Date) {
    try { $anchor = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "Invalid -Date '$Date'. Expected yyyy-MM-dd." }
} else { $anchor = (Get-Date) }

if ($Mode -eq 'weekly') {
    $win = Get-WeeklyWindow -Anchor $anchor -Tz $tz
    $key = "week-" + $win.StartLocal.ToString('yyyy-MM-dd')
    $rangeLabel = "{0} &ndash; {1}" -f $win.StartLocal.ToString('MMM d'), $win.EndLocal.ToString('MMM d, yyyy')
    $rangeLabelPlain = "{0} - {1}" -f $win.StartLocal.ToString('MMM d'), $win.EndLocal.ToString('MMM d')
} else {
    $target = $anchor.Date
    $coverStart = $target
    if (-not $Force) {
        # Backfill: cover from the day after the most recent sent date, capped to 7 days.
        $sentDates = @($state.records | Where-Object { $_.key -like 'day-*' } | ForEach-Object { try { [datetime]::ParseExact(($_.key -replace '^day-',''),'yyyy-MM-dd',[System.Globalization.CultureInfo]::InvariantCulture) } catch {} })
        if ($sentDates.Count -gt 0) {
            $maxSent = ($sentDates | Sort-Object | Select-Object -Last 1)
            $cand = $maxSent.AddDays(1)
            if ($cand -lt $coverStart) { $coverStart = $cand }
        }
        $earliest = $target.AddDays(-6)
        if ($coverStart -lt $earliest) { $coverStart = $earliest }
    }
    $win = Get-DailyWindow -TargetDate $target -CoverStart $coverStart -Tz $tz
    $key = "day-" + $target.ToString('yyyy-MM-dd')
    if ($win.StartLocal -eq $win.EndLocal) {
        $rangeLabel = $win.EndLocal.ToString('dddd, MMM d, yyyy')
        $rangeLabelPlain = $win.EndLocal.ToString('MMM d')
    } else {
        $rangeLabel = "{0} &ndash; {1}" -f $win.StartLocal.ToString('MMM d'), $win.EndLocal.ToString('MMM d, yyyy')
        $rangeLabelPlain = "{0} - {1}" -f $win.StartLocal.ToString('MMM d'), $win.EndLocal.ToString('MMM d')
    }
}
Write-Log "Window: [$($win.StartUtc.ToString('o')) .. $($win.EndUtc.ToString('o'))) covering dates: $($win.Dates -join ', '). key=$key"

if (($sentKeys -contains $key) -and -not $Force -and -not $DryRun -and -not $NoEmail) {
    Write-Log "Already sent for key=$key (state). Use -Force to resend. Exiting."
    return
}

# --- Enrichment (per-person Teams/email highlights + weekly summaries) --------
# Sourced from WorkIQ. Stored as state/enrichment.json: { generated_at, people: {
#   <alias>: { daily: "<one-day highlight>", weekly: "<week accomplishments>" } } }.
# Read-only here; population is done by the -Enrich step (or by the agent ad-hoc).
$enrichFile = Join-Path $stateDir 'enrichment.json'
if ($Enrich) {
    try {
        Write-Log "Enrich: refreshing enrichment.json via WorkIQ (mode=$Mode)..."
        & (Join-Path $skillDir 'enrich.ps1') -Mode $Mode -Dates $win.Dates -RangeLabelPlain $rangeLabelPlain -DirectsContext $directsCtx -OutFile $enrichFile -LogFile $logFile
    } catch { Write-Log "WARN: enrichment refresh failed - $($_.Exception.Message). Falling back to existing cache." }
}
$enrichMap = @{}
if (Test-Path $enrichFile) {
    try {
        $ej = Get-Content $enrichFile -Raw | ConvertFrom-Json
        $src = if ($ej.people) { $ej.people } else { $ej }
        foreach ($prop in $src.PSObject.Properties) {
            $enrichMap[$prop.Name] = @{ daily = [string]$prop.Value.daily; weekly = [string]$prop.Value.weekly }
        }
        Write-Log "Loaded enrichment for $($enrichMap.Keys.Count) people (generated $($ej.generated_at))."
    } catch { Write-Log "WARN: failed to read enrichment.json - $_" }
} else {
    Write-Log "No enrichment.json present - highlights/weekly summaries fall back to local signal."
}

# --- Gather + render ---------------------------------------------------------
$data = Get-TeamBriefData -Directs $directs -PeopleDir $peopleDir -StartUtc $win.StartUtc -EndUtc $win.EndUtc -Dates $win.Dates -Enrichment $enrichMap
Write-Log "Data: activePeople=$($data.ActivePeopleCount)/$($data.AliasCount) prsOpened=$($data.PrsAuthoredUnique) prsReviewed=$($data.PrsReviewedUnique) personasImported=$($data.PersonasImported)"

$dailyJokes = @(
    "Fourteen inboxes summarized and nobody's asked yet why their manager's agent reads their PRs at dinnertime.",
    "If 'absence of signal' counted as a deliverable, this team would be shipping daily.",
    "I counted the PRs so you don't have to pretend you read all the diffs.",
    "Your directs closed more tabs today than I did parsing their persona files - and that's saying something."
)
$weeklyJokes = @(
    "A week's worth of work compressed into one email - the only thing more efficient was the PR that 'fixed a typo' and touched 40 files.",
    "Highlights of the week, minus the three-hour thread about where to put the curly brace.",
    "If shipping were measured in Teams emojis, this would be a record quarter.",
    "I summarized the whole work week in one screen - which is one more screen than most retros manage."
)

if ($Mode -eq 'weekly') {
    $joke = $weeklyJokes | Get-Random
    $spec = Build-WeeklyBriefSpec -Data $data -RangeLabel $rangeLabel -ContextGeneratedLabel $ctxGenLabel -Joke $joke -TotalDirects $totalDirects
    $subject = "$(Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]') Weekly team highlights - week of $rangeLabelPlain"
} else {
    $joke = $dailyJokes | Get-Random
    $spec = Build-DailyBriefSpec -Data $data -RangeLabel $rangeLabel -ContextGeneratedLabel $ctxGenLabel -Joke $joke -TotalDirects $totalDirects
    $subject = "$(Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]') Team brief - $rangeLabelPlain"
}

$html = Build-InvestigationEmailHtml -Spec $spec
$sig  = Get-NirvanaSignature -Variant Default
$html = Add-SignatureBeforeBodyClose -Html $html -Signature $sig

$previewFile = Join-Path $outDir ("$Mode-" + $win.EndLocal.ToString('yyyy-MM-dd') + ".html")
$html | Set-Content -Path $previewFile -Encoding UTF8
Write-Log "Rendered preview -> $previewFile"
if ($Preview) { try { Start-Process $previewFile } catch {} }

if ($DryRun) { Write-Log "DryRun: no send, no state advance. Done."; return }
if ($NoEmail) { Write-Log "NoEmail: rendered + logged, no send, no state advance. Done."; return }

# --- Send (Outlook COM, mirrors email-team recipe) ---------------------------
$recipient = Get-AgentField -Path 'manager.email' -Default 'you@example.com'

if (Test-MigrationMode) {
    Write-Log "Migration mode active - skipping send (subject: $subject). State NOT advanced."
    return
}

$sent = $false
$ol = $null; $mail = $null
try {
    $ol = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    $mail.To = $recipient
    $mail.Subject = $subject
    $mail.HTMLBody = $html
    $mail.Send() | Out-Null
    $sent = $true
    Write-Log "Sent to $recipient (subject: $subject)."
} catch {
    Write-Log "WARN: send failed - $($_.Exception.Message). State NOT advanced."
} finally {
    if ($mail) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) }
    if ($ol)   { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) }
}

# Log to reports/email/YYYY-MM-DD.md (same audit trail as other senders).
if ($sent) {
    try {
        $emailLogDir = Join-Path $AgentRoot 'reports\email'
        New-Item -ItemType Directory -Force -Path $emailLogDir | Out-Null
        $emailLog = Join-Path $emailLogDir ((Get-Date).ToString('yyyy-MM-dd') + '.md')
        Add-Content -Path $emailLog -Value ("- {0} | team-brief ({1}) -> {2} | {3}" -f (Get-Date).ToString('HH:mm'), $Mode, $recipient, $subject)
    } catch { Write-Log "WARN: email audit log failed - $_" }

    # Advance state only on successful send.
    $rec = [pscustomobject]@{
        key = $key; mode = $Mode; sent_at = (Get-Date).ToString('o')
        covered_dates = $win.Dates; source_generated_at = [string]$ctx.generated_at
        active_people = $data.ActivePeopleCount; prs_opened = $data.PrsAuthoredUnique
    }
    $records = @($state.records | Where-Object { $_.key -ne $key })
    $records += $rec
    $state = [pscustomobject]@{ records = $records }
    Write-BriefState -State $state
    Write-Log "State advanced for key=$key."
}

Write-Log "team-brief complete. mode=$Mode sent=$sent"

