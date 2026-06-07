# Pre-meeting Team Open Discussions Agenda reminder for the wider team.
#
# Parses reports/team-agenda/open-discussions.md, extracts Open items, and
# emails the team (team@) the agenda so they walk into the Team Meeting with
# the open items fresh in mind. Runtime-confirms the meeting exists in Outlook
# before sending - if the meeting is cancelled or moved off the expected
# day/time, the runner exits cleanly without spamming the team.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-team-meeting-reminder.ps1
# Flags:
#   -DryRun         compute + log + write a preview HTML, do not send
#   -PreviewOnly    send only to Nir (not the team) - for one-off smoke tests
#   -Force          bypass the meeting-presence check AND per-instance idempotency
#   -MeetingSubject override the subject to match (default: "Team Meeting")
#   -LookAheadMin   how far into the future to look for the meeting (default 60)
#
# Scheduled by:  DM-TeamMeetingReminder (weekly, Tuesdays 14:00 IST - 30 min before
#                the recurring "Team Meeting" at 14:30).
# Per-meeting-instance idempotency: state\team-meeting-sent.txt stores the
# ISO timestamp of every meeting instance we have already emailed about.

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $PreviewOnly,
    [switch] $Force,
    [string] $MeetingSubject = 'Team Meeting',
    [int]    $LookAheadMin = 60,
    # Override "now" for testing. Format: any DateTime-parseable string.
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$agendaFile = Resolve-AgentPath (Join-Path (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) 'team-agenda\open-discussions.md') -Config $AgentConfig
$skillDir   = Join-Path $AgentRoot '.copilot\skills\team-agenda'
$stateFile  = Join-Path $skillDir 'state\team-meeting-sent.txt'
$previewFile= Join-Path $skillDir 'state\team-meeting-preview.html'

New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
$logFile = Join-Path $LogDir ("team-meeting-reminder-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$teamAlias     = Get-AgentField -Path 'team.alias'                -Default 'team'                    -Config $AgentConfig
$teamEmail     = "$someone@example.com"
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# HTML-escape user-provided text so titles like "IReadOnlyCollection<T>" don't
# get silently swallowed by Outlook's HTML parser. Then upgrade inline markdown
# backticks (`x`) to <code>x</code> for readability.
function Format-Field {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $h = [System.Net.WebUtility]::HtmlEncode($Text)
    # Convert paired backticks to <code>...</code>. Use a non-greedy match and
    # require at least one char between the ticks so we don't eat `` (empty).
    return [System.Text.RegularExpressions.Regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
}

# --- Parse agenda file (mirrors run-team-agenda-reminder.ps1) -------------
function Get-AgendaItems {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "Agenda file not found at $Path. Nothing to remind."
        return @()
    }

    $lines = Get-Content -Path $Path -Encoding UTF8

    $items = New-Object System.Collections.Generic.List[object]
    $current = $null
    $section = 'preamble'
    $headingRe = '^###\s+(TA-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$'
    $fieldRe   = '^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$'
    $lastKey = $null
    $multilineKeys = @('summary', 'next step')

    foreach ($raw in $lines) {
        if ($raw -match '^##\s+Open\b')   { if ($current) { $items.Add($current); $current = $null } ; $section = 'open'   ; $lastKey = $null ; continue }
        if ($raw -match '^##\s+Closed\b') { if ($current) { $items.Add($current); $current = $null } ; $section = 'closed' ; $lastKey = $null ; continue }
        if ($raw -match $headingRe) {
            if ($current) { $items.Add($current) }
            $current = [pscustomobject]@{
                Id       = $matches[1]
                Title    = $matches[2]
                Section  = $section
                Status   = ''
                Kind     = ''
                OpenedBy = ''
                OpenedOn = ''
                Owner    = ''
                Summary  = ''
                NextStep = ''
                ClosedOn = ''
            }
            $lastKey = $null
            continue
        }
        if ($current -and $raw -match $fieldRe) {
            $k = $matches['key'].Trim().ToLower()
            $v = $matches['value'].Trim()
            switch ($k) {
                'status'     { $current.Status   = $v }
                'kind'       { $current.Kind     = $v }
                'opened by'  { $current.OpenedBy = $v }
                'opened on'  { $current.OpenedOn = $v }
                'owner'      { $current.Owner    = $v }
                'summary'    { $current.Summary  = $v }
                'next step'  { $current.NextStep = $v }
                'closed on'  { $current.ClosedOn = $v }
            }
            $lastKey = $k
            continue
        }
        # Continuation line of a multi-line field (raw wrapped line, no bullet).
        if ($current -and $lastKey -and ($multilineKeys -contains $lastKey)) {
            $t = $raw.Trim()
            if ($t -eq '' -or $t -match '^#' -or $t -match '^---') {
                $lastKey = $null
            } else {
                switch ($lastKey) {
                    'summary'   { $current.Summary  = if ($current.Summary)  { $current.Summary  + "`n" + $t } else { $t } }
                    'next step' { $current.NextStep = if ($current.NextStep) { $current.NextStep + "`n" + $t } else { $t } }
                }
            }
        }
    }
    if ($current) { $items.Add($current) }

    return ,@($items.ToArray())
}

# --- Find next Team Meeting in Outlook ------------------------------------
function Get-NextTeamMeeting {
    param(
        [string]$Subject,
        [int]   $WithinMin,
        [DateTime]$Now
    )

    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    $_ensureLog = Join-Path $LogDir 'ensure-outlook.log'
    if (-not (Ensure-OutlookRunning -LogFile $_ensureLog)) {
        Write-Log "Outlook not running and could not be started. Cannot resolve meeting."
        return $null
    }

    $ol  = New-Object -ComObject Outlook.Application
    $ns  = $ol.GetNamespace('MAPI')
    $cal = $ns.GetDefaultFolder(9)
    $items = $cal.Items
    $items.Sort('[Start]')
    $items.IncludeRecurrences = $true

    $end = $Now.AddMinutes($WithinMin)
    $restrict = "[Start] >= '{0}' AND [Start] <= '{1}'" -f $Now.ToString('g'), $end.ToString('g')
    $found = $items.Restrict($restrict)

    $best = $null
    foreach ($a in $found) {
        # Exact subject match (case-insensitive). Guards against e.g.
        # "ILDC Kusto quarterly Team meeting" picking up "Team Meeting".
        if ($a.Subject -ieq $Subject) {
            if ($null -eq $best -or $a.Start -lt $best.Start) { $best = $a }
        }
    }

    if ($null -eq $best) { return $null }

    return [pscustomobject]@{
        Start     = $best.Start
        End       = $best.End
        Subject   = $best.Subject
        Organizer = $best.Organizer
        IdKey     = $best.Start.ToString('o')
    }
}

# --- Main -----------------------------------------------------------------
$now = if ($AsOfDate) { [DateTime]::Parse($AsOfDate) } else { Get-Date }

$allItems  = Get-AgendaItems -Path $agendaFile
$openItems = @($allItems | Where-Object {
    $_.Section -eq 'open' -and ($_.Status -ieq 'open' -or [string]::IsNullOrWhiteSpace($_.Status))
})
Write-Log "Parsed $($allItems.Count) item(s) total; $($openItems.Count) open."

$nextMeeting = Get-NextTeamMeeting -Subject $MeetingSubject -WithinMin $LookAheadMin -Now $now

if (-not $nextMeeting) {
    if ($Force) {
        Write-Log "No '$MeetingSubject' found in next $LookAheadMin min, but -Force set; proceeding with synthetic meeting context."
    } else {
        Write-Log "No '$MeetingSubject' found in next $LookAheadMin min. Skipping (use -Force to override)."
        return
    }
} else {
    Write-Log "Found '$MeetingSubject' at $($nextMeeting.Start.ToString('o')) (organizer: $($nextMeeting.Organizer))."
}

# Skip-when-empty: don't spam the team with a "no items" email.
if ($openItems.Count -eq 0 -and -not $Force) {
    Write-Log "Zero open items on the agenda. Skipping team email (use -Force to send empty-state notice)."
    return
}

# Per-meeting-instance idempotency.
if ($nextMeeting -and -not $Force -and (Test-Path $stateFile)) {
    $sentKeys = @(Get-Content $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($sentKeys -contains $nextMeeting.IdKey) {
        Write-Log "Already sent for meeting instance $($nextMeeting.IdKey). Skipping."
        return
    }
}

# --- Build email ----------------------------------------------------------
. (Join-Path $skillDir 'render.ps1')

$count  = $openItems.Count
$plural = if ($count -eq 1) { 'item' } else { 'items' }
$tail   = Format-AgendaSubjectTail -Items $openItems

if ($nextMeeting) {
    $mtgWhen  = $nextMeeting.Start.ToString('dddd HH:mm')
    $minsAway = [int][Math]::Round(($nextMeeting.Start - $now).TotalMinutes)
    $minsCopy = if ($minsAway -le 0) { 'about to start' } elseif ($minsAway -eq 1) { 'in 1 minute' } else { "in $minsAway minutes" }
    $openerLead = "Team Meeting $minsCopy ($mtgWhen)."
} else {
    $openerLead = "Team Meeting reminder (forced send - no scheduled instance found)."
}

if ($count -gt 0) {
    $opener = "<p>$openerLead $count open $plural on the agenda, split below.</p>"
} else {
    $opener = "<p>$openerLead Agenda is empty - nothing tracked this week.</p>"
}

$tables = ''
if ($count -gt 0) {
    $tables = Render-TwoTableAgenda -Items $openItems
}

$footer = "<p style='color:#666;font-size:12px;margin-top:14px'>Source: <code>reports/team-agenda/open-discussions.md</code>. To raise something for a future meeting, ping Nir.</p>"

# Jokes - tame, team-safe, light Nirvana flavor on a couple. ASCII-only source per PS-encoding rule.
$jokes = @(
    "30 minutes, $count $plural. The math is optimistic.",
    "Agenda's open. So is the floor.",
    "If we close one today, the list might forgive us by next week.",
    "List status: open. Mood: incrementally less open.",
    "Come as you are - bring an opinion.",
    "Tuesday 14:30: the slot where 'we should discuss this' goes to either land or linger."
)
$joke = $jokes | Get-Random
$jokeHtml = "<p style='color:#555;font-style:italic;margin-top:14px'>$joke</p>"

. (Join-Path $PSScriptRoot '_shared\signature.ps1')
$signature = Get-NirvanaSignature

$html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
        $opener +
        $tables +
        $footer +
        $jokeHtml +
        $signature +
        "</body></html>"

# Recipients
$to = if ($PreviewOnly) { $mgrEmail } else { $teamEmail }

# Subject (avoid HTML entities in the Subject field; some clients render literal text).
if ($PreviewOnly) {
    $subject = "$subjectPrefix [PREVIEW] Team Meeting in 30 min - $tail"
} else {
    $subject = "$subjectPrefix Team Meeting in 30 min - $tail"
}

Write-Log "To: $to | Subject: $subject"

# Always write the preview HTML (handy for debugging even on real sends).
[System.IO.File]::WriteAllText($previewFile, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Log "Preview HTML written to $previewFile"

if ($DryRun) {
    Write-Log "DryRun set - skipping send."
    return
}

# --- Send via Outlook COM -------------------------------------------------
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')

try {
    $ol   = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    $mail.To       = $to
    $mail.Subject  = $subject
    $mail.HTMLBody = $html
    if (Test-MigrationMode) {
        Write-Log "  [migration-mode] Skipping Send() for: $subject"
    } else {
        $mail.Send() | Out-Null
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
    Write-Log "Sent."

    # Stamp idempotency only for real sends to the real team (not previews / forced no-meeting runs).
    if ($nextMeeting -and -not $PreviewOnly) {
        Add-Content -Path $stateFile -Value $nextMeeting.IdKey -Encoding UTF8
    }
}
catch {
    Write-Log "  WARN: email send failed: $($_.Exception.Message). email=skipped:$($_.Exception.GetType().Name)"
    return
}

