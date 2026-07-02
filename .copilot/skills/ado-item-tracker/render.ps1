# ado-item-tracker render helpers (dot-sourced by run-ado-item-tracker.ps1).
#
# Pure functions only -- no side effects, no sends. Builds the HTML fragments
# for the daily digest table, the hourly update panel, and the ping-owner note,
# plus small formatting helpers (status class/colour, relative time, encode).
#
# The runner wraps the returned BodyHtml fragment; Send-NirvanaMessage appends
# the canonical Nirvana signature, so these functions never emit a signature.

function ConvertTo-AtHtml {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return ([string]$Text).
        Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').
        Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-AtStateClass {
    param([string] $State)
    $s = ([string]$State).Trim().ToLowerInvariant()
    switch -Regex ($s) {
        '^(done|closed|resolved|completed)$'                 { return 'done' }
        '^(removed|cut)$'                                    { return 'removed' }
        '^(to do|new|proposed|open|approved|backlog)$'       { return 'notstarted' }
        default                                              { return 'inprogress' }
    }
}

function Get-AtStatusPill {
    # Coloured inline pill for a work-item state.
    param([string] $State)
    $class = Get-AtStateClass -State $State
    $palette = @{
        done       = @{ bg = '#e6f4ea'; fg = '#137333' }
        inprogress = @{ bg = '#e8f0fe'; fg = '#1967d2' }
        notstarted = @{ bg = '#f1f3f4'; fg = '#5f6368' }
        removed    = @{ bg = '#fce8e6'; fg = '#c5221f' }
    }
    $c = $palette[$class]
    $label = ConvertTo-AtHtml ([string]$State)
    if (-not $label) { $label = '&mdash;' }
    return "<span style='display:inline-block;padding:2px 9px;border-radius:11px;font-size:12px;font-weight:600;background:$($c.bg);color:$($c.fg)'>$label</span>"
}

function Format-AtRelative {
    # "3h ago" / "2d ago" / "May 4" from an ISO timestamp. Empty -> em dash.
    param([string] $Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '&mdash;' }
    try { $dt = [datetime]::Parse($Iso).ToLocalTime() } catch { return '&mdash;' }
    $span = (Get-Date) - $dt
    if ($span.TotalSeconds -lt 0)    { return $dt.ToString('MMM d') }
    if ($span.TotalMinutes -lt 60)   { return ('{0}m ago' -f [int][Math]::Max(1, $span.TotalMinutes)) }
    if ($span.TotalHours   -lt 24)   { return ('{0}h ago' -f [int]$span.TotalHours) }
    if ($span.TotalDays    -lt 7)    { return ('{0}d ago' -f [int]$span.TotalDays) }
    return $dt.ToString('MMM d')
}

function Get-AtOwnerCell {
    param([string] $Owner)
    if ([string]::IsNullOrWhiteSpace($Owner)) {
        return "<span style='color:#c5221f'>Unassigned</span>"
    }
    return ConvertTo-AtHtml $Owner
}

function Render-AtTable {
    # The main digest / board table. $Items is a list of normalized work items:
    #   Id, Title, Type, Owner, State, Url, ChangedDate, Note
    param([object[]] $Items)
    if (-not $Items -or $Items.Count -eq 0) {
        return "<p style='color:#5f6368;font-size:13px'>No work items are being tracked. Tell me <code>track ADO &lt;id&gt;</code> to add one.</p>"
    }
    $th = "style='text-align:left;padding:7px 10px;border-bottom:2px solid #e0e0e0;font-size:12px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em'"
    $head = "<tr><th $th>Item</th><th $th>Title</th><th $th>Type</th><th $th>Owner</th><th $th>Status</th><th $th>Updated</th></tr>"

    $rows = foreach ($it in $Items) {
        $td      = "style='padding:8px 10px;border-bottom:1px solid #efefef;font-size:13px;vertical-align:top'"
        $idChip  = "<a href='$($it.Url)' style='font-family:Consolas,monospace;font-size:12px;color:#1967d2;text-decoration:none;white-space:nowrap'>#$($it.Id)</a>"
        $title   = "<a href='$($it.Url)' style='color:#202124;text-decoration:none;font-weight:600'>$(ConvertTo-AtHtml $it.Title)</a>"
        $noteRaw = if ($it.PSObject.Properties['Note']) { [string]$it.Note } else { '' }
        if ($noteRaw) { $title += "<div style='color:#5f6368;font-size:12px;margin-top:2px'>$(ConvertTo-AtHtml $noteRaw)</div>" }
        $type    = ConvertTo-AtHtml $it.Type
        $owner   = Get-AtOwnerCell $it.Owner
        $status  = Get-AtStatusPill $it.State
        $updated = Format-AtRelative $it.ChangedDate
        "<tr><td $td>$idChip</td><td $td>$title</td><td $td>$type</td><td $td>$owner</td><td $td>$status</td><td $td style='color:#5f6368;white-space:nowrap'>$updated</td></tr>"
    }

    return "<table style='border-collapse:collapse;width:100%;margin:6px 0 10px 0'><thead>$head</thead><tbody>$($rows -join '')</tbody></table>"
}

function Render-AtUpdatePanel {
    # Hourly-watch change summary. $Changes is a list of:
    #   Id, Title, Url, Lines (string[] describing what changed)
    param([object[]] $Changes)
    if (-not $Changes -or $Changes.Count -eq 0) { return '' }
    $blocks = foreach ($c in $Changes) {
        $lines = foreach ($l in $c.Lines) { "<li style='margin:1px 0'>$(ConvertTo-AtHtml $l)</li>" }
        "<div style='margin:0 0 12px 0;padding:10px 12px;border-left:3px solid #1967d2;background:#f8f9fb;border-radius:4px'>" +
        "<div style='font-weight:600;margin-bottom:3px'><a href='$($c.Url)' style='color:#1967d2;text-decoration:none'>#$($c.Id)</a> &nbsp;$(ConvertTo-AtHtml $c.Title)</div>" +
        "<ul style='margin:4px 0 0 0;padding-left:18px;color:#3c4043;font-size:13px'>$($lines -join '')</ul></div>"
    }
    return ($blocks -join '')
}

function Get-AtDigestJoke {
    param([int] $Count)
    $bank = @(
        "Tracking $Count item$(if($Count -ne 1){'s'}) so you don't have to keep 47 ADO tabs open like a digital hoarder.",
        "Status columns: where 'In Progress' goes to think about its life choices.",
        "A watched work item never boils &mdash; but it does, apparently, change state when you blink.",
        "Your ADO items, lined up and accounted for. The build is another conversation.",
        "If a tracked item moves to Done and nobody emails about it, did it really resolve?"
    )
    if ($Count -le 0) { return "An empty tracker is a peaceful tracker. Add one with 'track ADO <id>'." }
    return ($bank | Get-Random)
}

function Get-AtWatchJoke {
    param([int] $Count)
    $bank = @(
        "$Count update$(if($Count -ne 1){'s'}) since last hour &mdash; someone's been busy, or the field auto-rules have.",
        "Movement detected. Either real progress or a very enthusiastic bulk edit.",
        "State changed faster than a sprint commitment. Worth a glance.",
        "Fresh activity on your watchlist &mdash; served warm, no refresh button required."
    )
    return ($bank | Get-Random)
}

function Get-AtPingJoke {
    $bank = @(
        "No pressure &mdash; just a friendly nudge from a robot who genuinely enjoys a tidy status field.",
        "Reply at your convenience; the work item and I will be right here, refreshing.",
        "A one-line status now saves a three-question thread later. Math checks out."
    )
    return ($bank | Get-Random)
}
