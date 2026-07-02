<#
.SYNOPSIS
  Pure, side-effect-free helpers for team-vacation-watch. Dot-sourced by
  apply-vacation-state.ps1 and by tests/team-vacation-watch.tests.ps1.

  Keep this file free of orchestration / disk I/O so it is safe to dot-source
  in a test harness. Windows PowerShell 5.1, ASCII only.
#>

# Decode an Outlook free/busy string into a vacation status for a given as-of date.
# The free/busy string has ONE character per day (when sampled at 1440 min/char),
# each char a status code: 0=Free, 1=Tentative, 2=Busy, 3=OutOfOffice, 4=WorkingElsewhere.
# $WindowStart is the calendar date that corresponds to index 0 of $FreeBusy.
# Returns the same shape apply-vacation-state.ps1 consumes per person:
#   [pscustomobject]@{ on_vacation; start; end; returned_today; confidence }
# Pure: no COM, no I/O. The COM read happens in read-freebusy.ps1.
function Get-FreeBusyVacationStatus {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $FreeBusy,
        [Parameter(Mandatory)][datetime] $WindowStart,
        [Parameter(Mandatory)][datetime] $AsOf,
        [string] $OofCode = '3'
    )
    $notOnVac = { param($conf) [pscustomobject]@{ on_vacation = $false; start = $null; end = $null; returned_today = $false; confidence = $conf } }

    if ([string]::IsNullOrEmpty($FreeBusy)) { return (& $notOnVac 'low') }

    $ti = [int]($AsOf.Date - $WindowStart.Date).Days
    if ($ti -lt 0 -or $ti -ge $FreeBusy.Length) {
        # We have no sampled data covering the as-of day -> unknown, not on vacation.
        return (& $notOnVac 'low')
    }

    $todayCode = "$($FreeBusy[$ti])"

    if ($todayCode -eq $OofCode) {
        # Walk the contiguous OOF run around today to get start..end (inclusive).
        $s = $ti; while ($s - 1 -ge 0 -and "$($FreeBusy[$s - 1])" -eq $OofCode) { $s-- }
        $e = $ti; while ($e + 1 -lt $FreeBusy.Length -and "$($FreeBusy[$e + 1])" -eq $OofCode) { $e++ }
        $startDate = $WindowStart.Date.AddDays($s)
        $endDate   = $WindowStart.Date.AddDays($e)
        # If the run is truncated at index 0 we can't see its true start; report what we have.
        return [pscustomobject]@{
            on_vacation    = $true
            start          = $startDate.ToString('yyyy-MM-dd')
            end            = $endDate.ToString('yyyy-MM-dd')
            returned_today = $false
            confidence     = 'high'
        }
    }

    # Not OOF today. returned_today only if we can see yesterday was OOF. When it IS a
    # return, walk the contiguous OOF run that just ended (end = yesterday) and report its
    # start..end, so the caller can measure how many working days the absence cost and gate
    # the welcome on it. Without this the explicit returned_today path carried no span and
    # slipped past the min-working-days gate -- a 1-working-day absence got wrongly welcomed.
    # Symmetric to the on-vacation branch above.
    $returnedToday = $false
    $endedStart = $null
    $endedEnd   = $null
    if ($ti - 1 -ge 0 -and "$($FreeBusy[$ti - 1])" -eq $OofCode) {
        $returnedToday = $true
        $e = $ti - 1
        $s = $e; while ($s - 1 -ge 0 -and "$($FreeBusy[$s - 1])" -eq $OofCode) { $s-- }
        $endedStart = $WindowStart.Date.AddDays($s).ToString('yyyy-MM-dd')
        $endedEnd   = $WindowStart.Date.AddDays($e).ToString('yyyy-MM-dd')
    }
    return [pscustomobject]@{
        on_vacation    = $false
        start          = $endedStart
        end            = $endedEnd
        returned_today = $returnedToday
        confidence     = 'high'
    }
}

# Collapse an HOURLY free/busy string (one char per 60-min slot, sampled from midnight)
# into a DAILY out-of-office string (one char per day): '3' only when a day is essentially
# a FULL day of Out-of-Office (a real all-day OOF / vacation appointment), else '0'.
#
# WHY: Outlook free/busy sampled at 1440 min/char collapses a whole day to '3' if ANY part
# of it is OOF. People who mark individual meetings as "Show as Out of Office" then look
# identical to someone on vacation. Sampling hourly and requiring a (near) full day of OOF
# rejects that per-meeting noise. Verified 2026-06-04: Teammate14 had ~2 OOF hours/day
# (meetings) and was wrongly flagged; Oz/Maya were 24/24 OOF hours (genuine vacations).
# Pure: no COM, no I/O.
function ConvertTo-DailyOofString {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Hourly,
        [int] $SlotsPerDay = 24,
        [double] $MinOofFraction = 0.9
    )
    if ([string]::IsNullOrEmpty($Hourly)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $n = $Hourly.Length
    $minSlots = [int][Math]::Ceiling($SlotsPerDay * $MinOofFraction)
    for ($i = 0; $i -lt $n; $i += $SlotsPerDay) {
        $len = [Math]::Min($SlotsPerDay, $n - $i)
        $day = $Hourly.Substring($i, $len)
        $oof = ([regex]::Matches($day, '3')).Count
        # A day counts as vacation-OOF only if it has a near-complete slot count AND
        # a near-complete fraction of those slots are OOF (so a truncated final day or
        # a couple of OOF meetings never qualifies).
        if ($len -ge $minSlots -and ($oof / [double]$len) -ge $MinOofFraction) {
            [void]$sb.Append('3')
        } else {
            [void]$sb.Append('0')
        }
    }
    return $sb.ToString()
}

function Get-DominantEol {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Content)
    $crlf = ([regex]::Matches($Content, "`r`n")).Count
    $lf   = ([regex]::Matches($Content, "`n")).Count
    if ($crlf -gt 0 -and $crlf -ge ($lf - $crlf)) { return "`r`n" }
    if ($lf -gt 0) { return "`n" }
    return "`r`n"   # default for a brand-new / single-line file on Windows
}

function Get-VacationStatusLine {
    param(
        [Parameter(Mandatory)][bool]   $OnVacation,
        [string] $Start,
        [string] $End,
        [Parameter(Mandatory)][string] $AsOf
    )
    if (-not $OnVacation) { return "Not on vacation (as of $AsOf)." }
    if ([string]::IsNullOrWhiteSpace($Start)) { return "On vacation (as of $AsOf)." }
    if ([string]::IsNullOrWhiteSpace($End)) { return "On vacation from $Start (as of $AsOf)." }
    return "On vacation $Start..$End (per team calendar, as of $AsOf)."
}

# Returns the new file content with the managed vacation block upserted.
# NEVER touches anything outside the marker region (when markers exist).
# String-splice based (no regex-replacement-string pitfalls).
function Set-VacationBlockContent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [Parameter(Mandatory)][string] $StatusLine,
        [string] $Eol
    )
    if (-not $Eol) { $Eol = Get-DominantEol -Content $Content }

    $open  = '<!-- nirvana:vacation-status -->'
    $close = '<!-- /nirvana:vacation-status -->'
    $block = $open + $Eol + "- **Vacation:** $StatusLine" + $Eol + $close

    # Case 1: markers present -> splice the region [openIdx, closeEnd) with the new block.
    $m = [regex]::Match($Content, '(?s)<!--\s*nirvana:vacation-status\s*-->.*?<!--\s*/nirvana:vacation-status\s*-->')
    if ($m.Success) {
        return $Content.Substring(0, $m.Index) + $block + $Content.Substring($m.Index + $m.Length)
    }

    # Case 2: a '## Notes' header exists -> insert the block right after that header line.
    $notes = [regex]::Match($Content, '(?m)^##[^\S\r\n]+Notes[^\r\n]*$')
    if ($notes.Success) {
        $insertAt = $notes.Index + $notes.Length
        $rest = $Content.Substring($insertAt)
        $leadEol = ''
        if ($rest.StartsWith("`r`n")) { $leadEol = "`r`n"; $rest = $rest.Substring(2) }
        elseif ($rest.StartsWith("`n")) { $leadEol = "`n"; $rest = $rest.Substring(1) }
        return $Content.Substring(0, $insertAt) + $leadEol + $block + $Eol + $rest
    }

    # Case 3: no Notes section -> append a fresh '## Notes' section at EOF (never reorders).
    $trimmed = $Content.TrimEnd("`r", "`n")
    return $trimmed + $Eol + $Eol + '## Notes' + $Eol + $block + $Eol
}

# Map a WorkIQ display name to a roster alias (case-insensitive exact match).
function Resolve-AliasFromName {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][hashtable] $DisplayToAlias
    )
    $key = $Name.Trim().ToLowerInvariant()
    if ($DisplayToAlias.ContainsKey($key)) { return $DisplayToAlias[$key] }
    return $null
}

# Decide whether a roster member is a returnee, and the concrete return_date.
# Returns [pscustomobject]@{ IsReturnee; ReturnDate(string|null); Reason }.
function Get-ReturneeDecision {
    param(
        [Parameter(Mandatory)][bool] $IsFirstRun,
        [bool]   $CurOnVacation,
        [string] $CurConfidence,
        [bool]   $ReturnedToday,
        [AllowNull()][object] $Prior,         # prior snapshot person obj or $null
        [Parameter(Mandatory)][datetime] $Today
    )
    $okConf = @('high', 'medium') -contains ("$CurConfidence").ToLowerInvariant()

    # (A) Explicit returned_today
    if ($ReturnedToday -and $okConf) {
        return [pscustomobject]@{ IsReturnee = $true; ReturnDate = $Today.ToString('yyyy-MM-dd'); Reason = 'explicit' }
    }

    # First run: only the explicit path may post.
    if ($IsFirstRun) {
        return [pscustomobject]@{ IsReturnee = $false; ReturnDate = $null; Reason = 'first-run-no-explicit' }
    }

    # (B) Transition: prior on_vacation true -> current false.
    $priorOnVac = $false
    $priorEnd = $null
    if ($null -ne $Prior) {
        try { $priorOnVac = [bool]$Prior.on_vacation } catch { $priorOnVac = $false }
        try { $priorEnd = [string]$Prior.end } catch { $priorEnd = $null }
    }
    if ($priorOnVac -and -not $CurOnVacation -and $okConf) {
        if (-not [string]::IsNullOrWhiteSpace($priorEnd)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($priorEnd, [ref]$parsed)) {
                return [pscustomobject]@{ IsReturnee = $true; ReturnDate = $parsed.AddDays(1).ToString('yyyy-MM-dd'); Reason = 'transition' }
            }
        }
        # Transition but no usable prior end -> still a returnee, dated today.
        return [pscustomobject]@{ IsReturnee = $true; ReturnDate = $Today.ToString('yyyy-MM-dd'); Reason = 'transition-no-end' }
    }

    return [pscustomobject]@{ IsReturnee = $false; ReturnDate = $null; Reason = 'no-transition' }
}

function Test-IsWorkingDay {
    param(
        [Parameter(Mandatory)][datetime] $Date,
        [int[]] $WorkingDays = @(0, 1, 2, 3, 4)
    )
    return @($WorkingDays) -contains ([int]$Date.DayOfWeek)
}

function Get-NextWorkingDay {
    param(
        [Parameter(Mandatory)][datetime] $Date,
        [int[]] $WorkingDays = @(0, 1, 2, 3, 4)
    )
    $d = $Date.Date
    while (-not (Test-IsWorkingDay -Date $d -WorkingDays $WorkingDays)) {
        $d = $d.AddDays(1)
    }
    return $d
}

# Count the Israel working days (Sun-Thu by default) in the inclusive span [Start, End].
# Weekend days (Fri/Sat) never count. Used to gate the welcome-back: a vacation that
# cost fewer than N working days (e.g. weekend-only, or Thu+Fri+Sat = 1 working day) is
# too short to be worth a "welcome back". Returns 0 for an inverted/empty span.
# Pure: no COM, no I/O.
function Get-WorkingDayCount {
    param(
        [Parameter(Mandatory)][datetime] $Start,
        [Parameter(Mandatory)][datetime] $End,
        [int[]] $WorkingDays = @(0, 1, 2, 3, 4)
    )
    if ($End.Date -lt $Start.Date) { return 0 }
    $count = 0
    $d = $Start.Date
    while ($d -le $End.Date) {
        if (Test-IsWorkingDay -Date $d -WorkingDays $WorkingDays) { $count++ }
        $d = $d.AddDays(1)
    }
    return $count
}

# Detect a person's RECURRING weekly Out-of-Office weekdays from a multi-week DAILY OOF
# string (one char per day, '3' = full-day OOF). This is what distinguishes a standing
# weekly day-off (e.g. a part-timer who is OOF every Wednesday, or every Sunday) from a
# genuine multi-day vacation.
#
# WHY THIS EXISTS: the min-working-days gate alone treated recurring OOF as vacation.
# Teammate2 is OOF every Wednesday (plus her Fri/Sat weekend). Most weeks that is 1
# working day (gated out), but any week she was ALSO off an adjacent weekday (e.g. Tue+Wed)
# crossed the >=2 gate and wrongly fired a "welcome back" -- every Thursday. Subtracting a
# person's recurring-off weekdays from the vacation working-day count fixes this at the root:
# only UNEXPECTED absence counts toward a welcome-back.
#
# A working weekday is "recurring off" when, across the window, it is OOF on a strong
# majority ($MinOofFraction) of its >=$MinObserved occurrences AND it appears OOF *in
# isolation* -- i.e. NOT part of a multi-working-day contiguous OOF block -- in at least
# $MinIsolated distinct weeks. The isolation test is measured against the nearest WORKING-day
# neighbours (so the Fri/Sat weekend gap is ignored), which lets it also catch someone off
# every Sunday or every Thursday, while a genuine contiguous vacation (whose interior
# weekdays are never isolated) is never mistaken for a recurring pattern.
#
# Weekends (the days NOT in $WorkingDays) are never returned: they are already handled by
# the base working-day set, so recurring detection only ranges over working weekdays.
# Returns an int[] of DayOfWeek values (0=Sun..6=Sat). Pure: no COM, no I/O.
function Get-RecurringOffDays {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $DailyOof,
        [Parameter(Mandatory)][datetime] $WindowStart,
        [int[]]  $WorkingDays    = @(0, 1, 2, 3, 4),
        [int]    $MinObserved    = 3,
        [double] $MinOofFraction = 0.6,
        [int]    $MinIsolated    = 2,
        [string] $OofCode        = '3'
    )
    $result = @()
    if ([string]::IsNullOrEmpty($DailyOof)) { return $result }
    $n = $DailyOof.Length
    $isOof = New-Object 'bool[]' $n
    $dow   = New-Object 'int[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $isOof[$i] = ("$($DailyOof[$i])" -eq $OofCode)
        $dow[$i]   = [int]$WindowStart.Date.AddDays($i).DayOfWeek
    }
    # OOF status of the nearest working-day neighbour before/after index (skips weekend days);
    # a missing neighbour (window edge) counts as NOT OOF, so an edge occurrence reads isolated.
    $neighbourOof = {
        param($idx, $step)
        for ($j = $idx + $step; $j -ge 0 -and $j -lt $n; $j += $step) {
            if (@($WorkingDays) -contains $dow[$j]) { return $isOof[$j] }
        }
        return $false
    }
    foreach ($wd in @($WorkingDays)) {
        $observed = 0; $oof = 0; $isolated = 0
        for ($i = 0; $i -lt $n; $i++) {
            if ($dow[$i] -ne $wd) { continue }
            $observed++
            if ($isOof[$i]) {
                $oof++
                if (-not (& $neighbourOof $i -1) -and -not (& $neighbourOof $i 1)) { $isolated++ }
            }
        }
        if ($observed -ge $MinObserved -and ($oof / [double]$observed) -ge $MinOofFraction -and $isolated -ge $MinIsolated) {
            $result += $wd
        }
    }
    return @($result)
}

# The Israel working-day set (Sun-Thu) with a person's recurring-off weekdays removed, so a
# vacation working-day count reflects only UNEXPECTED absence. Never returns an empty set
# (if every working day were somehow recurring-off we fall back to the full set rather than
# suppress every genuine vacation).
function Get-EffectiveWorkingDays {
    param(
        [int[]] $RecurringOff = @(),
        [int[]] $WorkingDays  = @(0, 1, 2, 3, 4)
    )
    $eff = @(@($WorkingDays) | Where-Object { @($RecurringOff) -notcontains $_ })
    if (-not $eff -or $eff.Count -eq 0) { return @($WorkingDays) }
    return $eff
}

function Get-WelcomeDueDecision {
    param(
        [Parameter(Mandatory)][datetime] $Today,
        [Parameter(Mandatory)][datetime] $ReturnDate,
        [int] $MaxLate = 2,
        [int[]] $WorkingDays = @(0, 1, 2, 3, 4)
    )
    $eff = Get-NextWorkingDay -Date $ReturnDate -WorkingDays $WorkingDays
    if ($Today.Date -lt $eff.Date) {
        return [pscustomobject]@{ Decision = 'hold'; Effective = $eff }
    }
    $late = ($Today.Date - $eff.Date).Days
    if ($late -gt $MaxLate) {
        return [pscustomobject]@{ Decision = 'stale'; Effective = $eff }
    } elseif (Test-IsWorkingDay -Date $Today -WorkingDays $WorkingDays) {
        return [pscustomobject]@{ Decision = 'due'; Effective = $eff }
    } else {
        return [pscustomobject]@{ Decision = 'hold'; Effective = $eff }
    }
}
# Is a (alias, return_date) already welcomed (status=sent) in the ledger?
function Test-AlreadyWelcomed {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]] $Ledger,
        [Parameter(Mandatory)][string] $Alias,
        [Parameter(Mandatory)][string] $ReturnDate
    )
    if ($null -eq $Ledger) { return $false }
    foreach ($e in $Ledger) {
        if ($null -eq $e) { continue }
        if (("$($e.alias)") -eq $Alias -and ("$($e.return_date)") -eq $ReturnDate -and ("$($e.status)") -eq 'sent') {
            return $true
        }
    }
    return $false
}

