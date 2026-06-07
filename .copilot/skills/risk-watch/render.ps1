# Shared HTML rendering for the risk-watch weekly pulse email.
#
# run-risk-watch-pulse.ps1 dot-sources this to render the Red + Amber risk
# tables (Green omitted with a count), with overdue checkpoints flagged and
# sorted first.
#
# ASCII-only source (PS 5.1 parses .ps1 via CP1252). Non-ASCII via HTML entities.

function Format-RiskField {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $h = [System.Net.WebUtility]::HtmlEncode($Text)
    $h = [System.Text.RegularExpressions.Regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
    return [System.Text.RegularExpressions.Regex]::Replace($h, '\r\n|\r|\n', '<br>')
}

function Get-RiskRag {
    # Normalize an item's Risk field to 'red' | 'amber' | 'green'.
    # Missing / unknown defaults to 'amber' (an unclassified risk deserves a look).
    param($Item)
    $r = ''
    if ($Item.PSObject.Properties.Name -contains 'Risk') { $r = [string]$Item.Risk }
    $r = $r.Trim().ToLower()
    switch -regex ($r) {
        '^r(ed)?$'            { return 'red' }
        '^(a(mber)?|y(ellow)?)$' { return 'amber' }
        '^g(reen)?$'          { return 'green' }
        default               { return 'amber' }
    }
}

function Get-RiskCheckpointInfo {
    <#
        Returns a pscustomobject describing the Next checkpoint relative to Today:
          DaysTo  - integer days until checkpoint (negative = overdue);
                    [int]::MaxValue when there is no parseable checkpoint (sorts last).
          Label   - human badge: 'Overdue Nd', 'Due this week', 'by YYYY-MM-DD', 'no checkpoint'.
          Kind    - 'overdue' | 'soon' | 'scheduled' | 'none' (drives badge color).
    #>
    param(
        $Item,
        [DateTime]$Today
    )
    $raw = ''
    if ($Item.PSObject.Properties.Name -contains 'NextCheckpoint') { $raw = [string]$Item.NextCheckpoint }
    $raw = $raw.Trim()
    $parsed = $null
    if ($raw -and $raw -ne '-') {
        [DateTime]$tmp = [DateTime]::MinValue
        if ([DateTime]::TryParse($raw, [ref]$tmp)) { $parsed = $tmp.Date }
    }
    if ($null -eq $parsed) {
        return [pscustomobject]@{ DaysTo = [int]::MaxValue; Label = 'no checkpoint'; Kind = 'none' }
    }
    $days = ($parsed - $Today.Date).Days
    if ($days -lt 0) {
        $n = [Math]::Abs($days)
        $unit = if ($n -eq 1) { 'day' } else { 'days' }
        return [pscustomobject]@{ DaysTo = $days; Label = ("overdue {0} {1}" -f $n, $unit); Kind = 'overdue' }
    }
    if ($days -le 7) {
        return [pscustomobject]@{ DaysTo = $days; Label = 'due this week'; Kind = 'soon' }
    }
    return [pscustomobject]@{ DaysTo = $days; Label = ("by {0}" -f $parsed.ToString('yyyy-MM-dd')); Kind = 'scheduled' }
}

function Get-RiskCounts {
    param([object[]] $Items)
    if ($null -eq $Items) { $Items = @() }
    $red   = @($Items | Where-Object { (Get-RiskRag $_) -eq 'red' }).Count
    $amber = @($Items | Where-Object { (Get-RiskRag $_) -eq 'amber' }).Count
    $green = @($Items | Where-Object { (Get-RiskRag $_) -eq 'green' }).Count
    return [pscustomobject]@{ Red = $red; Amber = $amber; Green = $green; Total = $red + $amber + $green }
}

function Format-RiskSubjectTail {
    <#
        Human-readable count tail for the email subject.
          - "2 red, 1 amber"
          - "1 amber"
          - "all green" (no red/amber but green tracked)
          - "nothing tracked" (zero open)
    #>
    param([object[]] $Items)
    $c = Get-RiskCounts -Items $Items
    if ($c.Total -eq 0) { return 'nothing tracked' }
    $parts = @()
    if ($c.Red   -gt 0) { $parts += "$($c.Red) red" }
    if ($c.Amber -gt 0) { $parts += "$($c.Amber) amber" }
    if ($parts.Count -eq 0) { return 'all green' }
    return ($parts -join ', ')
}

function Render-RiskTable {
    param(
        [string]   $Heading,
        [string]   $AccentColor,
        [object[]] $Items,
        [DateTime] $Today
    )
    $html = "<h3 style='margin:18px 0 6px 0;font-size:15px;color:#242424'>$Heading</h3>"
    if (-not $Items -or $Items.Count -eq 0) {
        return $html + "<p style='color:#6f6f6f;font-style:italic;margin:0 0 8px 0'>None in this band.</p>"
    }

    # Decorate with checkpoint info, then sort: overdue (most negative) first,
    # then nearest checkpoint, then ID.
    $decorated = foreach ($it in $Items) {
        $cp = Get-RiskCheckpointInfo -Item $it -Today $Today
        [pscustomobject]@{ Item = $it; Cp = $cp }
    }
    $decorated = @($decorated | Sort-Object @{ Expression = { $_.Cp.DaysTo } }, @{ Expression = { $_.Item.Id } })

    $html += "<table style='border-collapse:collapse;width:100%;font-size:13px'>"
    $html += "<thead><tr style='text-align:left;color:#5c5c5c;border-bottom:1px solid #dedede'>" +
             "<th style='padding:6px 10px 6px 0;width:62px;white-space:nowrap'>ID</th>" +
             "<th style='padding:6px 10px;width:120px;white-space:nowrap'>Owner / Area</th>" +
             "<th style='padding:6px 10px'>Risk</th>" +
             "<th style='padding:6px 10px;width:130px;white-space:nowrap'>Checkpoint</th>" +
             "</tr></thead><tbody>"

    foreach ($d in $decorated) {
        $it = $d.Item
        $cp = $d.Cp
        $id    = Format-RiskField $it.Id
        $owner = if ($it.Owner) { Format-RiskField $it.Owner } else { 'TBD' }
        $area  = if ($it.Area)  { Format-RiskField $it.Area }  else { '' }
        $title = Format-RiskField $it.Title
        $why   = if ($it.Why)        { Format-RiskField $it.Why }        else { '' }
        $mit   = if ($it.Mitigation) { Format-RiskField $it.Mitigation } else { '' }

        $ownerBlock = "<div style='color:#242424'>$owner</div>"
        if ($area) { $ownerBlock += "<div style='color:#919191;font-size:11px;margin-top:2px'>$area</div>" }

        $bodyBlock = "<div style='font-weight:600;color:#242424'>$title</div>"
        if ($why) { $bodyBlock += "<div style='color:#5c5c5c;margin-top:3px'>$why</div>" }
        if ($mit -and $mit -ne '-') { $bodyBlock += "<div style='color:#5c5c5c;margin-top:3px'><em>Mitigation:</em> $mit</div>" }

        $cpColor = switch ($cp.Kind) {
            'overdue'   { '#b11f4b' }
            'soon'      { '#8a5a00' }
            'none'      { '#919191' }
            default     { '#5c5c5c' }
        }
        $cpWeight = if ($cp.Kind -eq 'overdue') { '700' } else { '400' }
        $cpBlock = "<span style='color:$cpColor;font-weight:$cpWeight'>$(Format-RiskField $cp.Label)</span>"

        $html += "<tr style='border-bottom:1px solid #f0f0f0;vertical-align:top'>" +
                 "<td style='padding:8px 10px 8px 0;font-family:Consolas,Courier New,monospace;color:$AccentColor'><strong>$id</strong></td>" +
                 "<td style='padding:8px 10px;color:#5c5c5c;white-space:nowrap'>$ownerBlock</td>" +
                 "<td style='padding:8px 10px'>$bodyBlock</td>" +
                 "<td style='padding:8px 10px;white-space:nowrap'>$cpBlock</td>" +
                 "</tr>"
    }
    $html += "</tbody></table>"
    return $html
}

function Render-RiskPulse {
    <#
        .DESCRIPTION
        Renders the Red table then the Amber table (each sorted by checkpoint
        urgency). Green risks are omitted from the tables; a one-line count is
        appended so Nir knows they are still tracked.
    #>
    param(
        [object[]] $Items,
        [DateTime] $Today
    )
    if ($null -eq $Items) { $Items = @() }
    if ($null -eq $Today) { $Today = (Get-Date).Date }

    $red   = @($Items | Where-Object { (Get-RiskRag $_) -eq 'red' })
    $amber = @($Items | Where-Object { (Get-RiskRag $_) -eq 'amber' })
    $green = @($Items | Where-Object { (Get-RiskRag $_) -eq 'green' })

    $out  = ''
    $out += Render-RiskTable -Heading ("Red ({0})"   -f $red.Count)   -AccentColor '#b11f4b' -Items $red   -Today $Today
    $out += Render-RiskTable -Heading ("Amber ({0})" -f $amber.Count) -AccentColor '#8a5a00' -Items $amber -Today $Today

    if ($green.Count -gt 0) {
        $plural = if ($green.Count -eq 1) { 'risk' } else { 'risks' }
        $out += "<p style='color:#6f6f6f;font-size:12px;margin-top:12px'>Green $plural omitted from the tables: $($green.Count) (still tracked in the register).</p>"
    }
    return $out
}
