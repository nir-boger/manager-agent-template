# Weekly risk-watch pulse.
#
# Parses reports/risks/register.md, extracts Open risks, and emails Nir the
# Red + Amber risks (Green omitted with a count), overdue checkpoints flagged
# and sorted first, so delivery risks don't drift silently between syncs.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-risk-watch-pulse.ps1
# Flags:
#   -DryRun    compute + log, do not send
#   -Force     bypass per-week idempotency check
#   -AsOfDate  override "today" for testing (YYYY-MM-DD)
# Scheduled by:  DM-RiskWatchPulse (weekly, Sundays 08:45 IST).
# Per-week idempotency: state\last-sent.txt prevents duplicate sends in the same ISO week.

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$registerFile = Resolve-AgentPath (Join-Path (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) 'risks\register.md') -Config $AgentConfig
$skillDir     = Join-Path $AgentRoot '.copilot\skills\risk-watch'
$stateFile    = Join-Path $skillDir 'state\last-sent.txt'

New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
$logFile = Join-Path $LogDir ("risk-watch-pulse-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- ISO week tag helper --------------------------------------------------
function Get-IsoWeekTag {
    param([DateTime]$Date)
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $rule = [System.Globalization.CalendarWeekRule]::FirstFourDayWeek
    $w = $cal.GetWeekOfYear($Date, $rule, [DayOfWeek]::Monday)
    $tmp = $Date.AddDays(4 - [int]$Date.DayOfWeek)
    if ([int]$Date.DayOfWeek -eq 0) { $tmp = $Date.AddDays(-3) }
    $isoYear = $tmp.Year
    return ('{0}-W{1:D2}' -f $isoYear, $w)
}

# --- Parse register file --------------------------------------------------
function Get-RiskItems {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "Register file not found at $Path. Nothing to remind."
        return @()
    }

    $lines = Get-Content -Path $Path -Encoding UTF8
    $items = New-Object System.Collections.Generic.List[object]
    $current = $null
    $section = 'preamble'  # preamble | open | closed
    $headingRe = '^###\s+(RK-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$'
    $fieldRe   = '^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$'
    $lastKey = $null
    $multilineKeys = @('why at risk', 'mitigation')

    foreach ($raw in $lines) {
        if ($raw -match '^##\s+Open\b')   { if ($current) { $items.Add($current); $current = $null } ; $section = 'open'   ; $lastKey = $null ; continue }
        if ($raw -match '^##\s+Closed\b') { if ($current) { $items.Add($current); $current = $null } ; $section = 'closed' ; $lastKey = $null ; continue }
        if ($raw -match $headingRe) {
            if ($current) { $items.Add($current) }
            $current = [pscustomobject]@{
                Id             = $matches[1]
                Title          = $matches[2]
                Section        = $section
                Status         = ''
                Risk           = ''
                Area           = ''
                Owner          = ''
                OpenedOn       = ''
                Why            = ''
                Mitigation     = ''
                NextCheckpoint = ''
                LinkedAdo      = ''
                Notes          = ''
            }
            $lastKey = $null
            continue
        }
        if ($current -and $raw -match $fieldRe) {
            $k = $matches['key'].Trim().ToLower()
            $v = $matches['value'].Trim()
            switch ($k) {
                'status'          { $current.Status         = $v }
                'risk'            { $current.Risk           = $v }
                'area'            { $current.Area           = $v }
                'owner'           { $current.Owner          = $v }
                'opened on'       { $current.OpenedOn       = $v }
                'why at risk'     { $current.Why            = $v }
                'mitigation'      { $current.Mitigation     = $v }
                'next checkpoint' { $current.NextCheckpoint = $v }
                'linked ado'      { $current.LinkedAdo      = $v }
                'notes'           { $current.Notes          = $v }
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
                    'why at risk' { $current.Why        = if ($current.Why)        { $current.Why        + "`n" + $t } else { $t } }
                    'mitigation'  { $current.Mitigation = if ($current.Mitigation) { $current.Mitigation + "`n" + $t } else { $t } }
                }
            }
        }
    }
    if ($current) { $items.Add($current) }

    return ,@($items.ToArray())
}

# --- Build event list -----------------------------------------------------
$today = if ($AsOfDate) { [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null).Date } else { (Get-Date).Date }
$weekTag = Get-IsoWeekTag -Date $today

$allItems  = Get-RiskItems -Path $registerFile
$openItems = @($allItems | Where-Object {
    $_.Section -eq 'open' -and ($_.Status -ieq 'open' -or [string]::IsNullOrWhiteSpace($_.Status))
})

Write-Log "Parsed $($allItems.Count) risk(s) total; $($openItems.Count) open."

# --- Idempotency: skip if we already sent this week ----------------------
$alreadySent = $false
if (-not $Force -and (Test-Path $stateFile)) {
    $existing = Get-Content $stateFile -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $existing) {
        if ($line.Trim() -eq $weekTag) { $alreadySent = $true; break }
    }
}
if ($alreadySent) {
    Write-Log "Pulse already sent this week ($weekTag). Skipping. Use -Force to override."
    return
}

# --- Build email ----------------------------------------------------------
. (Join-Path $skillDir 'render.ps1')

$counts = Get-RiskCounts -Items $openItems
$tail   = Format-RiskSubjectTail -Items $openItems
$actionable = $counts.Red + $counts.Amber
# Subject is a plain-text field: use a real em-dash (built from ASCII source) instead of the HTML entity, which would show literally.
$emDash = [char]0x2014

if ($counts.Total -eq 0) {
    $opener  = "<p>The risk register is empty &mdash; no delivery risks tracked this week. (Add one any time: <code>add a risk: &lt;text&gt;</code>.)</p>"
    $tables  = ''
    $subject = "$subjectPrefix Risk watch $emDash nothing tracked"
} elseif ($actionable -eq 0) {
    $opener  = "<p>No Red or Amber risks this week &mdash; $($counts.Green) Green $(if ($counts.Green -eq 1) {'risk'} else {'risks'}) still tracked in the register. Quiet, for once.</p>"
    $tables  = Render-RiskPulse -Items $openItems -Today $today
    $subject = "$subjectPrefix Risk watch $emDash all green"
} else {
    $opener  = "<p>$actionable open $(if ($actionable -eq 1) {'risk needs'} else {'risks need'}) eyes this week ($tail). Overdue checkpoints are flagged first.</p>"
    $tables  = Render-RiskPulse -Items $openItems -Today $today
    $subject = "$subjectPrefix Risk watch $emDash $tail"
}

$footer = "<p style='color:#666;font-size:12px;margin-top:14px'>Source: <code>reports/risks/register.md</code>. To add, update RAG, set a checkpoint, or close a risk, ask me.</p>"

# Jokes - short, on-topic, Nirvana-band-flavored where it lands cleanly.
$jokes = @(
    "A risk left in Amber too long eventually picks a color for you.",
    "Heart-shaped box of mitigations &mdash; open before the checkpoint.",
    "Come as you are, but bring an owner.",
    "Red is just Amber that stopped answering its checkpoints.",
    "The register's only New Year's resolution: turn green.",
    "On a plain markdown file, no less &mdash; risk tracking, pleasantly low-tech."
)
$joke = $jokes | Get-Random
$jokeHtml = "<p style='color:#555;font-style:italic;margin-top:14px'>$joke</p>"

# Signature
. (Join-Path $PSScriptRoot '_shared\signature.ps1')
$signature = Get-NirvanaSignature

$html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
        $opener +
        $tables +
        $footer +
        $jokeHtml +
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

    Add-Content -Path $stateFile -Value $weekTag -Encoding UTF8
}
catch {
    Write-Log "  WARN: email send failed: $($_.Exception.Message). email=skipped:$($_.Exception.GetType().Name)"
    return
}

