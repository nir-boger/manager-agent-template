# Shared HTML rendering for the team-agenda email body.
#
# Both run-team-agenda-reminder.ps1 (Mon to Nir) and
# run-team-meeting-reminder.ps1 (Tue pre-meeting to team@) call
# Render-TwoTableAgenda below to produce a Discussion + Follow-up split.
#
# ASCII-only source (PS 5.1 parses .ps1 via CP1252).

function Format-AgendaField {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $h = [System.Net.WebUtility]::HtmlEncode($Text)
    # Convert paired `x` to <code>x</code> for readability.
    $h = [System.Text.RegularExpressions.Regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
    # Honour real line breaks the author typed (Summary / Next step can wrap).
    return [System.Text.RegularExpressions.Regex]::Replace($h, '\r\n|\r|\n', '<br>')
}

function Get-AgendaKind {
    # Returns 'follow-up' if the entry's Kind field, case-insensitively trimmed,
    # starts with 'follow' or 'fu'. Anything else (including missing/blank) -> 'discussion'.
    param($Item)
    $k = ''
    if ($Item.PSObject.Properties.Name -contains 'Kind') { $k = [string]$Item.Kind }
    $k = $k.Trim().ToLower()
    if ($k -like 'follow*' -or $k -eq 'fu') { return 'follow-up' }
    return 'discussion'
}

function Render-AgendaTable {
    param(
        [string]   $Heading,
        [object[]] $Items,
        [string]   $EmptyText
    )
    $html = "<h3 style='margin:18px 0 6px 0;font-size:15px;color:#242424'>$Heading</h3>"
    if (-not $Items -or $Items.Count -eq 0) {
        return $html + "<p style='color:#6f6f6f;font-style:italic;margin:0 0 8px 0'>$EmptyText</p>"
    }
    $html += "<table style='border-collapse:collapse;width:100%;font-size:13px'>"
    $html += "<thead><tr style='text-align:left;color:#5c5c5c;border-bottom:1px solid #dedede'>" +
             "<th style='padding:6px 10px 6px 0;width:62px;white-space:nowrap'>ID</th>" +
             "<th style='padding:6px 10px;width:96px;white-space:nowrap'>Opened by</th>" +
             "<th style='padding:6px 10px'>Item</th>" +
             "</tr></thead>"
    $html += "<tbody>"
    foreach ($it in $Items) {
        $id    = Format-AgendaField $it.Id
        $by    = if ($it.OpenedBy) { Format-AgendaField $it.OpenedBy } else { 'unknown' }
        $on    = if ($it.OpenedOn) { Format-AgendaField $it.OpenedOn } else { '' }
        $title = Format-AgendaField $it.Title
        $summ  = if ($it.Summary)  { Format-AgendaField $it.Summary }  else { '' }
        $next  = if ($it.NextStep) { Format-AgendaField $it.NextStep } else { '' }

        $whenBlock = if ($on) { "<div style='color:#919191;font-size:11px;margin-top:2px'>$on</div>" } else { '' }
        $bodyBlock = "<div style='font-weight:600;color:#242424'>$title</div>"
        if ($summ) { $bodyBlock += "<div style='color:#5c5c5c;margin-top:3px'>$summ</div>" }
        if ($next) { $bodyBlock += "<div style='color:#5c5c5c;margin-top:3px'><em>Next step:</em> $next</div>" }

        $html += "<tr style='border-bottom:1px solid #f0f0f0;vertical-align:top'>" +
                 "<td style='padding:8px 10px 8px 0;font-family:Consolas,Courier New,monospace;color:#b11f4b'><strong>$id</strong></td>" +
                 "<td style='padding:8px 10px;color:#5c5c5c;white-space:nowrap'>$by$whenBlock</td>" +
                 "<td style='padding:8px 10px'>$bodyBlock</td>" +
                 "</tr>"
    }
    $html += "</tbody></table>"
    return $html
}

function Render-TwoTableAgenda {
    <#
        .DESCRIPTION
        Renders two HTML tables: Discussion (proposals/new debate) and
        Follow-up (items previously raised, tracking status).
        Items missing the Kind field default to Discussion.
        Empty kinds render an italic empty-state line, not an empty table.
    #>
    param(
        [object[]] $Items
    )
    if ($null -eq $Items) { $Items = @() }
    $discuss   = @($Items | Where-Object { (Get-AgendaKind $_) -eq 'discussion' })
    $followUps = @($Items | Where-Object { (Get-AgendaKind $_) -eq 'follow-up' })
    $out  = ''
    $out += Render-AgendaTable -Heading ("Things to discuss ({0})" -f $discuss.Count)   -Items $discuss   -EmptyText 'No new discussion items this round.'
    $out += Render-AgendaTable -Heading ("Follow-ups ({0})"        -f $followUps.Count) -Items $followUps -EmptyText 'No follow-ups outstanding.'
    return $out
}

function Get-AgendaCounts {
    <#
        .DESCRIPTION
        Returns a pscustomobject with Discuss / FollowUp / Total counts.
        Used to build the email subject line.
    #>
    param([object[]] $Items)
    if ($null -eq $Items) { $Items = @() }
    $d = @($Items | Where-Object { (Get-AgendaKind $_) -eq 'discussion' }).Count
    $f = @($Items | Where-Object { (Get-AgendaKind $_) -eq 'follow-up'  }).Count
    return [pscustomobject]@{ Discuss = $d; FollowUp = $f; Total = $d + $f }
}

function Format-AgendaSubjectTail {
    <#
        .DESCRIPTION
        Builds the human-readable count tail for an email subject.
        Examples:
          - 3 follow-ups, 2 to discuss
          - 1 to discuss
          - 1 follow-up
          - empty -> "nothing tracked"
        Reads like a sentence; follow-ups first when present (they tend to be the
        urgency signal pre-meeting).
    #>
    param([object[]] $Items)
    $c = Get-AgendaCounts -Items $Items
    if ($c.Total -eq 0) { return 'nothing tracked' }
    $parts = @()
    if ($c.FollowUp -gt 0) {
        $parts += if ($c.FollowUp -eq 1) { '1 follow-up' } else { "$($c.FollowUp) follow-ups" }
    }
    if ($c.Discuss -gt 0) {
        $parts += if ($c.Discuss -eq 1) { '1 to discuss' } else { "$($c.Discuss) to discuss" }
    }
    return ($parts -join ', ')
}

