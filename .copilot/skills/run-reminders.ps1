# run-reminders.ps1 - poll reports/reminders/reminders.md every 5 min and fire any due reminder.
#
# Single-instance lock at reports/logs/reminders.lock.
# Idempotent: only fires Status=pending entries within [now-10min, now] window.
# Re-resolves meeting times on every tick so reminders follow if a meeting is moved.
#
# Switches:
#   -DryRun       parse + resolve + log, but skip Send and skip status flip
#   -PreviewOnly  print which reminders would fire right now, then exit
#   -Force        ignore the 10-min back-window and fire anything strictly in the past
#
# ASCII-only source on purpose (PS 5.1 parses .ps1 via CP1252).

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$PreviewOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- paths -------------------------------------------------------------------
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$RemFile  = Join-Path $RepoRoot 'reports\reminders\reminders.md'
$LogDir   = Join-Path $RepoRoot 'reports\logs'
$LogFile  = Join-Path $LogDir   ('reminders-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
$LockFile = Join-Path $LogDir   'reminders.lock'
$SigPs1   = Join-Path $RepoRoot '.copilot\skills\_shared\signature.ps1'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# ---- logging -----------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = 'info')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ---- single-instance lock ----------------------------------------------------
function Acquire-Lock {
    if (Test-Path $LockFile) {
        $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($age.TotalMinutes -lt 15) {
            Write-Log "another instance holds the lock (age $([int]$age.TotalSeconds)s) - exiting." 'warn'
            return $false
        }
        Write-Log "stale lock (age $([int]$age.TotalMinutes)m) - clearing." 'warn'
        Remove-Item $LockFile -Force
    }
    "$PID" | Set-Content -Path $LockFile -Encoding ASCII
    return $true
}
function Release-Lock { if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } }

# ---- markdown parsing --------------------------------------------------------
# Each section starts with "### RM-NNN - <title>" and continues until the next "### " or "## " heading or EOF.
function Read-Reminders {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $text = Get-Content -Path $Path -Raw -Encoding UTF8
    $lines = $text -split "`r?`n"

    $entries = @()
    $cur = $null
    $startLine = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^###\s+(RM-\d{3})\s*-\s*(.+?)\s*$') {
            if ($cur) {
                $cur.EndLine = $i - 1
                $entries += $cur
            }
            $cur = [pscustomobject]@{
                Id            = $Matches[1]
                Title         = $Matches[2]
                StartLine     = $i
                EndLine       = -1
                Status        = $null
                Kind          = $null
                Channel       = 'email'
                Created       = $null
                Fields        = @{}
            }
            continue
        }
        # If a new "## " section header appears, close current entry.
        if ($ln -match '^##\s+' -and $cur) {
            $cur.EndLine = $i - 1
            $entries += $cur
            $cur = $null
            continue
        }
        if ($cur -and $ln -match '^\s*-\s+\*\*([^*]+):\*\*\s*(.*?)\s*$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            $cur.Fields[$k] = $v
            switch ($k.ToLower()) {
                'status'  { $cur.Status  = $v }
                'kind'    { $cur.Kind    = $v }
                'channel' { $cur.Channel = $v }
                'created' { $cur.Created = $v }
            }
        }
    }
    if ($cur) { $cur.EndLine = $lines.Length - 1; $entries += $cur }
    return ,$entries
}

# ---- Outlook helpers ---------------------------------------------------------
$script:OutlookApp = $null
$script:OutlookNs  = $null
function Get-Outlook {
    if ($script:OutlookApp) { return $script:OutlookApp }
    try {
        $script:OutlookApp = New-Object -ComObject Outlook.Application
        $script:OutlookNs  = $script:OutlookApp.GetNamespace('MAPI')
        return $script:OutlookApp
    } catch {
        Write-Log "Outlook COM unavailable: $($_.Exception.Message)" 'warn'
        return $null
    }
}

# Find the first meeting on $date whose subject contains $needle (case-insensitive).
# Returns a [datetime] or $null.
function Resolve-MeetingStart {
    param([string]$Date, [string]$Needle)
    $app = Get-Outlook
    if (-not $app) { return $null }
    try {
        $d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null)
    } catch {
        Write-Log "bad meeting date '$Date' - $($_.Exception.Message)" 'warn'
        return $null
    }
    $start = $d.Date
    $end   = $start.AddDays(1)
    $cal = $script:OutlookNs.GetDefaultFolder(9)  # olFolderCalendar
    $items = $cal.Items
    $items.IncludeRecurrences = $true
    $items.Sort('[Start]')
    $fmt = "'{0:MM/dd/yyyy HH:mm tt}'"
    $r = ('[Start] >= {0} AND [Start] < {1}' -f ($fmt -f $start), ($fmt -f $end))
    $restricted = $items.Restrict($r)
    $needleLc = $Needle.ToLower()
    $hit = $null
    foreach ($it in $restricted) {
        try {
            $subj = if ($it.Subject) { $it.Subject } else { '' }
            if ($subj.ToLower().Contains($needleLc)) { $hit = $it; break }
        } catch { continue }
    }
    if ($null -eq $hit) { return $null }
    try { return [datetime]$hit.Start } catch { return $null }
}

# ---- fire-time computation ---------------------------------------------------
function Compute-FireAt {
    param([pscustomobject]$Entry)
    if ($Entry.Kind -eq 'absolute') {
        $iso = $Entry.Fields['Fire at']
        if (-not $iso) { return @{ ok=$false; reason='missing Fire at' } }
        try {
            $dt = [datetimeoffset]::Parse($iso).LocalDateTime
            return @{ ok=$true; at=$dt; source='absolute' }
        } catch {
            return @{ ok=$false; reason="bad Fire at '$iso'" }
        }
    } elseif ($Entry.Kind -eq 'meeting') {
        $needle = $Entry.Fields['Meeting subject match']
        $mdate  = $Entry.Fields['Meeting date']
        $off    = $Entry.Fields['Offset min']
        if (-not $needle -or -not $mdate -or -not $off) {
            return @{ ok=$false; reason='missing meeting subject/date/offset' }
        }
        try { $offInt = [int]$off } catch { return @{ ok=$false; reason="bad offset '$off'" } }
        $start = Resolve-MeetingStart -Date $mdate -Needle $needle
        if ($null -eq $start) { return @{ ok=$false; reason="meeting not found (subject contains '$needle' on $mdate)" } }
        $at = $start.AddMinutes($offInt)
        return @{ ok=$true; at=$at; source=('meeting@{0:yyyy-MM-ddTHH:mm:ss}' -f $start) }
    } else {
        return @{ ok=$false; reason="unknown kind '$($Entry.Kind)'" }
    }
}

# ---- markdown rewrite (flip Status in place) ---------------------------------
function Mark-Fired {
    param(
        [string]$Path,
        [string]$Id,
        [datetime]$FiredAt,
        [datetime]$ResolvedFireAt,
        [string]$SourceTag
    )
    $text  = Get-Content -Path $Path -Raw -Encoding UTF8
    $lines = $text -split "`r?`n"

    $start = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match ('^###\s+' + [regex]::Escape($Id) + '\b')) { $start = $i; break }
    }
    if ($start -lt 0) { throw "section $Id not found in $Path" }

    $end = $lines.Length - 1
    for ($j = $start + 1; $j -lt $lines.Length; $j++) {
        if ($lines[$j] -match '^###\s+RM-\d{3}\b' -or $lines[$j] -match '^##\s+') { $end = $j - 1; break }
    }

    $firedAtIso     = $FiredAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $resolvedAtIso  = $ResolvedFireAt.ToString('yyyy-MM-ddTHH:mm:sszzz')

    $newSection = New-Object System.Collections.Generic.List[string]
    $insertedFiredAt = $false
    $insertedResolved = $false
    $statusFlipped = $false
    for ($k = $start; $k -le $end; $k++) {
        $ln = $lines[$k]
        if (-not $statusFlipped -and $ln -match '^(\s*-\s+\*\*Status:\*\*\s*)pending\s*$') {
            $newSection.Add($Matches[1] + 'fired')
            $statusFlipped = $true
            continue
        }
        $newSection.Add($ln)
    }
    if (-not $statusFlipped) {
        # entry had no Status: pending line - inject one
        $newSection.Insert(1, '- **Status:** fired')
    }
    # Append the timestamp fields just before the trailing blank line of the section.
    # Find last non-empty line within section.
    $lastIdx = $newSection.Count - 1
    while ($lastIdx -ge 0 -and [string]::IsNullOrWhiteSpace($newSection[$lastIdx])) { $lastIdx-- }
    $insertAt = $lastIdx + 1
    $newSection.Insert($insertAt, ('- **Fired at:** ' + $firedAtIso))
    $newSection.Insert($insertAt + 1, ('- **Resolved fire_at:** ' + $resolvedAtIso))
    $newSection.Insert($insertAt + 2, ('- **Source:** ' + $SourceTag))

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $start; $i++) { $out.Add($lines[$i]) }
    foreach ($s in $newSection) { $out.Add($s) }
    for ($i = $end + 1; $i -lt $lines.Length; $i++) { $out.Add($lines[$i]) }

    $newText = ($out -join "`r`n")
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $newText, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $Path -Force
}

# ---- email send --------------------------------------------------------------
function Send-ReminderEmail {
    param([pscustomobject]$Entry, [datetime]$ResolvedFireAt, [string]$SourceTag)

    Add-Type -AssemblyName System.Web

    $app = Get-Outlook
    if (-not $app) { Write-Log "cannot send: Outlook unavailable" 'error'; return $false }

    . $SigPs1
    $notesRaw = if ($Entry.Fields.ContainsKey('Notes')) { $Entry.Fields['Notes'] } else { '' }
    $noJoke = ($notesRaw -match '(?i)NOJOKE|NO\s*JOKE|no-joke') -or ($Entry.Title -match '(?i)NOJOKE')
    $noSig  = ($notesRaw -match '(?i)NOSIG')                    -or ($Entry.Title -match '(?i)NOSIG')

    $subj = '[Nirvana] Reminder: ' + $Entry.Title
    if ($subj.Length -gt 120) { $subj = $subj.Substring(0,117) + '...' }

    $jokePool = @(
        "Reminders are the duct tape of executive function - and we are in deep this week.",
        "If you forget this one too, I'll remind you that I reminded you.",
        "I had nothing better to do for the last 5 minutes anyway.",
        "Marking this 'remember' before it joins the 'oh no, I forgot' pile.",
        "Consider this your nudge - the gentle kind, before life uses the loud kind."
    )
    $joke = $jokePool[(Get-Random -Minimum 0 -Maximum $jokePool.Count)]

    $bodyHtml = New-Object System.Text.StringBuilder
    [void]$bodyHtml.AppendLine('<div style="font-family: Segoe UI, Aptos, Calibri, sans-serif; font-size: 14px; color: #242424;">')
    [void]$bodyHtml.AppendLine('<p>Heads up: <b>' + [System.Web.HttpUtility]::HtmlEncode($Entry.Title) + '</b></p>')
    [void]$bodyHtml.AppendLine('<table style="border-collapse: collapse;">')
    [void]$bodyHtml.AppendLine('<tr><td style="padding: 2px 12px 2px 0;color:#5c5c5c;">Reminder</td><td style="padding: 2px 0;"><code>' + $Entry.Id + '</code></td></tr>')
    [void]$bodyHtml.AppendLine('<tr><td style="padding: 2px 12px 2px 0;color:#5c5c5c;">Fire time</td><td style="padding: 2px 0;">' + $ResolvedFireAt.ToString('yyyy-MM-dd HH:mm zzz') + '</td></tr>')
    [void]$bodyHtml.AppendLine('<tr><td style="padding: 2px 12px 2px 0;color:#5c5c5c;">Source</td><td style="padding: 2px 0;">' + [System.Web.HttpUtility]::HtmlEncode($SourceTag) + '</td></tr>')
    [void]$bodyHtml.AppendLine('</table>')
    if ($notesRaw) {
        [void]$bodyHtml.AppendLine('<p style="margin-top: 14px;"><b>Notes</b><br/>' + ([System.Web.HttpUtility]::HtmlEncode($notesRaw) -replace "`n", '<br/>') + '</p>')
    }
    if (-not $noJoke) {
        [void]$bodyHtml.AppendLine('<p style="color:#5c5c5c;font-style:italic;margin-top:18px;">' + [System.Web.HttpUtility]::HtmlEncode($joke) + '</p>')
    }
    if (-not $noSig) {
        $sig = Get-NirvanaSignature -NoNotice
        [void]$bodyHtml.AppendLine($sig)
    }
    [void]$bodyHtml.AppendLine('</div>')

    $mail = $script:OutlookApp.CreateItem(0)  # olMailItem
    $mail.Subject = $subj
    $mail.HTMLBody = $bodyHtml.ToString()
    $mail.To = 'someone@example.com'
    $mail.Send()
    return $true
}

# ---- main --------------------------------------------------------------------
try {
    if (-not (Acquire-Lock)) { exit 0 }

    if (-not (Test-Path $RemFile)) {
        Write-Log "no reminders file at $RemFile - nothing to do." 'info'
        Release-Lock
        exit 0
    }

    $entries = Read-Reminders -Path $RemFile
    $pending = @($entries | Where-Object { $_.Status -eq 'pending' })
    Write-Log ("parsed {0} entries ({1} pending)" -f $entries.Count, $pending.Count)

    if ($pending.Count -eq 0) { Release-Lock; exit 0 }

    $now = Get-Date
    $backWindow = New-TimeSpan -Minutes 10
    $hits = @()

    foreach ($e in $pending) {
        $res = Compute-FireAt -Entry $e
        if (-not $res.ok) {
            Write-Log ("{0}: skip - {1}" -f $e.Id, $res.reason) 'warn'
            continue
        }
        $diff = $now - $res.at  # >0 means past, <0 means future
        $inWindow = if ($Force) { $diff.TotalSeconds -ge 0 } else { $diff -ge [timespan]::Zero -and $diff -le $backWindow }
        $tag = if ($inWindow) { 'FIRE' } else { if ($diff -lt [timespan]::Zero) { 'future' } else { 'too-old' } }
        Write-Log ("{0}: fire_at={1:yyyy-MM-dd HH:mm:ss} ({2}) - {3} (diff={4:N1}m)" -f $e.Id, $res.at, $res.source, $tag, $diff.TotalMinutes)
        if ($inWindow) { $hits += [pscustomobject]@{ Entry=$e; At=$res.at; Source=$res.source } }
    }

    if ($PreviewOnly) {
        Write-Log ("preview-only: {0} would fire now." -f $hits.Count)
        Release-Lock
        exit 0
    }

    foreach ($h in $hits) {
        if ($DryRun) {
            Write-Log ("DRY-RUN would fire {0}" -f $h.Entry.Id)
            continue
        }
        try {
            $ok = Send-ReminderEmail -Entry $h.Entry -ResolvedFireAt $h.At -SourceTag $h.Source
            if ($ok) {
                Mark-Fired -Path $RemFile -Id $h.Entry.Id -FiredAt (Get-Date) -ResolvedFireAt $h.At -SourceTag $h.Source
                Write-Log ("{0}: FIRED + marked." -f $h.Entry.Id) 'info'
            } else {
                Write-Log ("{0}: send failed - leaving pending." -f $h.Entry.Id) 'error'
            }
        } catch {
            Write-Log ("{0}: exception during fire/mark: {1}" -f $h.Entry.Id, $_.Exception.Message) 'error'
        }
    }
} finally {
    Release-Lock
}

