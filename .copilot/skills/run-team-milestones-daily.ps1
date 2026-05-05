# Daily team-milestones reminder.
#
# Scans .copilot/skills/team-personas/people/*.md Employment blocks for
# birthdays and work anniversaries falling on today or tomorrow (local time),
# and emails Nir a short heads-up. Silent on empty days.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-team-milestones-daily.ps1
# Flags:
#   -DryRun    compute + log, do not send
#   -Force     bypass per-day idempotency check
# Scheduled by:  DM-TeamMilestonesDaily (daily 00:00, every 10 min for 24h).
# Per-day idempotency: state\last-sent.txt prevents duplicate sends.

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    # Override "today" for testing. Format: YYYY-MM-DD.
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$peopleDir = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$skillDir  = Join-Path $AgentRoot '.copilot\skills\team-milestones'
$stateFile = Join-Path $skillDir 'state\last-sent.txt'

New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
$logFile = Join-Path $LogDir ("team-milestones-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

# Config-driven values for email composition
$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Parse persona Employment blocks --------------------------------------

function Get-EmploymentDates {
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8

    # Display name: first H1 line, strip any prefix tag and any suffix descriptor.
    # Handles both proper em-dash (U+2014) and the legacy mojibake "â€"" sequence.
    $name = $null
    if ($content -match '(?m)^#\s+(.+?)\s*$') {
        $name = $matches[1]
        # Strip leading "Working-Style Persona:" / "Working Persona:" prefix.
        $name = $name -replace '^\s*(Working[\s-]?Style|Working)\s+Persona\s*:\s*', ''
        # Strip trailing " <separator> Persona" / " <separator> Working[-]Style Persona" suffix
        # where <separator> is any run of non-alphanumeric characters (covers --, em-dash,
        # en-dash, "â€"" mojibake, etc.).
        $name = $name -replace '\s+[^A-Za-z0-9]+\s*(Working[\s-]?Style\s+Persona|Working\s+Persona|Persona).*$', ''
        $name = $name.Trim()
    }
    if (-not $name) { $name = [System.IO.Path]::GetFileNameWithoutExtension($Path) }

    $bday = $null; $hired = $null
    if ($content -match '(?m)^\s*-\s*\*\*Birthday:\*\*\s*([0-9]{1,2})\s*/\s*([0-9]{1,2})\s*$') {
        # Persona files use MM/DD (e.g., 4/15 = April 15).
        $bday = [pscustomobject]@{ Month = [int]$matches[1]; Day = [int]$matches[2] }
    }
    if ($content -match '(?m)^\s*-\s*\*\*Hired:\*\*\s*([0-9]{4})-([0-9]{2})-([0-9]{2})\s*$') {
        $hired = (Get-Date -Year ([int]$matches[1]) -Month ([int]$matches[2]) -Day ([int]$matches[3]) -Hour 0 -Minute 0 -Second 0).Date
    }

    return [pscustomobject]@{
        Name    = $name
        File    = $Path
        Birthday = $bday
        Hired    = $hired
    }
}

function Test-DateMatch {
    # Returns $true when (recurring M/D) matches $target's day/month.
    # Handles Feb 29 fallback: in non-leap years, treat Feb 29 as Feb 28.
    param(
        [int]$Day, [int]$Month, [DateTime]$Target
    )
    $tDay = $Target.Day; $tMonth = $Target.Month
    if ($Month -eq 2 -and $Day -eq 29) {
        $isLeap = [DateTime]::IsLeapYear($Target.Year)
        if (-not $isLeap) {
            return ($tMonth -eq 2 -and $tDay -eq 28)
        }
    }
    return ($tMonth -eq $Month -and $tDay -eq $Day)
}

# --- Build event list -----------------------------------------------------

$today    = if ($AsOfDate) { [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null).Date } else { (Get-Date).Date }
$tomorrow = $today.AddDays(1)

$personas = Get-ChildItem -Path $peopleDir -Filter '*.md' -File
Write-Log "Scanning $($personas.Count) persona file(s) for $($today.ToString('ddd, MMM dd, yyyy')) and $($tomorrow.ToString('ddd, MMM dd, yyyy'))."

$todayEvents = @()
$tomorrowEvents = @()

foreach ($p in $personas) {
    try {
        $info = Get-EmploymentDates -Path $p.FullName
    } catch {
        Write-Log "  WARN: failed to parse $($p.Name): $($_.Exception.Message)"
        continue
    }

    foreach ($when in @(@{Date=$today;Bucket='Today'}, @{Date=$tomorrow;Bucket='Tomorrow'})) {
        $target = $when.Date
        $bucket = $when.Bucket

        if ($info.Birthday -and (Test-DateMatch -Day $info.Birthday.Day -Month $info.Birthday.Month -Target $target)) {
            $evt = [pscustomobject]@{
                Person = $info.Name; Type = 'Birthday'; Years = $null
                Hired  = $info.Hired; Date = $target; Bucket = $bucket
            }
            if ($bucket -eq 'Today') { $todayEvents += $evt } else { $tomorrowEvents += $evt }
        }

        if ($info.Hired -and (Test-DateMatch -Day $info.Hired.Day -Month $info.Hired.Month -Target $target)) {
            $years = $target.Year - $info.Hired.Year
            if ($years -ge 1) {
                $evt = [pscustomobject]@{
                    Person = $info.Name; Type = 'Work anniversary'; Years = $years
                    Hired  = $info.Hired; Date = $target; Bucket = $bucket
                }
                if ($bucket -eq 'Today') { $todayEvents += $evt } else { $tomorrowEvents += $evt }
            }
        }
    }
}

$todayEvents    = @($todayEvents    | Sort-Object Person, Type)
$tomorrowEvents = @($tomorrowEvents | Sort-Object Person, Type)

Write-Log "Found: today=$($todayEvents.Count), tomorrow=$($tomorrowEvents.Count)."

if ($todayEvents.Count -eq 0 -and $tomorrowEvents.Count -eq 0) {
    Write-Log "Nothing to announce. Exiting silently."
    return
}

# --- Idempotency: skip if we already sent the same fingerprint today ------

$fingerprintParts = @()
foreach ($e in $todayEvents)    { $fingerprintParts += "T|$($e.Person)|$($e.Type)|$($e.Years)" }
foreach ($e in $tomorrowEvents) { $fingerprintParts += "M|$($e.Person)|$($e.Type)|$($e.Years)" }
$fingerprint = ($fingerprintParts -join ';')

$todayKey = $today.ToString('yyyy-MM-dd')
$alreadySent = $false
if (-not $Force -and (Test-Path $stateFile)) {
    $existing = Get-Content $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $existing) {
        if ($line -like "$todayKey`t*") {
            $existingFp = ($line -split "`t", 2)[1]
            if ($existingFp -eq $fingerprint) {
                $alreadySent = $true
                break
            }
        }
    }
}

if ($alreadySent) {
    Write-Log "Same fingerprint already sent today ($todayKey). Skipping. Use -Force to override."
    return
}

# --- Build email ----------------------------------------------------------

function Format-EventLi($e) {
    if ($e.Type -eq 'Birthday') {
        $hiredHint = ''
        return "<li><strong>$($e.Person)</strong> &mdash; Birthday &#127874;$hiredHint</li>"
    } else {
        $yLabel = if ($e.Years -eq 1) { '1-year' } else { "$($e.Years)-year" }
        $hiredStr = $e.Hired.ToString('yyyy-MM-dd')
        return "<li><strong>$($e.Person)</strong> &mdash; $yLabel work anniversary (hired $hiredStr)</li>"
    }
}

$bodyHtml = ''

if ($todayEvents.Count -gt 0) {
    $hdr = "Today ($($today.ToString('ddd, MMM dd'))) &mdash; $($todayEvents.Count) milestone$(if ($todayEvents.Count -ne 1){'s'}):"
    $bodyHtml += "<p>$hdr</p><ul>"
    foreach ($e in $todayEvents) { $bodyHtml += (Format-EventLi $e) }
    $bodyHtml += "</ul>"
}

if ($tomorrowEvents.Count -gt 0) {
    $hdr = "Tomorrow heads-up ($($tomorrow.ToString('ddd, MMM dd'))) &mdash; $($tomorrowEvents.Count) milestone$(if ($tomorrowEvents.Count -ne 1){'s'}):"
    $bodyHtml += "<p>$hdr</p><ul>"
    foreach ($e in $tomorrowEvents) { $bodyHtml += (Format-EventLi $e) }
    $bodyHtml += "</ul>"
}

# Joke pool - on-topic for milestones / time / cache.
$jokes = @(
    "Today's hot cache; tomorrow's heads-up so the cake doesn't end up in cold storage.",
    "Catching this before it shows up as `summarize count() by missed_milestone`.",
    "Ingestion latency on these is one day. Don't .alter the SLA.",
    "The follower cluster of good intentions is healthy &mdash; your card just needs to mv-expand to action.",
    "Filed under: things that beat a belated Teams DM."
)
$joke = $jokes | Get-Random
$bodyHtml += "<p style=`"color:#555;font-style:italic;margin-top:14px`">$joke</p>"

# Subject
$todayNames    = ($todayEvents    | ForEach-Object { $_.Person } | Select-Object -Unique) -join ', '
$tomorrowNames = ($tomorrowEvents | ForEach-Object { $_.Person } | Select-Object -Unique) -join ', '

if ($todayEvents.Count -gt 0 -and $tomorrowEvents.Count -gt 0) {
    $subject = "$subjectPrefix Team milestones - today: $todayNames; tomorrow: $tomorrowNames"
} elseif ($todayEvents.Count -gt 0) {
    $subject = "$subjectPrefix Team milestones today: $todayNames"
} else {
    $subject = "$subjectPrefix Team milestones tomorrow heads-up: $tomorrowNames"
}

# Default signature (user-facing content, NOT a runner heartbeat).
. (Join-Path $PSScriptRoot '_shared\signature.ps1')
$signature = Get-NirvanaSignature

$html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
        $bodyHtml +
        $signature +
        "</body></html>"

Write-Log "Subject: $subject"

if ($DryRun) {
    Write-Log "DryRun set - skipping send."
    return
}

# --- Send via Outlook COM (skip silently if Outlook not running) ----------

. (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')
$_ensureLog = Join-Path $LogDir 'ensure-outlook.log'
if (-not (Ensure-OutlookRunning -LogFile $_ensureLog)) { exit 0 }

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

    Add-Content -Path $stateFile -Value "$todayKey`t$fingerprint" -Encoding UTF8
}
catch {
    Write-Log "  WARN: email send failed: $($_.Exception.Message). email=skipped:$($_.Exception.GetType().Name)"
    return
}

