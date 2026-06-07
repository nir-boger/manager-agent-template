# Pure helpers + HTML renderers for the sprint-digest weekly email.
#
# run-sprint-digest.ps1 dot-sources this. The pace/working-day/state-classifier
# functions are pure (no I/O) so tests can exercise them directly.
#
# ASCII-only source (PS 5.1 parses .ps1 via CP1252). Non-ASCII via HTML entities.

# --- Pure: working-day math (Israel Sun-Thu work week) --------------------

function Test-IsWorkingDay {
    param([DateTime]$Date)
    # Sunday(0)..Thursday(4) are working days; Friday(5)/Saturday(6) are not.
    return ([int]$Date.DayOfWeek -le 4)
}

function Get-WorkingDaysInRange {
    # Inclusive count of Sun-Thu dates in [Start, End].
    param([DateTime]$Start, [DateTime]$End)
    $s = $Start.Date; $e = $End.Date
    if ($e -lt $s) { return 0 }
    $n = 0
    for ($d = $s; $d -le $e; $d = $d.AddDays(1)) {
        if (Test-IsWorkingDay -Date $d) { $n++ }
    }
    return $n
}

function Get-ElapsedWorkingDays {
    # Working days from Start through YESTERDAY (today not yet "worked"), clamped >= 0.
    param([DateTime]$Start, [DateTime]$Today)
    $end = $Today.Date.AddDays(-1)
    if ($end -lt $Start.Date) { return 0 }
    return Get-WorkingDaysInRange -Start $Start -End $end
}

function Get-Fraction {
    param([double]$Numerator, [double]$Denominator)
    if ($Denominator -le 0) { return 0.0 }
    $f = $Numerator / $Denominator
    if ($f -lt 0) { return 0.0 }
    if ($f -gt 1) { return 1.0 }
    return $f
}

# --- Pure: work-item state classification ---------------------------------

function Get-WorkItemStateClass {
    <#
        Maps a work-item State string to one of:
          'done'        - completed (Done/Closed/Resolved/Completed)
          'removed'     - cut/removed (excluded from the denominator)
          'notstarted'  - To Do/New/Proposed (not yet picked up)
          'inprogress'  - everything else still open (Active/In Progress/In Review/Committed/...)
        Case-insensitive; unknown/blank -> 'inprogress' (conservative: counts as open work).
    #>
    param([string]$State)
    $s = ($State + '').Trim().ToLower()
    switch -regex ($s) {
        '^(done|closed|resolved|completed)$'        { return 'done' }
        '^(removed|cut)$'                           { return 'removed' }
        '^(to ?do|new|proposed|open|approved)$'     { return 'notstarted' }
        default                                     { return 'inprogress' }
    }
}

# --- Pure: pace verdict ----------------------------------------------------

function Get-PaceVerdict {
    <#
        Compares completion fraction against elapsed-time fraction.
        Returns Verdict / Color / Gap (gap = elapsed - completion; positive = behind).
    #>
    param([double]$CompletionFraction, [double]$ElapsedFraction)
    $gap = [Math]::Round($ElapsedFraction - $CompletionFraction, 4)
    if ($gap -le 0.05) {
        $v = if ($CompletionFraction -ge ($ElapsedFraction + 0.10)) { 'Ahead of schedule' } else { 'On track' }
        return [pscustomobject]@{ Verdict = $v; Color = '#0f7a3c'; Gap = $gap }
    }
    if ($gap -le 0.20) {
        return [pscustomobject]@{ Verdict = 'Behind'; Color = '#8a5a00'; Gap = $gap }
    }
    return [pscustomobject]@{ Verdict = 'Well behind'; Color = '#b42318'; Gap = $gap }
}

function Get-AssigneeName {
    param($Item)
    $a = $null
    if ($Item.PSObject.Properties.Name -contains 'AssignedTo') { $a = $Item.AssignedTo }
    if ([string]::IsNullOrWhiteSpace($a)) { return 'Unassigned' }
    return $a
}

# --- HTML helpers ----------------------------------------------------------

function Format-SdField {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $h = [System.Net.WebUtility]::HtmlEncode($Text)
    return [System.Text.RegularExpressions.Regex]::Replace($h, '\r\n|\r|\n', '<br>')
}

function Format-Pct {
    param([double]$Fraction)
    return ('{0}%' -f [Math]::Round($Fraction * 100))
}

function Render-PaceRibbon {
    <#
        $Pace fields: ElapsedFraction, CompletionFraction, BaselineFraction (nullable),
        ElapsedDays, TotalDays, Done, Total, BaselineDone, BaselineTotal, AddedSinceStart,
        WorkingDaysLeft, Verdict, Color.
    #>
    param($Pace)
    $verdictBadge = "<span style='display:inline-block;padding:3px 10px;border-radius:12px;background:$($Pace.Color);color:#fff;font-weight:600;font-size:13px'>$($Pace.Verdict)</span>"
    $dayWord = if ($Pace.WorkingDaysLeft -eq 1) { 'day' } else { 'days' }
    $html  = "<div style='border:1px solid #e3e3e3;border-left:4px solid $($Pace.Color);border-radius:6px;padding:12px 14px;margin:8px 0 14px 0;background:#fafafa'>"
    $html += "<div style='font-size:14px;margin-bottom:6px'>$verdictBadge &nbsp; <span style='color:#5c5c5c'>$($Pace.WorkingDaysLeft) working $dayWord left in the sprint</span></div>"
    $html += "<table style='border-collapse:collapse;font-size:13px'>"
    $html += "<tr><td style='padding:2px 14px 2px 0;color:#5c5c5c'>Time elapsed</td><td style='padding:2px 0;font-weight:600'>$(Format-Pct $Pace.ElapsedFraction) <span style='color:#919191;font-weight:400'>($($Pace.ElapsedDays)/$($Pace.TotalDays) working days)</span></td></tr>"
    $html += "<tr><td style='padding:2px 14px 2px 0;color:#5c5c5c'>Work done (current scope)</td><td style='padding:2px 0;font-weight:600'>$(Format-Pct $Pace.CompletionFraction) <span style='color:#919191;font-weight:400'>($($Pace.Done)/$($Pace.Total) Tasks+Bugs)</span></td></tr>"
    if ($null -ne $Pace.BaselineFraction) {
        $addNote = if ($Pace.AddedSinceStart -gt 0) { " &middot; $($Pace.AddedSinceStart) added since sprint start" } else { '' }
        $html += "<tr><td style='padding:2px 14px 2px 0;color:#5c5c5c'>Work done (baseline scope)</td><td style='padding:2px 0;font-weight:600'>$(Format-Pct $Pace.BaselineFraction) <span style='color:#919191;font-weight:400'>($($Pace.BaselineDone)/$($Pace.BaselineTotal))$addNote</span></td></tr>"
    }
    $html += "</table></div>"
    return $html
}

function Render-ItemTable {
    param(
        [string]   $Heading,
        [object[]] $Items,
        [int]      $Cap = 20
    )
    $count = @($Items).Count
    $html = "<h3 style='margin:16px 0 6px 0;font-size:15px;color:#242424'>$Heading ($count)</h3>"
    if ($count -eq 0) {
        return $html + "<p style='color:#6f6f6f;font-style:italic;margin:0 0 8px 0'>None.</p>"
    }
    $shown = @($Items | Select-Object -First $Cap)
    $html += "<table style='border-collapse:collapse;width:100%;font-size:13px'>"
    $html += "<thead><tr style='text-align:left;color:#5c5c5c;border-bottom:1px solid #dedede'>" +
             "<th style='padding:6px 10px 6px 0;width:62px'>ID</th>" +
             "<th style='padding:6px 10px;width:64px'>Type</th>" +
             "<th style='padding:6px 10px;width:120px'>State</th>" +
             "<th style='padding:6px 10px;width:140px'>Assignee</th>" +
             "<th style='padding:6px 10px'>Title</th>" +
             "</tr></thead><tbody>"
    foreach ($it in $shown) {
        $html += "<tr style='border-bottom:1px solid #f0f0f0;vertical-align:top'>" +
                 "<td style='padding:6px 10px 6px 0;font-family:Consolas,Courier New,monospace;color:#0067b8'>$(Format-SdField ([string]$it.Id))</td>" +
                 "<td style='padding:6px 10px;color:#5c5c5c'>$(Format-SdField $it.Type)</td>" +
                 "<td style='padding:6px 10px;color:#5c5c5c'>$(Format-SdField $it.State)</td>" +
                 "<td style='padding:6px 10px;color:#5c5c5c'>$(Format-SdField (Get-AssigneeName $it))</td>" +
                 "<td style='padding:6px 10px;color:#242424'>$(Format-SdField $it.Title)</td>" +
                 "</tr>"
    }
    $html += "</tbody></table>"
    if ($count -gt $Cap) {
        $html += "<p style='color:#919191;font-size:12px;margin:4px 0 0 0'>... and $($count - $Cap) more.</p>"
    }
    return $html
}

function Render-ByPersonTable {
    # $Rows: pscustomobject Person / NotStarted / InProgress / Done / Total, pre-sorted.
    param([object[]] $Rows)
    $html = "<h3 style='margin:16px 0 6px 0;font-size:15px;color:#242424'>By person</h3>"
    if (-not $Rows -or @($Rows).Count -eq 0) {
        return $html + "<p style='color:#6f6f6f;font-style:italic'>No assigned Tasks/Bugs.</p>"
    }
    $html += "<table style='border-collapse:collapse;font-size:13px'>"
    $html += "<thead><tr style='text-align:left;color:#5c5c5c;border-bottom:1px solid #dedede'>" +
             "<th style='padding:6px 14px 6px 0'>Assignee</th>" +
             "<th style='padding:6px 12px;text-align:right'>Not started</th>" +
             "<th style='padding:6px 12px;text-align:right'>In progress</th>" +
             "<th style='padding:6px 12px;text-align:right'>Done</th>" +
             "<th style='padding:6px 12px;text-align:right'>Total</th>" +
             "</tr></thead><tbody>"
    foreach ($r in $Rows) {
        $html += "<tr style='border-bottom:1px solid #f0f0f0'>" +
                 "<td style='padding:6px 14px 6px 0;color:#242424'>$(Format-SdField $r.Person)</td>" +
                 "<td style='padding:6px 12px;text-align:right;color:#5c5c5c'>$($r.NotStarted)</td>" +
                 "<td style='padding:6px 12px;text-align:right;color:#5c5c5c'>$($r.InProgress)</td>" +
                 "<td style='padding:6px 12px;text-align:right;color:#0f7a3c'>$($r.Done)</td>" +
                 "<td style='padding:6px 12px;text-align:right;font-weight:600'>$($r.Total)</td>" +
                 "</tr>"
    }
    $html += "</tbody></table>"
    return $html
}

function Render-DeltaPanel {
    # $Delta: Completed / Added / Removed / Reopened arrays of label strings; $HasPrev bool.
    param($Delta, [bool]$HasPrev)
    $html = "<h3 style='margin:16px 0 6px 0;font-size:15px;color:#242424'>Since last digest</h3>"
    if (-not $HasPrev) {
        return $html + "<p style='color:#6f6f6f;font-style:italic'>First digest for this sprint &mdash; no prior snapshot to diff.</p>"
    }
    $rows = @(
        @{ Label = 'Completed'; Items = $Delta.Completed; Color = '#0f7a3c' },
        @{ Label = 'Added';     Items = $Delta.Added;     Color = '#0067b8' },
        @{ Label = 'Removed';   Items = $Delta.Removed;   Color = '#919191' },
        @{ Label = 'Reopened';  Items = $Delta.Reopened;  Color = '#b42318' }
    )
    $any = $false
    $body = "<ul style='margin:4px 0;padding-left:18px;color:#5c5c5c;font-size:13px'>"
    foreach ($r in $rows) {
        $items = @($r.Items)
        if ($items.Count -eq 0) { continue }
        $any = $true
        $sample = ($items | Select-Object -First 8) -join ', '
        if ($items.Count -gt 8) { $sample += ", ... (+$($items.Count - 8))" }
        $body += "<li><span style='color:$($r.Color);font-weight:600'>$($r.Label) ($($items.Count)):</span> $(Format-SdField $sample)</li>"
    }
    $body += "</ul>"
    if (-not $any) {
        return $html + "<p style='color:#6f6f6f;font-style:italic'>No item changes since the last digest.</p>"
    }
    return $html + $body
}
