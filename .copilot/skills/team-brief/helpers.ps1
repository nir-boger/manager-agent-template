#requires -Version 5.1
# Pure helpers for the team-brief skill (daily team brief + weekly highlights).
#
# This file is ASCII-only (PS 5.1 .ps1 source-file constraint). All non-ASCII
# glyphs in rendered output go through HTML entities (&mdash; &middot; etc.).
#
# No I/O, no Outlook, no global state. Everything here is deterministic and
# unit-testable. The runner (run-team-brief.ps1) owns config, sources, COM send,
# state, and logging.

# ---- Timezone -------------------------------------------------------------

function Get-IsraelTimeZone {
    foreach ($id in @('Israel Standard Time', 'Asia/Jerusalem')) {
        try { return [System.TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { }
    }
    return [System.TimeZoneInfo]::CreateCustomTimeZone('IL-fallback', [TimeSpan]::FromHours(2), 'IL', 'IL')
}

# Convert a local Israel wall-clock datetime to a UTC DateTimeOffset (DST-aware).
function ConvertTo-UtcFromIsrael {
    param([Parameter(Mandatory)][datetime] $Local, [System.TimeZoneInfo] $Tz)
    if (-not $Tz) { $Tz = Get-IsraelTimeZone }
    $unspecified = [datetime]::SpecifyKind($Local, [System.DateTimeKind]::Unspecified)
    $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($unspecified, $Tz)
    return [System.DateTimeOffset]::new($utc, [TimeSpan]::Zero)
}

# Daily window: half-open [coverStart 00:00 IST, targetDate+1 00:00 IST) in UTC.
function Get-DailyWindow {
    param(
        [Parameter(Mandatory)][datetime] $TargetDate,
        [datetime] $CoverStart,
        [System.TimeZoneInfo] $Tz
    )
    if (-not $Tz) { $Tz = Get-IsraelTimeZone }
    $target = $TargetDate.Date
    if (-not $CoverStart) { $CoverStart = $target } else { $CoverStart = $CoverStart.Date }
    if ($CoverStart -gt $target) { $CoverStart = $target }

    $startUtc = ConvertTo-UtcFromIsrael -Local $CoverStart        -Tz $Tz
    $endUtc   = ConvertTo-UtcFromIsrael -Local $target.AddDays(1) -Tz $Tz   # exclusive

    $dates = @()
    $d = $CoverStart
    while ($d -le $target) { $dates += $d.ToString('yyyy-MM-dd'); $d = $d.AddDays(1) }

    return [pscustomobject]@{
        StartUtc = $startUtc; EndUtc = $endUtc
        StartLocal = $CoverStart; EndLocal = $target; Dates = $dates
    }
}

# Weekly window for the Israeli work week (Sun..Thu) that CONTAINS the anchor.
function Get-WeeklyWindow {
    param(
        [Parameter(Mandatory)][datetime] $Anchor,
        [System.TimeZoneInfo] $Tz
    )
    if (-not $Tz) { $Tz = Get-IsraelTimeZone }
    $a = $Anchor.Date
    $sunday = $a.AddDays(-1 * [int]$a.DayOfWeek)   # Sunday=0
    $friday = $sunday.AddDays(5)                   # exclusive end (Sun..Thu)

    $startUtc = ConvertTo-UtcFromIsrael -Local $sunday -Tz $Tz
    $endUtc   = ConvertTo-UtcFromIsrael -Local $friday -Tz $Tz

    $dates = @()
    for ($i = 0; $i -lt 5; $i++) { $dates += $sunday.AddDays($i).ToString('yyyy-MM-dd') }

    return [pscustomobject]@{
        StartUtc = $startUtc; EndUtc = $endUtc
        StartLocal = $sunday; EndLocal = $sunday.AddDays(4); Dates = $dates
    }
}

# ---- HTML safety ----------------------------------------------------------

function ConvertTo-HtmlText {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

# ---- PR / observation filtering ------------------------------------------

function Test-PrInWindow {
    param(
        [string] $CreatedIso,
        [Parameter(Mandatory)][System.DateTimeOffset] $StartUtc,
        [Parameter(Mandatory)][System.DateTimeOffset] $EndUtc
    )
    if ([string]::IsNullOrWhiteSpace($CreatedIso)) { return $false }
    $parsed = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $ok = [System.DateTimeOffset]::TryParse($CreatedIso, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)
    if (-not $ok) { return $false }
    return ($parsed -ge $StartUtc -and $parsed -lt $EndUtc)
}

# Parse "## Daily observations" lines from a persona file for the given dates.
function Get-PersonObservations {
    param([string] $Content, [string[]] $Dates)
    $out = @()
    if ([string]::IsNullOrEmpty($Content)) { return $out }
    $idx = $Content.IndexOf('## Daily observations')
    if ($idx -lt 0) { return $out }
    $rest = $Content.Substring($idx)
    $nextH2 = [regex]::Match($rest.Substring(5), '(?m)^##\s')
    if ($nextH2.Success) { $rest = $rest.Substring(0, $nextH2.Index + 5) }

    foreach ($line in ($rest -split "`n")) {
        $m = [regex]::Match($line, '^\s*-\s*(\d{4}-\d{2}-\d{2})\s*\(([^)]*)\):\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        $date = $m.Groups[1].Value
        if ($Dates -and ($Dates -notcontains $date)) { continue }
        $tag  = $m.Groups[2].Value
        $text = $m.Groups[3].Value
        $text = [regex]::Replace($text, '\s*\[src:[^\]]*\]\s*$', '')
        $kind = if ($tag -match 'behavioral') { 'behavioral' } else { 'thread' }
        if ($kind -eq 'thread') {
            $text = [regex]::Replace($text, '^top email threads\s*[-\u2014:]*\s*', '')
        }
        $out += [pscustomobject]@{ Date = $date; Kind = $kind; Text = $text }
    }
    return $out
}

# ---- Aggregation ----------------------------------------------------------

function Get-TeamBriefData {
    param(
        [Parameter(Mandatory)] $Directs,
        [string]  $PeopleDir,
        [Parameter(Mandatory)][System.DateTimeOffset] $StartUtc,
        [Parameter(Mandatory)][System.DateTimeOffset] $EndUtc,
        [string[]] $Dates,
        $Enrichment   # hashtable: alias -> @{ daily = '...'; weekly = '...' }
    )
    $aliases = @($Directs.PSObject.Properties.Name)
    $people  = @()
    $personasImported = 0

    foreach ($alias in $aliases) {
        $p = $Directs.$alias

        # CRITICAL: attribute PRs by role. role=author  -> the person OPENED it.
        #           role=reviewer -> the person REVIEWED it. Mixing the two is the
        #           bug that made us credit a reviewer with authoring a PR.
        $authored = @(); $reviewed = @()
        $seenA = @{}; $seenR = @{}
        foreach ($pr in @($p.recent_prs)) {
            if (-not $pr) { continue }
            if (-not (Test-PrInWindow -CreatedIso $pr.created -StartUtc $StartUtc -EndUtc $EndUtc)) { continue }
            $id = [string]$pr.id
            if ($pr.role -eq 'author') {
                if (-not $seenA.ContainsKey($id)) { $seenA[$id] = $true; $authored += $pr }
            } elseif ($pr.role -eq 'reviewer') {
                if (-not $seenR.ContainsKey($id)) { $seenR[$id] = $true; $reviewed += $pr }
            }
        }

        $obs = @()
        if ($PeopleDir) {
            $pf = Join-Path $PeopleDir ("$alias.md")
            if (Test-Path $pf) {
                $content = Get-Content $pf -Raw -ErrorAction SilentlyContinue
                $obs = @(Get-PersonObservations -Content $content -Dates $Dates)
                if ($obs.Count -gt 0) { $personasImported++ }
            }
        }
        $threads    = @($obs | Where-Object { $_.Kind -eq 'thread' } | ForEach-Object { $_.Text })
        $behavioral = @($obs | Where-Object { $_.Kind -eq 'behavioral' } | ForEach-Object { $_.Text } | Select-Object -First 1)

        $dailyHi = ''; $weeklySum = ''
        if ($Enrichment -and $Enrichment.ContainsKey($alias)) {
            $e = $Enrichment[$alias]
            if ($e.daily)  { $dailyHi   = [string]$e.daily }
            if ($e.weekly) { $weeklySum = [string]$e.weekly }
        }

        $wins = @($p.recent_wins)
        $hasActivity = ($authored.Count -gt 0) -or ($reviewed.Count -gt 0) -or ($threads.Count -gt 0) -or [bool]$dailyHi

        $people += [pscustomobject]@{
            Alias = $alias; Name = [string]$p.name; Smtp = [string]$p.smtp
            PrsAuthored = $authored; PrsReviewed = $reviewed
            Threads = $threads; Behavioral = ($behavioral | Select-Object -First 1)
            Wins = $wins; DailyHighlight = $dailyHi; WeeklySummary = $weeklySum
            HasActivity = $hasActivity
        }
    }

    $aIds = @{}; $rIds = @{}
    foreach ($pp in $people) {
        foreach ($pr in $pp.PrsAuthored) { if ($pr.id) { $aIds[[string]$pr.id] = $true } }
        foreach ($pr in $pp.PrsReviewed) { if ($pr.id) { $rIds[[string]$pr.id] = $true } }
    }

    return [pscustomobject]@{
        People = $people
        AliasCount = $aliases.Count
        ActivePeopleCount = @($people | Where-Object { $_.HasActivity }).Count
        PrsAuthoredUnique = $aIds.Count
        PrsReviewedUnique = $rIds.Count
        PersonasImported = $personasImported
    }
}

# ---- Spec builders --------------------------------------------------------

function Build-TeamBriefStatCard {
    param([string] $Label, $Value, [string] $Sub, [string] $Tone = 'neutral')
    return @{ Label = $Label; Value = "$Value"; Sublabel = $Sub; Tone = $Tone }
}

function Format-PrListItem {
    param(
        [Parameter(Mandatory)] $Pr,
        [switch] $ShowAuthor   # append "(Author Name)" - used for Reviewed lists
    )
    $t = ConvertTo-HtmlText ([string]$Pr.title)
    $repo = ConvertTo-HtmlText ([string]$Pr.repo)
    $statusTone = if ($Pr.status -eq 'completed') { '#0f7a3c' } else { '#57606a' }
    $status = ConvertTo-HtmlText ([string]$Pr.status)
    $link = [string]$Pr.url
    $titleHtml = if ($link) { "<a href='$([System.Net.WebUtility]::HtmlEncode($link))' style='color:#6e40c9;text-decoration:none'>$t</a>" } else { $t }
    $authorHtml = ''
    if ($ShowAuthor -and $Pr.PSObject.Properties.Name -contains 'author' -and -not [string]::IsNullOrWhiteSpace([string]$Pr.author)) {
        $authorHtml = " <span style='color:#57606a'>(" + (ConvertTo-HtmlText ([string]$Pr.author)) + ")</span>"
    }
    return "<li style='margin:2px 0'>$titleHtml$authorHtml <span style='color:#8a8a8a'>&middot; $repo &middot; <span style='color:$statusTone'>$status</span></span></li>"
}

function Build-PersonSectionHtml {
    param([Parameter(Mandatory)] $Person)
    $parts = New-Object System.Collections.ArrayList

    if ($Person.PrsAuthored.Count -gt 0) {
        [void]$parts.Add("<div style='margin:2px 0 4px'><b>Opened</b></div><ul style='margin:0 0 8px 18px;padding:0'>")
        foreach ($pr in ($Person.PrsAuthored | Select-Object -First 8)) { [void]$parts.Add((Format-PrListItem -Pr $pr)) }
        [void]$parts.Add("</ul>")
    }
    if ($Person.PrsReviewed.Count -gt 0) {
        [void]$parts.Add("<div style='margin:2px 0 4px'><b>Reviewed</b></div><ul style='margin:0 0 8px 18px;padding:0'>")
        foreach ($pr in ($Person.PrsReviewed | Select-Object -First 8)) { [void]$parts.Add((Format-PrListItem -Pr $pr -ShowAuthor)) }
        [void]$parts.Add("</ul>")
    }

    $hi = if ($Person.DailyHighlight) { [string]$Person.DailyHighlight }
          elseif ($Person.Threads.Count -gt 0) { 'In the inbox: ' + (($Person.Threads | Select-Object -First 2) -join ' | ') }
          else { '' }
    if ($hi) {
        [void]$parts.Add("<div style='margin:4px 0;color:#57606a'><b style='color:#1f2328'>Teams &amp; email:</b> " + (ConvertTo-HtmlText $hi) + "</div>")
    }
    if ($Person.Behavioral) {
        $b = ConvertTo-HtmlText ([string]$Person.Behavioral)
        [void]$parts.Add("<div style='margin:4px 0;color:#8a5a00;font-style:italic'>&ldquo;$b&rdquo;</div>")
    }

    if ($parts.Count -eq 0) { [void]$parts.Add("<div style='color:#8a8a8a'>No tracked activity in this window.</div>") }
    return ($parts -join "`n")
}

function Build-DailyBriefSpec {
    param(
        [Parameter(Mandatory)] $Data,
        [Parameter(Mandatory)] [string] $RangeLabel,
        [string] $ContextGeneratedLabel,
        [string] $Joke,
        [int]    $TotalDirects = 14
    )
    $active = @($Data.People | Where-Object { $_.HasActivity } | Sort-Object { $_.PrsAuthored.Count } -Descending)
    $quiet  = @($Data.People | Where-Object { -not $_.HasActivity } | ForEach-Object { $_.Name })

    $chips = @()
    if ($ContextGeneratedLabel) { $chips += @{ Label = "ADO context $ContextGeneratedLabel"; Tone = 'neutral' } }
    $chips += @{ Label = "$($Data.ActivePeopleCount)/$TotalDirects active"; Tone = 'good' }

    $stats = @(
        (Build-TeamBriefStatCard -Label 'People active' -Value $Data.ActivePeopleCount -Sub "of $TotalDirects directs" -Tone 'accent'),
        (Build-TeamBriefStatCard -Label 'PRs opened'    -Value $Data.PrsAuthoredUnique -Sub 'authored in window' -Tone 'good'),
        (Build-TeamBriefStatCard -Label 'PRs reviewed'  -Value $Data.PrsReviewedUnique -Sub 'as reviewer'        -Tone 'neutral')
    )

    $sections = @()
    foreach ($pp in $active) {
        $bits = @()
        if ($pp.PrsAuthored.Count -gt 0) { $bits += "$($pp.PrsAuthored.Count) opened" }
        if ($pp.PrsReviewed.Count -gt 0) { $bits += "$($pp.PrsReviewed.Count) reviewed" }
        $sub = if ($bits.Count -gt 0) { $bits -join ' &middot; ' } else { 'Teams &amp; email activity' }
        $sections += @{ Title = $pp.Name; SubtitleHtml = $sub; BodyHtml = (Build-PersonSectionHtml -Person $pp) }
    }
    if ($quiet.Count -gt 0) {
        $names = ($quiet | ForEach-Object { ConvertTo-HtmlText $_ }) -join ', '
        $sections += @{ Title = 'Quiet in this window'; BodyHtml = "<div style='color:#8a8a8a'>No tracked PRs or highlights for: $names. (Absence of signal, not absence of work.)</div>" }
    }

    $tldr = "<b>$($Data.ActivePeopleCount)</b> of $TotalDirects directs had tracked activity &mdash; " +
            "<b>$($Data.PrsAuthoredUnique)</b> PR(s) opened, <b>$($Data.PrsReviewedUnique)</b> reviewed."

    return @{
        Eyebrow = 'Daily Team Brief'
        Title = "What your team did &mdash; $RangeLabel"
        Subtitle = 'Where your 14 directs spent the day &mdash; what they opened, what they reviewed, and what lit up Teams and email.'
        Chips = $chips; Tldr = $tldr; Stats = $stats; Sections = $sections; Joke = $Joke
    }
}

function Build-WeeklyBriefSpec {
    param(
        [Parameter(Mandatory)] $Data,
        [Parameter(Mandatory)] [string] $RangeLabel,
        [string] $ContextGeneratedLabel,
        [string] $Joke,
        [int]    $TotalDirects = 14
    )
    # Weekly is intentionally PR-free: a per-person narrative of what each
    # accomplished, synthesized from Teams/email/activity (WeeklySummary) plus wins.
    $withSummary = @($Data.People | Where-Object { $_.WeeklySummary -or $_.Wins.Count -gt 0 })
    $ranked = @($withSummary | Sort-Object { if ($_.WeeklySummary) { 1 } else { 0 } } -Descending)

    $chips = @()
    if ($ContextGeneratedLabel) { $chips += @{ Label = "Context $ContextGeneratedLabel"; Tone = 'neutral' } }
    $chips += @{ Label = "$($ranked.Count)/$TotalDirects with highlights"; Tone = 'good' }

    $sections = @()
    foreach ($pp in $ranked) {
        $body = New-Object System.Collections.ArrayList
        if ($pp.WeeklySummary) {
            [void]$body.Add("<div style='margin:2px 0'>" + (ConvertTo-HtmlText ([string]$pp.WeeklySummary)) + "</div>")
        }
        $wins = @($pp.Wins | Where-Object { $_ })
        if ($wins.Count -gt 0) {
            [void]$body.Add("<ul style='margin:6px 0 0 18px;padding:0'>")
            foreach ($w in ($wins | Select-Object -First 3)) { [void]$body.Add("<li style='margin:2px 0'>" + (ConvertTo-HtmlText ([string]$w)) + "</li>") }
            [void]$body.Add("</ul>")
        }
        if ($body.Count -eq 0) { [void]$body.Add("<div style='color:#8a8a8a'>Quiet week on the record.</div>") }
        $sections += @{ Title = $pp.Name; BodyHtml = ($body -join "`n") }
    }

    $tldr = "Week of <b>$RangeLabel</b> &mdash; what each of your directs drove and shipped, summarized from Teams, email, and activity."

    return @{
        Eyebrow = 'Weekly Highlights'
        Title = "Team highlights &mdash; $RangeLabel"
        Subtitle = 'The week your team had, person by person: what they accomplished, the calls they drove, and the wins worth knowing.'
        Chips = $chips; Tldr = $tldr; Sections = $sections; Joke = $Joke
    }
}

# Insert a signature block immediately before the closing </body> of a full HTML doc.
function Add-SignatureBeforeBodyClose {
    param([Parameter(Mandatory)][string] $Html, [string] $Signature)
    if ([string]::IsNullOrEmpty($Signature)) { return $Html }
    $idx = $Html.LastIndexOf('</body>')
    if ($idx -lt 0) { return $Html + $Signature }
    return $Html.Substring(0, $idx) + $Signature + $Html.Substring($idx)
}
