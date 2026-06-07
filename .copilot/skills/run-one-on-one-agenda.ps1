# Pre-1:1 agenda reminder. Polls every 5 min via DM-OneOnOneAgenda.
#
# What it does (every tick):
#   1. Scans reports/one-on-ones/*.md
#   2. Parses each file for open ON-NNN items
#   3. For every file with >= 1 open item, queries Outlook for any meeting
#      starting in the next $LookAheadMin minutes whose subject contains the
#      person's name (from the file header) AND a 1:1 indicator
#      (1x1 / 1:1 / 1-on-1 / 1on1 / one-on-one / 1 on 1).
#   4. Fires exactly one email to Nir per matching meeting instance,
#      $OffsetMin minutes before it starts. State stamp prevents re-fires.
#
# Auto-extends to any new 1:1 partner: drop a new file at
# reports/one-on-ones/<slug>.md with the right header and items, done.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .copilot\skills\run-one-on-one-agenda.ps1
# Flags:
#   -DryRun       parse + match + log + write preview HTML, do NOT send
#   -Force        bypass per-meeting-instance idempotency
#   -LookAheadMin how far ahead to scan Outlook (default 35 = 30 + 5-min poll slack)
#   -OffsetMin    fire when meeting is <= N min away (default 30)
#   -AsOfDate     override "now" for testing (any DateTime-parseable string)
#
# Scheduled by:  DM-OneOnOneAgenda (every 5 min, 24/7).
# Per-meeting-instance idempotency:
#   .copilot/skills/one-on-one-agenda/state/sent-instances.txt
#   One line per "<slug>:<start.ToString('o')>".
#
# ASCII-only source on purpose (PS 5.1 parses .ps1 via CP1252).

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [int]    $LookAheadMin = 35,
    [int]    $OffsetMin    = 30,
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$reportsRoot   = Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig
$agendaDir     = Resolve-AgentPath (Join-Path $reportsRoot 'one-on-ones') -Config $AgentConfig
$skillDir      = Join-Path $AgentRoot '.copilot\skills\one-on-one-agenda'
$teamAgendaDir = Join-Path $AgentRoot '.copilot\skills\team-agenda'
$stateFile     = Join-Path $skillDir 'state\sent-instances.txt'
$previewFile   = Join-Path $skillDir 'state\preview.html'
$lockFile      = Join-Path $LogDir   'one-on-one-agenda.lock'

New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
$logFile = Join-Path $LogDir ("one-on-one-agenda-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

. (Join-Path $skillDir 'parser.ps1')

$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ---- single-instance lock --------------------------------------------------
function Acquire-Lock {
    if (Test-Path $lockFile) {
        $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
        if ($age.TotalMinutes -lt 15) {
            Write-Log "another instance holds the lock (age $([int]$age.TotalSeconds)s) - exiting." 'warn'
            return $false
        }
        Write-Log "stale lock (age $([int]$age.TotalMinutes)m) - clearing." 'warn'
        Remove-Item $lockFile -Force
    }
    "$PID" | Set-Content -Path $lockFile -Encoding ASCII
    return $true
}
function Release-Lock { if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue } }

# ---- Outlook calendar scan -----------------------------------------------
function Get-UpcomingMeetings {
    param([DateTime]$Now, [int]$WithinMin)

    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    $_ensureLog = Join-Path $LogDir 'ensure-outlook.log'
    if (-not (Ensure-OutlookRunning -LogFile $_ensureLog)) {
        Write-Log "Outlook not running; cannot resolve meetings." 'warn'
        return @()
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

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($a in $found) {
        $out.Add([pscustomobject]@{
            Start     = $a.Start
            End       = $a.End
            Subject   = "$($a.Subject)"
            Organizer = "$($a.Organizer)"
        })
    }
    return ,@($out.ToArray())
}

# ---- Main ----------------------------------------------------------------
if (-not (Acquire-Lock)) { exit 0 }

try {
    $now = if ($AsOfDate) { [DateTime]::Parse($AsOfDate) } else { Get-Date }

    if (-not (Test-Path $agendaDir)) {
        Write-Log "Agenda dir not found at $agendaDir; nothing to do."
        return
    }

    $agendaFiles = @(Get-ChildItem -Path $agendaDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($agendaFiles.Count -eq 0) {
        Write-Log "No 1:1 agenda files in $agendaDir."
        return
    }

    # Build the per-person open-items map.
    $peopleWithOpen = New-Object System.Collections.Generic.List[object]
    foreach ($f in $agendaFiles) {
        $slug      = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $allItems  = Get-OneOnOneItems -Path $f.FullName
        $openItems = @($allItems | Where-Object {
            $_.Section -eq 'open' -and ($_.Status -ieq 'open' -or [string]::IsNullOrWhiteSpace($_.Status))
        })
        if ($openItems.Count -eq 0) { continue }
        $personLabel = Get-PersonLabel -Path $f.FullName
        $peopleWithOpen.Add([pscustomobject]@{
            Slug      = $slug
            Path      = $f.FullName
            Person    = $personLabel
            OpenItems = $openItems
        })
    }

    if ($peopleWithOpen.Count -eq 0) {
        Write-Log "No 1:1 files have open ON-NNN items. Nothing to fire."
        return
    }

    $peopleSummary = ($peopleWithOpen | ForEach-Object { "$($_.Person)($($_.OpenItems.Count))" }) -join ', '
    Write-Log ("Scanning Outlook for 1:1s in next $LookAheadMin min covering: $peopleSummary")

    $meetings = Get-UpcomingMeetings -Now $now -WithinMin $LookAheadMin
    if ($meetings.Count -eq 0) {
        Write-Log "No meetings in the next $LookAheadMin min."
        return
    }

    # Existing sent-instance keys.
    $sentKeys = @()
    if (Test-Path $stateFile) {
        $sentKeys = @(Get-Content $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    }

    # Match meetings to people. Each meeting matches at most one person
    # (first hit wins; deterministic order = directory-sort of files).
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($p in $peopleWithOpen) {
        foreach ($m in $meetings) {
            if (-not (Test-Is1on1MeetingForPerson -Subject $m.Subject -PersonToken $p.Person)) { continue }
            $minsAway = ($m.Start - $now).TotalMinutes
            if ($minsAway -gt $OffsetMin) { continue }   # too early
            if ($minsAway -lt -1)         { continue }   # already started
            $idKey = "{0}:{1}" -f $p.Slug, $m.Start.ToString('o')
            if (-not $Force -and ($sentKeys -contains $idKey)) {
                Write-Log "Already sent for $idKey; skipping."
                continue
            }
            $jobs.Add([pscustomobject]@{
                Person   = $p
                Meeting  = $m
                IdKey    = $idKey
                MinsAway = [int][Math]::Round($minsAway)
            })
        }
    }

    if ($jobs.Count -eq 0) {
        Write-Log "No matching meetings within $OffsetMin min that haven't already been emailed."
        return
    }

    . (Join-Path $teamAgendaDir 'render.ps1')
    . (Join-Path $PSScriptRoot '_shared\signature.ps1')
    . (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')

    foreach ($j in $jobs) {
        $person  = $j.Person.Person
        $slug    = $j.Person.Slug
        $items   = $j.Person.OpenItems
        $count   = $items.Count
        $plural  = if ($count -eq 1) { 'item' } else { 'items' }
        $tail    = Format-AgendaSubjectTail -Items $items
        $mins    = $j.MinsAway
        $minsCopy = if ($mins -le 0) { 'about to start' } elseif ($mins -eq 1) { 'in 1 minute' } else { "in $mins minutes" }
        $mtgWhen = $j.Meeting.Start.ToString('dddd HH:mm')

        $opener = "<p>1:1 with <strong>$([System.Net.WebUtility]::HtmlEncode($person))</strong> $minsCopy ($mtgWhen). $count open $plural on the agenda, split below.</p>"
        $tables = Render-TwoTableAgenda -Items $items
        $footer = "<p style='color:#666;font-size:12px;margin-top:14px'>Source: <code>reports/one-on-ones/$slug.md</code>. To add or close items, ask me.</p>"

        $jokes = @(
            "30 minutes, $count $plural. Bring the headlines, save the lore for next time.",
            "Less monologue, more decision - the calendar's voting.",
            "Open list, open mic.",
            "If we close one today, the file might forgive us by tomorrow.",
            "Status: open. Mood: incrementally less open."
        )
        $joke = $jokes | Get-Random
        $jokeHtml = "<p style='color:#555;font-style:italic;margin-top:14px'>$joke</p>"

        $signature = Get-NirvanaSignature

        $html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
                $opener + $tables + $footer + $jokeHtml + $signature +
                "</body></html>"

        $subject = "$subjectPrefix 1:1 with $person in $mins min - $tail"

        Write-Log "To: $mgrEmail | Subject: $subject"
        [System.IO.File]::WriteAllText($previewFile, $html, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "Preview HTML written to $previewFile"

        if ($DryRun) {
            Write-Log "DryRun - skipping send for $($j.IdKey)."
            continue
        }

        try {
            $ol   = New-Object -ComObject Outlook.Application
            $mail = $ol.CreateItem(0)
            $mail.To       = $mgrEmail
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

            Add-Content -Path $stateFile -Value $j.IdKey -Encoding UTF8
        }
        catch {
            Write-Log "  WARN: email send failed: $($_.Exception.Message). email=skipped:$($_.Exception.GetType().Name)" 'warn'
        }
    }
}
finally {
    Release-Lock
}

