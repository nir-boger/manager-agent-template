<#
.SYNOPSIS
  Deterministic Outlook COM free/busy reader for team-vacation-watch.

.DESCRIPTION
  Reads each roster member's free/busy via Outlook COM and emits the exact JSON
  shape apply-vacation-state.ps1 consumes:
    { "as_of": "YYYY-MM-DD",
      "people": [ { "name", "on_vacation", "start", "end", "returned_today", "confidence" } ] }

  WHY NOT WorkIQ: WorkIQ only returns event metadata for timed meetings. It cannot
  read free/busy status or all-day "OOO" banners, so it structurally MISSES vacations
  (verified 2026-06-04: Teammate8 was OOF May 26..Jun 8 and WorkIQ reported nothing).
  Outlook COM Recipient.FreeBusy is authoritative. We sample it HOURLY (60 min/char) and
  collapse each day to an Out-of-Office flag (ConvertTo-DailyOofString): a day counts as
  vacation only when it is a (near) FULL day of OOF. This rejects per-meeting "Show as Out
  of Office" flags that otherwise fake a vacation (verified 2026-06-04: Teammate14 had
  ~2 OOF hours/day of meetings, not a vacation). Status codes: 0=Free 1=Tentative 2=Busy
  3=OutOfOffice 4=WorkingElsewhere.

  The decode is the pure helper Get-FreeBusyVacationStatus (unit-tested). This script
  only does the COM read + roster assembly, then writes/returns the JSON. It NEVER
  writes persona or state files -- apply-vacation-state.ps1 owns all of that.

.NOTES
  Windows PowerShell 5.1. ASCII only. Requires Outlook desktop running.
#>
[CmdletBinding()]
param(
    [string] $PeopleDir,
    [string] $AsOfDate,
    [int]    $LookbackDays  = 14,   # Recipient.FreeBusy returns a fixed ~1-month window
    [string] $OutJsonPath           # if omitted, JSON is written to stdout
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'vacation-helpers.ps1')

$skillDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PeopleDir) { $PeopleDir = Join-Path (Split-Path -Parent $skillDir) 'team-personas\people' }
if (-not $AsOfDate)  { $AsOfDate  = (Get-Date).ToString('yyyy-MM-dd') }
$asOf = [datetime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null)

# Recipient.FreeBusy returns one status char per sampled slot for the recipient's PUBLISHED
# free/busy horizon (~29 days here), ALWAYS starting at the requested date. We sample HOURLY
# (60 min/char) and collapse each day to a single OOF flag with ConvertTo-DailyOofString,
# so that per-meeting "Show as Out of Office" flags don't fake a vacation -- only a (near)
# full day of OOF counts. The requested start must be close enough that as-of (today) lands
# inside the returned window; we start LookbackDays before today (to capture the recent run
# start + yesterday for returned_today) and re-read from today-2 if today still isn't covered.
function Read-FreeBusyCovering {
    param($Recip, [datetime] $AsOf, [int] $Lookback)
    $ws = $AsOf.Date.AddDays(-$Lookback)
    $daily = ConvertTo-DailyOofString -Hourly "$($Recip.FreeBusy($ws, 60, $true))"
    $ti = [int]($AsOf.Date - $ws).Days
    if ($ti -ge $daily.Length) {
        $ws = $AsOf.Date.AddDays(-2)
        $daily = ConvertTo-DailyOofString -Hourly "$($Recip.FreeBusy($ws, 60, $true))"
    }
    return [pscustomobject]@{ Fb = $daily; WindowStart = $ws }
}

# Roster: display name from each persona H1 (exclude nirvana).
$personaFiles = Get-ChildItem -Path $PeopleDir -Filter '*.md' | Where-Object { $_.BaseName -ne 'nirvana' }
$roster = @()
foreach ($f in $personaFiles) {
    $head = Get-Content $f.FullName -TotalCount 1 -Encoding UTF8
    $h1 = [regex]::Match("$head", '^#\s+(.+?)\s*\((.+?)\)\s*$')
    $display = if ($h1.Success) { $h1.Groups[1].Value.Trim() } else { $f.BaseName.Replace('-', ' ') }
    $roster += [pscustomobject]@{ Alias = $f.BaseName; Display = $display }
}

$ol = New-Object -ComObject Outlook.Application
$ns = $ol.GetNamespace('MAPI')

$people = @()
foreach ($m in $roster) {
    $status = $null
    $recurring = @()
    try {
        $recip = $ns.CreateRecipient($m.Display)
        $null = $recip.Resolve()
        if ($recip.Resolved) {
            $read = Read-FreeBusyCovering -Recip $recip -AsOf $asOf -Lookback $LookbackDays
            $status = Get-FreeBusyVacationStatus -FreeBusy $read.Fb -WindowStart $read.WindowStart -AsOf $asOf
            # Recurring weekly OOF weekdays (e.g. a part-timer off every Wednesday). The engine
            # subtracts these from the vacation working-day count so a standing weekly day-off
            # never triggers a welcome-back; only UNEXPECTED absence counts.
            $recurring = @(Get-RecurringOffDays -DailyOof $read.Fb -WindowStart $read.WindowStart)
        }
    } catch {
        Write-Verbose "free/busy read failed for $($m.Display): $($_.Exception.Message)"
    }
    if ($null -eq $status) {
        # Unresolved / read error -> conservative not-on-vacation, low confidence.
        $status = [pscustomobject]@{ on_vacation = $false; start = $null; end = $null; returned_today = $false; confidence = 'low' }
    }
    $people += [ordered]@{
        name               = $m.Display
        on_vacation        = [bool]$status.on_vacation
        start              = $status.start
        end                = $status.end
        returned_today     = [bool]$status.returned_today
        confidence         = "$($status.confidence)"
        recurring_off_days = @($recurring)
    }
}

[System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) | Out-Null

$payload = [ordered]@{ as_of = $AsOfDate; people = $people }
$json = $payload | ConvertTo-Json -Depth 6

if ($OutJsonPath) {
    Set-Content -Path $OutJsonPath -Value $json -Encoding UTF8
    Write-Output $OutJsonPath
} else {
    Write-Output $json
}

