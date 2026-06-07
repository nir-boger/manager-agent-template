# Tests for the team-brief skill: timezone/window math (DST), PR-in-window filter,
# observation parser, spec builders, signature insertion, plus runner / manifest /
# schedule wiring.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\team-brief'
$helpersPs1 = Join-Path $skillDir 'helpers.ps1'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$runnerPs1  = Join-Path $repoRoot '.copilot\skills\run-team-brief.ps1'
$skillsJson = Join-Path $repoRoot 'config\skills.json'
$schedJson  = Join-Path $repoRoot 'config\schedules.json'

foreach ($p in @($helpersPs1, $skillMd, $runnerPs1, $skillsJson, $schedJson)) {
    if (-not (Test-Path $p)) { throw "missing required file: $p" }
}

. $helpersPs1

$runnerText = Get-Content $runnerPs1 -Raw -Encoding UTF8

Describe 'team-brief source hygiene' {

    It 'helpers.ps1 is ASCII-only (PS 5.1 source constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($helpersPs1)
        $bad = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad++ } }
        Assert-Equal 0 $bad "helpers.ps1 has $bad non-ASCII byte(s)"
    }

    It 'runner is ASCII-only (PS 5.1 source constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($runnerPs1)
        $bad = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad++ } }
        Assert-Equal 0 $bad "runner has $bad non-ASCII byte(s)"
    }
}

Describe 'team-brief - timezone + windows' {

    It 'Get-IsraelTimeZone resolves a usable timezone' {
        $tz = Get-IsraelTimeZone
        Assert-True ($null -ne $tz) 'expected a TimeZoneInfo'
    }

    It 'daily window for a June day is [D 21:00Z(prev) .. D+1 21:00Z) (DST UTC+3)' {
        $tz  = Get-IsraelTimeZone
        $win = Get-DailyWindow -TargetDate ([datetime]'2026-06-05') -Tz $tz
        Assert-Equal '2026-06-04T21:00:00Z' $win.StartUtc.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') 'June DST start'
        Assert-Equal '2026-06-05T21:00:00Z' $win.EndUtc.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')   'June DST end'
    }

    It 'daily window covers exactly the single target date by default' {
        $win = Get-DailyWindow -TargetDate ([datetime]'2026-06-05')
        Assert-Equal 1 $win.Dates.Count 'single day'
        Assert-Equal '2026-06-05' $win.Dates[0] ''
    }

    It 'daily backfill window enumerates every covered date inclusive' {
        $win = Get-DailyWindow -TargetDate ([datetime]'2026-06-07') -CoverStart ([datetime]'2026-06-05')
        Assert-Equal 3 $win.Dates.Count '3 days covered'
        Assert-Equal '2026-06-05' $win.Dates[0] ''
        Assert-Equal '2026-06-07' $win.Dates[2] ''
    }

    It 'daily window clamps a CoverStart later than target back to target' {
        $win = Get-DailyWindow -TargetDate ([datetime]'2026-06-05') -CoverStart ([datetime]'2026-06-09')
        Assert-Equal 1 $win.Dates.Count 'clamped to single day'
    }

    It 'weekly window for a midweek anchor is Sun..Thu (5 days, Fri exclusive end)' {
        $tz  = Get-IsraelTimeZone
        # 2026-06-03 is a Wednesday; its work week is Sun 5/31 .. Thu 6/4
        $win = Get-WeeklyWindow -Anchor ([datetime]'2026-06-03') -Tz $tz
        Assert-Equal 5 $win.Dates.Count 'Sun..Thu'
        Assert-Equal '2026-05-31' $win.Dates[0] 'starts Sunday'
        Assert-Equal '2026-06-04' $win.Dates[4] 'ends Thursday'
        Assert-Equal '2026-05-30T21:00:00Z' $win.StartUtc.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') 'Sunday 00:00 IST'
        Assert-Equal '2026-06-04T21:00:00Z' $win.EndUtc.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')   'Friday 00:00 IST exclusive'
    }

    It 'weekly window from a Thursday anchor still covers that same Sun..Thu week' {
        $win = Get-WeeklyWindow -Anchor ([datetime]'2026-06-04')
        Assert-Equal '2026-05-31' $win.Dates[0] ''
        Assert-Equal '2026-06-04' $win.Dates[4] ''
    }
}

Describe 'team-brief - PR-in-window filter' {

    $start = ConvertTo-UtcFromIsrael -Local ([datetime]'2026-06-05')
    $end   = ConvertTo-UtcFromIsrael -Local ([datetime]'2026-06-06')

    It 'accepts a PR created inside the window' {
        Assert-True (Test-PrInWindow -CreatedIso '2026-06-05T08:00:00Z' -StartUtc $start -EndUtc $end) 'in-window'
    }

    It 'rejects a PR created before the window' {
        Assert-False (Test-PrInWindow -CreatedIso '2026-06-04T08:00:00Z' -StartUtc $start -EndUtc $end) 'before'
    }

    It 'rejects a PR exactly at the exclusive end boundary' {
        # 2026-06-06 00:00 IST == 2026-06-05 21:00Z == $end
        Assert-False (Test-PrInWindow -CreatedIso '2026-06-05T21:00:00Z' -StartUtc $start -EndUtc $end) 'exclusive end'
    }

    It 'rejects blank / unparseable timestamps' {
        Assert-False (Test-PrInWindow -CreatedIso '' -StartUtc $start -EndUtc $end) 'blank'
        Assert-False (Test-PrInWindow -CreatedIso 'not-a-date' -StartUtc $start -EndUtc $end) 'garbage'
    }
}

Describe 'team-brief - observation parser' {

    $sample = @'
# Teammate2 (lea)

## Daily observations
- 2026-06-04 (raw 24h): top email threads - ingestion latency; cluster rollout [src: x]
- 2026-06-04 (behavioral, raw): Stated position: "we should ship behind a flag" [src: y]
- 2026-06-03 (raw 24h): top email threads - retro follow-ups [src: z]

## Something else
- not an observation
'@

    It 'parses observations only for the requested date' {
        $obs = Get-PersonObservations -Content $sample -Dates @('2026-06-04')
        Assert-Equal 2 $obs.Count 'two lines on 6/4'
    }

    It 'classifies thread vs behavioral and strips the [src:] tail' {
        $obs = Get-PersonObservations -Content $sample -Dates @('2026-06-04')
        $thread = @($obs | Where-Object { $_.Kind -eq 'thread' })
        $beh    = @($obs | Where-Object { $_.Kind -eq 'behavioral' })
        Assert-Equal 1 $thread.Count 'one thread line'
        Assert-Equal 1 $beh.Count 'one behavioral line'
        Assert-NotMatch '\[src:' $thread[0].Text 'src tail stripped'
        Assert-NotMatch 'top email threads' $thread[0].Text 'thread prefix stripped'
    }

    It 'does not bleed into the next ## section' {
        $obs = Get-PersonObservations -Content $sample -Dates @('2026-06-03','2026-06-04')
        Assert-Equal 3 $obs.Count 'three observation lines total, none from Something else'
    }

    It 'returns empty for content with no observations section' {
        $obs = Get-PersonObservations -Content "# x`n## Other`n- y" -Dates @('2026-06-04')
        Assert-Equal 0 $obs.Count 'none'
    }
}

Describe 'team-brief - HTML safety + signature insertion' {

    It 'ConvertTo-HtmlText encodes angle brackets and ampersands' {
        Assert-Equal '&lt;b&gt;x&amp;y&lt;/b&gt;' (ConvertTo-HtmlText '<b>x&y</b>') 'encoded'
    }

    It 'Add-SignatureBeforeBodyClose inserts before </body>' {
        $html = '<html><body><p>hi</p></body></html>'
        $out  = Add-SignatureBeforeBodyClose -Html $html -Signature '<div id="sig">S</div>'
        Assert-Match '<div id="sig">S</div></body>' $out 'sig before close'
        Assert-NotMatch '</body>.*<div id="sig"' $out 'sig not after close'
    }

    It 'Add-SignatureBeforeBodyClose appends when no </body> present' {
        $out = Add-SignatureBeforeBodyClose -Html '<p>x</p>' -Signature 'SIG'
        Assert-Match 'xSIG|x</p>SIG' $out 'appended'
    }
}

Describe 'team-brief - data aggregation + spec builders' {

    # Minimal directs-context shaped object: 3 people, varied activity.
    $start = ConvertTo-UtcFromIsrael -Local ([datetime]'2026-06-04')
    $end   = ConvertTo-UtcFromIsrael -Local ([datetime]'2026-06-05')

    # PR id 5 is AUTHORED by roni and REVIEWED by Teammate12 -- the exact shape of the
    # bug Nir caught (a reviewer credited as the author). Attribution MUST split it.
    $directs = [pscustomobject]@{
        lea = [pscustomobject]@{
            name = 'Teammate2'; smtp = 'lea@x'
            recent_prs = @(
                [pscustomobject]@{ id = 1; title = 'Fix ingest'; url = 'http://p/1'; status = 'active';    repo = 'r'; role = 'author';   created = '2026-06-04T09:00:00Z' },
                [pscustomobject]@{ id = 2; title = 'Old merge';  url = 'http://p/2'; status = 'completed'; repo = 'r'; role = 'author';   created = '2026-05-01T09:00:00Z' }
            )
            recent_wins = @('Shipped X')
        }
        maya = [pscustomobject]@{
            name = 'Teammate4'; smtp = 'maya@x'
            recent_prs = @(); recent_wins = @()
        }
        amir = [pscustomobject]@{
            name = 'Amir K'; smtp = 'amir@x'
            recent_prs = @(
                [pscustomobject]@{ id = 3; title = 'Refactor'; url = 'http://p/3'; status = 'active'; repo = 'r2'; role = 'author'; created = '2026-06-04T12:00:00Z' }
            )
            recent_wins = @()
        }
        roni = [pscustomobject]@{
            name = 'Teammate11'; smtp = 'roni@x'
            recent_prs = @(
                [pscustomobject]@{ id = 5; title = 'VC prefix fix'; url = 'http://p/5'; status = 'active'; repo = 'r'; role = 'author'; created = '2026-06-04T08:00:00Z' }
            )
            recent_wins = @()
        }
        Teammate12 = [pscustomobject]@{
            name = 'Teammate12'; smtp = 'Teammate12@x'
            recent_prs = @(
                [pscustomobject]@{ id = 5; title = 'VC prefix fix'; url = 'http://p/5'; status = 'active'; repo = 'r'; role = 'reviewer'; author = 'Teammate11'; created = '2026-06-04T08:00:00Z' }
            )
            recent_wins = @()
        }
    }

    $data = Get-TeamBriefData -Directs $directs -PeopleDir $null -StartUtc $start -EndUtc $end -Dates @('2026-06-04')

    It 'counts aliases and active people correctly' {
        Assert-Equal 5 $data.AliasCount 'five directs'
        Assert-Equal 4 $data.ActivePeopleCount 'lea + amir authored, roni authored, Teammate12 reviewed'
    }

    It 'counts unique PRs authored in window (reviewer copies excluded)' {
        Assert-Equal 3 $data.PrsAuthoredUnique 'PR 1, 3, 5 authored'
        Assert-Equal 1 $data.PrsReviewedUnique 'PR 5 reviewed (by Teammate12)'
    }

    It 'attributes a PR to its author, not its reviewer (the headline fix)' {
        $roni  = @($data.People | Where-Object { $_.Alias -eq 'roni' })[0]
        $Teammate12 = @($data.People | Where-Object { $_.Alias -eq 'Teammate12' })[0]
        Assert-Equal 1 $roni.PrsAuthored.Count 'roni authored PR 5'
        Assert-Equal 0 $roni.PrsReviewed.Count 'roni did not review anything'
        Assert-Equal 0 $Teammate12.PrsAuthored.Count 'Teammate12 authored nothing'
        Assert-Equal 1 $Teammate12.PrsReviewed.Count 'Teammate12 only reviewed PR 5'
        Assert-Equal '5' ([string]$Teammate12.PrsReviewed[0].id) 'the reviewed PR is 5'
    }

    It 'keeps an out-of-window authored PR out of the authored count' {
        $lea = @($data.People | Where-Object { $_.Alias -eq 'lea' })[0]
        Assert-Equal 1 $lea.PrsAuthored.Count 'only the in-window authored PR'
    }

    It 'shows the PR author in parentheses on a Reviewed item, but not on an Opened item' {
        $Teammate12 = @($data.People | Where-Object { $_.Alias -eq 'Teammate12' })[0]
        $roni  = @($data.People | Where-Object { $_.Alias -eq 'roni' })[0]
        $sapirHtml = Build-PersonSectionHtml -Person $Teammate12
        Assert-Match '(?s)<b>Reviewed</b>.*\(Teammate11\)' $sapirHtml 'reviewed PR annotated with author'
        # Roni AUTHORED PR 5 (no author parenthetical on her Opened list - it would be herself).
        $roniHtml = Build-PersonSectionHtml -Person $roni
        Assert-NotMatch '(?s)<b>Opened</b>.*\(Teammate11\)' $roniHtml 'opened PR not annotated with author'
    }

    It 'Format-PrListItem only emits the author parenthetical with -ShowAuthor' {
        $pr = [pscustomobject]@{ id = 7; title = 'X'; url = ''; status = 'active'; repo = 'r'; author = 'Some One' }
        Assert-NotMatch '\(Some One\)' (Format-PrListItem -Pr $pr) 'no author without the switch'
        Assert-Match    '\(Some One\)' (Format-PrListItem -Pr $pr -ShowAuthor) 'author shown with the switch'
    }

    It 'Build-DailyBriefSpec produces required spec keys + 3 stats (no work items)' {
        $spec = Build-DailyBriefSpec -Data $data -RangeLabel 'Jun 4' -Joke 'ha' -TotalDirects 5
        Assert-True ($null -ne $spec.Title) 'has title'
        Assert-Equal 3 $spec.Stats.Count 'three stat cards (people / opened / reviewed)'
        Assert-NotMatch 'work item' (($spec.Stats | ForEach-Object { $_.Label }) -join '|') 'no work-item stat'
        Assert-Equal 'ha' $spec.Joke 'joke threaded through'
        Assert-True ($spec.Sections.Count -ge 1) 'has person sections'
    }

    It 'Build-WeeklyBriefSpec is PR-free prose with no stat grid' {
        $enr = @{ lea = @{ daily = ''; weekly = 'Lea drove an ingestion incident this week.' } }
        $wd  = Get-TeamBriefData -Directs $directs -PeopleDir $null -StartUtc $start -EndUtc $end -Dates @('2026-06-04') -Enrichment $enr
        $spec = Build-WeeklyBriefSpec -Data $wd -RangeLabel 'May 31 - Jun 4' -Joke 'wk' -TotalDirects 5
        Assert-True (($null -eq $spec.Stats) -or ($spec.Stats.Count -eq 0)) 'no stat grid in weekly'
        $leaSec = @($spec.Sections | Where-Object { $_.Title -eq 'Teammate2' })[0]
        Assert-Match 'ingestion incident' $leaSec.BodyHtml 'weekly summary prose rendered'
        Assert-NotMatch '<b>Opened</b>' (($spec.Sections | ForEach-Object { $_.BodyHtml }) -join "`n") 'no PR Opened list in weekly'
        Assert-NotMatch '<b>Reviewed</b>' (($spec.Sections | ForEach-Object { $_.BodyHtml }) -join "`n") 'no PR Reviewed list in weekly'
    }

    It 'enrichment DailyHighlight renders in the person section and counts as activity' {
        $enr = @{ maya = @{ daily = 'Maya drove a Fabric PPE portal incident.'; weekly = '' } }
        $d3  = Get-TeamBriefData -Directs $directs -PeopleDir $null -StartUtc $start -EndUtc $end -Dates @('2026-06-04') -Enrichment $enr
        $maya = @($d3.People | Where-Object { $_.Alias -eq 'maya' })[0]
        Assert-True ($maya.HasActivity) 'a daily highlight makes a PR-less person active'
        $html = Build-PersonSectionHtml -Person $maya
        Assert-Match 'Fabric PPE portal' $html 'highlight text present'
        Assert-Match 'Teams &amp; email:' $html 'highlight labelled'
    }

    It 'person section HTML-encodes PR titles' {
        $directs2 = [pscustomobject]@{
            x = [pscustomobject]@{
                name = 'X'; smtp = 'x@x'
                recent_prs = @([pscustomobject]@{ id = 9; title = '<script>bad</script>'; url = ''; status = 'active'; repo = 'r'; role = 'author'; created = '2026-06-04T09:00:00Z' })
                recent_wins = @()
            }
        }
        $d2 = Get-TeamBriefData -Directs $directs2 -PeopleDir $null -StartUtc $start -EndUtc $end -Dates @('2026-06-04')
        $html = Build-PersonSectionHtml -Person $d2.People[0]
        Assert-Match '&lt;script&gt;' $html 'title encoded'
        Assert-NotMatch '<script>bad' $html 'no raw script tag'
    }
}

Describe 'team-brief - runner wiring' {

    It 'runner accepts -Mode daily|weekly and the documented flags' {
        Assert-Match "ValidateSet\('daily', 'weekly'\)" $runnerText 'mode set'
        foreach ($flag in @('\$Date', '\$Force', '\$DryRun', '\$NoEmail', '\$Enrich')) {
            Assert-Match $flag $runnerText "has $flag"
        }
    }

    It 'runner reads enrichment.json and passes it to Get-TeamBriefData' {
        Assert-Match 'enrichment\.json' $runnerText 'reads enrichment cache'
        Assert-Match '-Enrichment' $runnerText 'passes enrichment to data builder'
        Assert-Match "Join-Path \`$skillDir 'enrich\.ps1'" $runnerText 'invokes enrich.ps1 under -Enrich'
    }

    It 'runner reuses the shared renderer + signature + migration guard' {
        Assert-Match 'investigation-email\.ps1' $runnerText 'renderer'
        Assert-Match 'Get-NirvanaSignature' $runnerText 'signature'
        Assert-Match 'Test-MigrationMode' $runnerText 'migration guard'
        Assert-Match 'Add-SignatureBeforeBodyClose' $runnerText 'signature inserted before body close'
    }

    It 'runner only advances state on a successful send' {
        Assert-Match 'if \(\$sent\)' $runnerText 'state advance gated on send'
        Assert-Match 'State NOT advanced' $runnerText 'failure path leaves state untouched'
    }

    It 'runner backfills missed days (capped) in daily mode' {
        Assert-Match 'AddDays\(-6\)' $runnerText '7-day backfill cap'
        Assert-Match 'CoverStart' $runnerText 'cover-start backfill logic'
    }
}

Describe 'team-brief - manifest + schedule wiring' {

    $skills = (Get-Content $skillsJson -Raw | ConvertFrom-Json).skills
    $tasks  = (Get-Content $schedJson  -Raw | ConvertFrom-Json).tasks

    It 'team-brief is registered in skills.json' {
        $e = @($skills | Where-Object { $_.name -eq 'team-brief' })
        Assert-Equal 1 $e.Count 'one entry'
        Assert-Equal '.copilot/skills/run-team-brief.ps1' $e[0].entrypoint_path ''
        Assert-True ($e[0].show_in_agents) 'shown in AGENTS.md'
    }

    It 'both scheduled tasks are in the manifest with the right modes' {
        $daily  = @($tasks | Where-Object { $_.suffix -eq 'TeamBriefDaily' })
        $weekly = @($tasks | Where-Object { $_.suffix -eq 'TeamWeeklyHighlights' })
        Assert-Equal 1 $daily.Count 'daily task'
        Assert-Equal 1 $weekly.Count 'weekly task'
        Assert-Equal 'daily' $daily[0].schedule.kind ''
        Assert-Equal '18:30' $daily[0].schedule.time ''
        Assert-Equal 'weekly' $weekly[0].schedule.kind ''
        Assert-Equal '17:00' $weekly[0].schedule.time ''
        Assert-Equal 'Thursday' $weekly[0].schedule.days[0] ''
        Assert-Contains 'daily' ($daily[0].args -join ' ') 'daily mode arg'
        Assert-Contains 'weekly' ($weekly[0].args -join ' ') 'weekly mode arg'
    }
}

