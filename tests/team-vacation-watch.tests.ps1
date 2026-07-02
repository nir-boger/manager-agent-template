# Tests for team-vacation-watch deterministic state engine.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\team-vacation-watch.tests.ps1

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$skillDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.copilot\skills\team-vacation-watch'
$helpers  = Join-Path $skillDir 'vacation-helpers.ps1'
$applyPs1 = Join-Path $skillDir 'apply-vacation-state.ps1'
$welcomeMsg = Join-Path $skillDir 'welcome-message.ps1'
. $helpers
. $welcomeMsg

Describe 'Get-DominantEol' {
    It 'detects CRLF' { Assert-Equal "`r`n" (Get-DominantEol "a`r`nb`r`nc") }
    It 'detects LF'   { Assert-Equal "`n"   (Get-DominantEol "a`nb`nc") }
    It 'defaults to CRLF for a no-newline string' { Assert-Equal "`r`n" (Get-DominantEol 'single line') }
    It 'treats mostly-CRLF as CRLF'  { Assert-Equal "`r`n" (Get-DominantEol "a`r`nb`r`nc`nd") }
}

Describe 'Get-VacationStatusLine' {
    It 'not on vacation' {
        Assert-Equal 'Not on vacation (as of 2026-06-04).' (Get-VacationStatusLine -OnVacation $false -AsOf '2026-06-04')
    }
    It 'on vacation with start+end' {
        Assert-Equal 'On vacation 2026-06-05..2026-06-12 (per team calendar, as of 2026-06-04).' `
            (Get-VacationStatusLine -OnVacation $true -Start '2026-06-05' -End '2026-06-12' -AsOf '2026-06-04')
    }
    It 'on vacation with start, no end' {
        Assert-Equal 'On vacation from 2026-06-05 (as of 2026-06-04).' `
            (Get-VacationStatusLine -OnVacation $true -Start '2026-06-05' -AsOf '2026-06-04')
    }
    It 'on vacation, no dates' {
        Assert-Equal 'On vacation (as of 2026-06-04).' (Get-VacationStatusLine -OnVacation $true -AsOf '2026-06-04')
    }
}

Describe 'Set-VacationBlockContent - insert' {
    It 'appends a Notes section + block when neither markers nor Notes exist (preserves everything else byte-for-byte)' {
        $orig = "# Foo (foo)`r`n`r`n## Employment`r`n- Gender: X`r`n`r`n## Daily observations`r`n- a line`r`n"
        $new  = Set-VacationBlockContent -Content $orig -StatusLine 'Not on vacation (as of 2026-06-04).'
        Assert-Match 'nirvana:vacation-status' $new
        Assert-Match '## Notes' $new
        # Original content fully preserved as a prefix.
        Assert-Equal $true ($new.Contains('## Employment'))
        Assert-Equal $true ($new.Contains('## Daily observations'))
        Assert-Equal $true ($new.Contains('- a line'))
        # CRLF preserved.
        Assert-Match "nirvana:vacation-status -->`r`n- \*\*Vacation:\*\*" $new
    }
    It 'inserts under an existing ## Notes header, keeping existing note lines' {
        $orig = "# Foo (foo)`n`n## Notes`n- 2026-04-29: hello`n`n## Sources`n- x`n"
        $new  = Set-VacationBlockContent -Content $orig -StatusLine 'Not on vacation (as of 2026-06-04).'
        Assert-Match '## Notes' $new
        Assert-Match '- 2026-04-29: hello' $new
        Assert-Match '## Sources' $new
        # Exactly one managed block.
        Assert-Equal 1 ([regex]::Matches($new, '<!-- nirvana:vacation-status -->').Count)
    }
}

Describe 'Set-VacationBlockContent - update (idempotent, surgical)' {
    It 'replaces only the marker region, leaving surrounding text intact' {
        $orig = "# Foo (foo)`n`n## Notes`n<!-- nirvana:vacation-status -->`n- **Vacation:** Not on vacation (as of 2026-06-01).`n<!-- /nirvana:vacation-status -->`n- 2026-04-29: keep me`n"
        $new  = Set-VacationBlockContent -Content $orig -StatusLine 'On vacation 2026-06-05..2026-06-12 (per team calendar, as of 2026-06-04).'
        Assert-Match 'On vacation 2026-06-05\.\.2026-06-12' $new
        Assert-Match '- 2026-04-29: keep me' $new
        Assert-Equal $false ($new.Contains('Not on vacation (as of 2026-06-01)'))
        Assert-Equal 1 ([regex]::Matches($new, '<!-- nirvana:vacation-status -->').Count)
    }
    It 'is idempotent: applying the same status twice yields identical content' {
        $orig = "# Foo (foo)`n`n## Notes`n- note`n"
        $a = Set-VacationBlockContent -Content $orig -StatusLine 'Not on vacation (as of 2026-06-04).'
        $b = Set-VacationBlockContent -Content $a    -StatusLine 'Not on vacation (as of 2026-06-04).'
        Assert-Equal $a $b
    }
}

Describe 'Resolve-AliasFromName' {
    $map = @{ 'Teammate8' = 'oz-Teammate8'; 'Teammate2' = 'lea-Teammate2' }
    It 'matches case-insensitively' { Assert-Equal 'oz-Teammate8' (Resolve-AliasFromName -Name 'Teammate8' -DisplayToAlias $map) }
    It 'returns null for unknown'   { Assert-Equal $null (Resolve-AliasFromName -Name 'Nobody Here' -DisplayToAlias $map) }
    It 'trims whitespace'           { Assert-Equal 'lea-Teammate2' (Resolve-AliasFromName -Name '  Teammate2 ' -DisplayToAlias $map) }
}

Describe 'Test-IsWorkingDay' {
    It 'verifies known Israel working days and weekend days' {
        Assert-Equal 'Thursday' "$(([datetime]'2026-06-04').DayOfWeek)"
        Assert-Equal 'Friday' "$(([datetime]'2026-06-05').DayOfWeek)"
        Assert-Equal 'Saturday' "$(([datetime]'2026-06-06').DayOfWeek)"
        Assert-Equal 'Sunday' "$(([datetime]'2026-06-07').DayOfWeek)"
        Assert-Equal $true  (Test-IsWorkingDay -Date ([datetime]'2026-06-04'))
        Assert-Equal $false (Test-IsWorkingDay -Date ([datetime]'2026-06-05'))
        Assert-Equal $false (Test-IsWorkingDay -Date ([datetime]'2026-06-06'))
        Assert-Equal $true  (Test-IsWorkingDay -Date ([datetime]'2026-06-07'))
    }
}

Describe 'Get-WorkingDayCount' {
    # 2026-06-04 Thu, 06-05 Fri, 06-06 Sat, 06-07 Sun.
    It 'counts Mon-Thu (4 working days), excluding the weekend in between' {
        # 2026-06-01 Mon .. 2026-06-04 Thu = Mon,Tue,Wed,Thu = 4 (no weekend in range)
        Assert-Equal 4 (Get-WorkingDayCount -Start ([datetime]'2026-06-01') -End ([datetime]'2026-06-04'))
    }
    It 'weekend-only (Fri+Sat) -> 0 working days' {
        Assert-Equal 0 (Get-WorkingDayCount -Start ([datetime]'2026-06-05') -End ([datetime]'2026-06-06'))
    }
    It 'Thu+Fri+Sat -> 1 working day (only Thursday counts)' {
        Assert-Equal 1 (Get-WorkingDayCount -Start ([datetime]'2026-06-04') -End ([datetime]'2026-06-06'))
    }
    It 'Wed+Thu -> 2 working days (the threshold boundary)' {
        Assert-Equal 2 (Get-WorkingDayCount -Start ([datetime]'2026-06-03') -End ([datetime]'2026-06-04'))
    }
    It 'spans a weekend: Thu..Sun -> 2 working days (Thu+Sun)' {
        Assert-Equal 2 (Get-WorkingDayCount -Start ([datetime]'2026-06-04') -End ([datetime]'2026-06-07'))
    }
    It 'single working day -> 1' {
        Assert-Equal 1 (Get-WorkingDayCount -Start ([datetime]'2026-06-07') -End ([datetime]'2026-06-07'))
    }
    It 'inverted span -> 0' {
        Assert-Equal 0 (Get-WorkingDayCount -Start ([datetime]'2026-06-07') -End ([datetime]'2026-06-01'))
    }
    It 'a full Sun-Thu week + weekend -> 5 working days' {
        # 2026-06-07 Sun .. 2026-06-13 Sat = Sun,Mon,Tue,Wed,Thu (5) + Fri,Sat (0)
        Assert-Equal 5 (Get-WorkingDayCount -Start ([datetime]'2026-06-07') -End ([datetime]'2026-06-13'))
    }
}

Describe 'Get-RecurringOffDays' {
    # WindowStart 2026-06-14 is a Sunday; one Sun..Sat week = 7 chars, Wed at week-index 3.
    $ws = [datetime]'2026-06-14'
    It 'flags a standing weekly day-off (OOF every Wednesday) as recurring' {
        # "0003033" = Sun0 Mon0 Tue0 Wed3 Thu0 Fri3 Sat3 ; x4 weeks. Fri/Sat are weekend.
        $daily = '0003033' * 4
        Assert-Equal '3' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
    It 'one extra adjacent OOF weekday does not change the recurring set (still just Wed)' {
        # Reproduces Lea: off every Wed, plus one week also off the Tuesday (Tue+Wed).
        $chars = ('0003033' * 4).ToCharArray()
        $chars[16] = '3'   # week 2 (0-based) Tuesday -> OOF
        $daily = -join $chars
        Assert-Equal '3' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
    It 'a genuine contiguous multi-day block is NOT recurring (interior days never isolated)' {
        # Tue+Wed+Thu OOF for 3 straight weeks: Wed is always flanked by an OOF working day.
        $daily = ('0033300' * 3) + '0000000'
        Assert-Equal '' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
    It 'too few observed weeks (<3) is not enough to call it recurring' {
        $daily = '0003033' * 2
        Assert-Equal '' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
    It 'weekend days (Fri/Sat) are never returned even when OOF every week' {
        # Only Fri+Sat OOF, every week -> nothing recurring among working days.
        $daily = '0000033' * 4
        Assert-Equal '' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
    It 'empty input -> empty set' {
        Assert-Equal '' (@(Get-RecurringOffDays -DailyOof '' -WindowStart $ws) -join ',')
    }
    It 'catches an off-every-Sunday pattern (isolation ignores the weekend gap)' {
        # Sun3 then working Mon-Thu clear; Fri/Sat weekend OOF. Sunday's prior working
        # neighbour is Thursday (skipping Sat/Fri), which is clear -> isolated.
        $daily = '3000033' * 4
        Assert-Equal '0' (@(Get-RecurringOffDays -DailyOof $daily -WindowStart $ws) -join ',')
    }
}

Describe 'Get-EffectiveWorkingDays' {
    It 'subtracts a recurring Wednesday from the Sun-Thu set' {
        Assert-Equal '0,1,2,4' (@(Get-EffectiveWorkingDays -RecurringOff @(3)) -join ',')
    }
    It 'no recurring days -> full Sun-Thu set' {
        Assert-Equal '0,1,2,3,4' (@(Get-EffectiveWorkingDays -RecurringOff @()) -join ',')
    }
    It 'never returns empty: all-days recurring falls back to the full set' {
        Assert-Equal '0,1,2,3,4' (@(Get-EffectiveWorkingDays -RecurringOff @(0,1,2,3,4)) -join ',')
    }
}

Describe 'Get-WelcomeDueDecision' {
    It 'weekday return due on the return date' {
        $d = Get-WelcomeDueDecision -Today ([datetime]'2026-06-04') -ReturnDate ([datetime]'2026-06-04')
        Assert-Equal 'due' $d.Decision
        Assert-Equal '2026-06-04' $d.Effective.ToString('yyyy-MM-dd')
    }
    It 'Friday return holds Friday and Saturday, then becomes due Sunday' {
        $fri = Get-WelcomeDueDecision -Today ([datetime]'2026-06-05') -ReturnDate ([datetime]'2026-06-05')
        $sat = Get-WelcomeDueDecision -Today ([datetime]'2026-06-06') -ReturnDate ([datetime]'2026-06-05')
        $sun = Get-WelcomeDueDecision -Today ([datetime]'2026-06-07') -ReturnDate ([datetime]'2026-06-05')
        Assert-Equal 'hold' $fri.Decision
        Assert-Equal 'hold' $sat.Decision
        Assert-Equal 'due'  $sun.Decision
        Assert-Equal '2026-06-07' $sun.Effective.ToString('yyyy-MM-dd')
    }
    It 'far beyond effective plus max late is stale' {
        $d = Get-WelcomeDueDecision -Today ([datetime]'2026-06-08') -ReturnDate ([datetime]'2026-06-01') -MaxLate 2
        Assert-Equal 'stale' $d.Decision
    }
    It 'measures lateness from effective working day across a weekend' {
        $d = Get-WelcomeDueDecision -Today ([datetime]'2026-06-07') -ReturnDate ([datetime]'2026-06-05') -MaxLate 2
        Assert-Equal 'due' $d.Decision
        Assert-Equal '2026-06-07' $d.Effective.ToString('yyyy-MM-dd')
    }
}
Describe 'Get-ReturneeDecision' {
    $today = [datetime]'2026-06-04'
    It 'explicit returned_today (high conf) -> returnee dated today' {
        $d = Get-ReturneeDecision -IsFirstRun $false -CurOnVacation $false -CurConfidence 'high' -ReturnedToday $true -Prior $null -Today $today
        Assert-Equal $true $d.IsReturnee; Assert-Equal '2026-06-04' $d.ReturnDate
    }
    It 'first run blocks transition path (no explicit) -> not a returnee' {
        $prior = [pscustomobject]@{ on_vacation = $true; end = '2026-06-02' }
        $d = Get-ReturneeDecision -IsFirstRun $true -CurOnVacation $false -CurConfidence 'high' -ReturnedToday $false -Prior $prior -Today $today
        Assert-Equal $false $d.IsReturnee
    }
    It 'transition prior-onvac -> now-off uses prior.end + 1' {
        $prior = [pscustomobject]@{ on_vacation = $true; end = '2026-06-02' }
        $d = Get-ReturneeDecision -IsFirstRun $false -CurOnVacation $false -CurConfidence 'high' -ReturnedToday $false -Prior $prior -Today $today
        Assert-Equal $true $d.IsReturnee; Assert-Equal '2026-06-03' $d.ReturnDate
    }
    It 'low confidence blocks the explicit path' {
        $d = Get-ReturneeDecision -IsFirstRun $false -CurOnVacation $false -CurConfidence 'low' -ReturnedToday $true -Prior $null -Today $today
        Assert-Equal $false $d.IsReturnee
    }
    It 'no prior + no explicit -> not a returnee' {
        $d = Get-ReturneeDecision -IsFirstRun $false -CurOnVacation $false -CurConfidence 'high' -ReturnedToday $false -Prior $null -Today $today
        Assert-Equal $false $d.IsReturnee
    }
    It 'still on vacation -> not a returnee' {
        $prior = [pscustomobject]@{ on_vacation = $true; end = '2026-06-10' }
        $d = Get-ReturneeDecision -IsFirstRun $false -CurOnVacation $true -CurConfidence 'high' -ReturnedToday $false -Prior $prior -Today $today
        Assert-Equal $false $d.IsReturnee
    }
}

Describe 'Test-AlreadyWelcomed' {
    $ledger = @(
        [pscustomobject]@{ alias='lea-Teammate2'; return_date='2026-06-03'; status='sent' },
        [pscustomobject]@{ alias='oz-Teammate8'; return_date='2026-06-03'; status='pending' }
    )
    It 'true for a sent entry'   { Assert-Equal $true  (Test-AlreadyWelcomed -Ledger $ledger -Alias 'lea-Teammate2' -ReturnDate '2026-06-03') }
    It 'false for pending entry' { Assert-Equal $false (Test-AlreadyWelcomed -Ledger $ledger -Alias 'oz-Teammate8' -ReturnDate '2026-06-03') }
    It 'false for unknown'       { Assert-Equal $false (Test-AlreadyWelcomed -Ledger $ledger -Alias 'nobody' -ReturnDate '2026-06-03') }
    It 'false for null ledger'   { Assert-Equal $false (Test-AlreadyWelcomed -Ledger $null -Alias 'x' -ReturnDate 'y') }
}

# --- Integration: scan orchestration against temp fixtures (no real personas touched) ---
Describe 'Get-VacationLengthPhrase' {
    It 'null -> null'                 { Assert-Equal $null (Get-VacationLengthPhrase -WorkDays $null) }
    It 'zero/negative -> null'        { Assert-Equal $null (Get-VacationLengthPhrase -WorkDays 0); Assert-Equal $null (Get-VacationLengthPhrase -WorkDays -3) }
    It 'non-numeric -> null'          { Assert-Equal $null (Get-VacationLengthPhrase -WorkDays 'abc') }
    It '1 -> quick day off'           { Assert-Equal 'quick day off' (Get-VacationLengthPhrase -WorkDays 1) }
    It '2 -> short break'             { Assert-Equal 'short break' (Get-VacationLengthPhrase -WorkDays 2) }
    It '3 -> few days off'            { Assert-Equal 'few days off' (Get-VacationLengthPhrase -WorkDays 3) }
    It '4 -> few days off'            { Assert-Equal 'few days off' (Get-VacationLengthPhrase -WorkDays 4) }
    It '5 -> week off'               { Assert-Equal 'week off' (Get-VacationLengthPhrase -WorkDays 5) }
    It '7 -> week off'               { Assert-Equal 'week off' (Get-VacationLengthPhrase -WorkDays 7) }
    It '9 -> long break'             { Assert-Equal 'long break' (Get-VacationLengthPhrase -WorkDays 9) }
    It '12 -> long stretch off'      { Assert-Equal 'long stretch off' (Get-VacationLengthPhrase -WorkDays 12) }
    It 'accepts string input'        { Assert-Equal 'short break' (Get-VacationLengthPhrase -WorkDays '2') }
}

Describe 'Build-WelcomeBackMessage' {
    It 'never includes raw vacation dates (Nir rule: qualitative only)' {
        $msg = Build-WelcomeBackMessage -FirstName 'Lea' -VacStart '2026-06-01' -VacEnd '2026-06-04' -VacDays 4 -WorkDays 4
        Assert-NotMatch '2026-06-01' $msg
        Assert-NotMatch '2026-06-04' $msg
        # No "(4 days)" style count either.
        Assert-NotMatch '\(\d+\s+days?\)' $msg
        Assert-Match 'Welcome back, <b>Lea</b>' $msg
        Assert-Match 'few days off' $msg
    }
    It 'uses working-days for the phrase, not calendar days' {
        # Calendar span 4 days but only 2 working days -> "short break", not "few days off".
        $msg = Build-WelcomeBackMessage -FirstName 'Sam' -VacDays 4 -WorkDays 2
        Assert-Match 'short break' $msg
        Assert-NotMatch 'few days off' $msg
    }
    It 'falls back to calendar days when working days are unknown' {
        $msg = Build-WelcomeBackMessage -FirstName 'Sam' -VacDays 5 -WorkDays $null
        Assert-Match 'week off' $msg
    }
    It 'renders a PR-flavored brief when highlights are present' {
        $msg = Build-WelcomeBackMessage -FirstName 'Lea' -WorkDays 5 -Highlights @('Add retry to ingestion (Oz)','Fix flaky test (Maya)')
        Assert-Match "team&rsquo;s PRs" $msg
        Assert-Match '<li>Add retry to ingestion \(Oz\)</li>' $msg
        Assert-Match '<li>Fix flaky test \(Maya\)</li>' $msg
    }
    It 'HTML-escapes highlight content' {
        $msg = Build-WelcomeBackMessage -FirstName 'Lea' -WorkDays 5 -Highlights @('Tighten <Foo> & <Bar>')
        Assert-Match 'Tighten &lt;Foo&gt; &amp; &lt;Bar&gt;' $msg
    }
    It 'caps the brief at 4 bullets' {
        $msg = Build-WelcomeBackMessage -FirstName 'Lea' -WorkDays 5 -Highlights @('a','b','c','d','e','f')
        Assert-Equal 4 ([regex]::Matches($msg, '<li>').Count)
    }
    It 'falls back to a generic catch-up line when there are no highlights' {
        $msg = Build-WelcomeBackMessage -FirstName 'Lea' -WorkDays 5 -Highlights @()
        Assert-NotMatch '<li>' $msg
        Assert-Match 'quick catch-up' $msg
    }
}

Describe 'Get-TeamDisplayNames' {
    It 'reads persona H1 display names and excludes nirvana' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vacwatch-roster-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Set-Content (Join-Path $tmp 'oz-Teammate8.md') "# Teammate8 (oz-Teammate8)`r`n- x`r`n" -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $tmp 'lea-Teammate2.md') "# Teammate2 (lea-Teammate2)`r`n- y`r`n" -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $tmp 'nirvana.md')    "# Nirvana (nirvana)`r`n" -Encoding UTF8 -NoNewline
        $names = @(Get-TeamDisplayNames -PeopleDir $tmp)
        Assert-Equal $true ($names -contains 'Teammate8')
        Assert-Equal $true ($names -contains 'Teammate2')
        Assert-Equal $false ($names -contains 'Nirvana')
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'missing dir -> empty (no throw)' {
        $names = @(Get-TeamDisplayNames -PeopleDir (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))))
        Assert-Equal 0 $names.Count
    }
}

Describe 'apply-vacation-state.ps1 scan (integration, temp dirs)' {
    function New-Fixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("vacwatch-" + [guid]::NewGuid().ToString('N'))
        $people = Join-Path $root 'team-personas\people'
        $state  = Join-Path $root 'team-vacation-watch\state'
        New-Item -ItemType Directory -Force -Path $people, $state | Out-Null
        Set-Content (Join-Path $people 'oz-Teammate8.md') "# Teammate8 (oz-Teammate8)`r`n`r`n## Employment`r`n- Gender: M`r`n`r`n## Daily observations`r`n- x`r`n" -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $people 'lea-Teammate2.md') "# Teammate2 (lea-Teammate2)`r`n`r`n## Notes`r`n- 2026-04-29: keep`r`n`r`n## Sources`r`n- y`r`n" -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $people 'nirvana.md')    "# Nirvana (nirvana)`r`n" -Encoding UTF8 -NoNewline
        return [pscustomobject]@{ Root=$root; People=$people; State=$state }
    }

    function Invoke-Scan {
        param($fx, $wqJson, [switch]$DryRun, [string]$AsOf='2026-06-04')
        $wqPath = Join-Path $fx.Root 'wq.json'
        Set-Content $wqPath $wqJson -Encoding UTF8
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$applyPs1,'-Mode','scan',
                  '-WorkIqJsonPath',$wqPath,'-AsOfDate',$AsOf,'-PeopleDir',$fx.People,'-StateDir',$fx.State)
        if ($DryRun) { $args += '-DryRun' }
        $out = & powershell @args 2>&1 | Out-String
        return $out
    }

    It 'DryRun writes NOTHING (personas + state untouched)' {
        $fx = New-Fixture
        $ozBefore  = Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8
        $leaBefore = Get-Content (Join-Path $fx.People 'lea-Teammate2.md') -Raw -Encoding UTF8
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate8","on_vacation":true,"start":"2026-06-03","end":"2026-06-10","returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -DryRun
        Assert-Match 'VACWATCH_RESULT' $out
        Assert-Match '"dry_run":true' $out
        Assert-Equal $ozBefore  (Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8)
        Assert-Equal $leaBefore (Get-Content (Join-Path $fx.People 'lea-Teammate2.md') -Raw -Encoding UTF8)
        Assert-Equal $false (Test-Path (Join-Path $fx.State 'vacation-status.json'))
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'real scan upserts only the managed block and writes a snapshot; never rewrites curated content' {
        $fx = New-Fixture
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate8","on_vacation":true,"start":"2026-06-03","end":"2026-06-10","returned_today":false,"confidence":"high"},{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq
        Assert-Match '"persona_updated":2' $out
        $oz  = Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8
        $lea = Get-Content (Join-Path $fx.People 'lea-Teammate2.md') -Raw -Encoding UTF8
        # Curated content preserved.
        Assert-Match '## Daily observations' $oz
        Assert-Match '- 2026-04-29: keep' $lea
        Assert-Match '## Sources' $lea
        # Managed block applied.
        Assert-Match 'On vacation 2026-06-03\.\.2026-06-10' $oz
        Assert-Match 'Not on vacation \(as of 2026-06-04\)' $lea
        # Snapshot written, nirvana.md excluded.
        $snap = Get-Content (Join-Path $fx.State 'vacation-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal '2026-06-04' $snap.as_of
        Assert-Equal $true ($snap.people.PSObject.Properties.Name -contains 'oz-Teammate8')
        Assert-Equal $false ($snap.people.PSObject.Properties.Name -contains 'nirvana')
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'first run does NOT flag returnees (no welcome on first scan)' {
        $fx = New-Fixture
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq
        Assert-Match '"first_run":true' $out
        Assert-Match '"returnees":\[\]' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'second scan detects a transition returnee with prior.end+1' {
        $fx = New-Fixture
        # Seed a prior snapshot: Lea on vacation ending 2026-06-02.
        $prior = '{ "as_of":"2026-06-02","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-05-28","end":"2026-06-02","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-04'
        Assert-Match '"alias":"lea-Teammate2"' $out
        Assert-Match '"return_date":"2026-06-03"' $out
        # Pending claim written to ledger.
        $led = Get-Content (Join-Path $fx.State 'welcomed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 'pending' (@($led)[0].status)
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'recurring-off weekday is subtracted from the gate: a Tue+Wed span with a standing Wednesday off is NOT welcomed (the every-Thursday-Lea bug)' {
        $fx = New-Fixture
        # Prior: Lea "on vacation" Tue 2026-06-30..Wed 2026-07-01 (what the free/busy read saw).
        $prior = '{ "as_of":"2026-07-01","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-30","end":"2026-07-01","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        # Current: back at work Thursday 07-02, and the reader reports Wednesday (dow 3) as a
        # recurring weekly day-off. Return date = end+1 = 2026-07-02.
        $wq = '{ "as_of":"2026-07-02","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high","recurring_off_days":[3]}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-07-02'
        # Only Tuesday is unexpected (1 working day) -> below the >=2 gate -> no welcome.
        Assert-Match '"returnees":\[\]' $out
        # No ledger claim written (ledger may exist as an empty array, but no entries).
        $ledPath = Join-Path $fx.State 'welcomed.json'
        $ledCount = 0
        if (Test-Path $ledPath) { $ledCount = @((Get-Content $ledPath -Raw -Encoding UTF8 | ConvertFrom-Json)).Count }
        Assert-Equal 0 $ledCount
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'control: the same Tue+Wed span WITHOUT a recurring-off weekday IS welcomed (proves the recurring flag is the only difference)' {
        $fx = New-Fixture
        $prior = '{ "as_of":"2026-07-01","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-30","end":"2026-07-01","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-07-02","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high","recurring_off_days":[]}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-07-02'
        Assert-Match '"alias":"lea-Teammate2"' $out
        Assert-Match '"return_date":"2026-07-02"' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'invalid WorkIQ JSON touches nothing and exits non-zero' {
        $fx = New-Fixture
        $ozBefore = Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8
        $wqPath = Join-Path $fx.Root 'wq.json'
        Set-Content $wqPath 'this is not json' -Encoding UTF8
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$applyPs1,'-Mode','scan',
                  '-WorkIqJsonPath',$wqPath,'-AsOfDate','2026-06-04','-PeopleDir',$fx.People,'-StateDir',$fx.State)
        & powershell @args 2>&1 | Out-Null
        Assert-Equal $false ($LASTEXITCODE -eq 0)
        Assert-Equal $ozBefore (Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8)
        Assert-Equal $false (Test-Path (Join-Path $fx.State 'vacation-status.json'))
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stale return (older than max_late_welcome_days) is not flagged for a post' {
        $fx = New-Fixture
        $prior = '{ "as_of":"2026-05-20","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-05-15","end":"2026-05-20","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-04'   # return would be 2026-05-21, 14 days stale
        Assert-Match '"returnees":\[\]' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'low-confidence carry-forward: a flaky read does NOT erase a known vacation or fake a return' {
        $fx = New-Fixture
        # Prior: Oz genuinely on vacation 2026-06-01..2026-06-10 (high).
        $prior = '{ "as_of":"2026-06-03","people":{ "oz-Teammate8":{ "on_vacation":true,"start":"2026-06-01","end":"2026-06-10","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        # This tick Oz fails to resolve -> low/false (the flake).
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate8","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"low"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-04'
        # No spurious returnee from the flake.
        Assert-Match '"returnees":\[\]' $out
        # Persona block preserved as "On vacation", not flapped to "Not on vacation".
        $oz = Get-Content (Join-Path $fx.People 'oz-Teammate8.md') -Raw -Encoding UTF8
        Assert-Match 'On vacation 2026-06-01\.\.2026-06-10' $oz
        # Snapshot keeps on_vacation=true (carried) so a later genuine return is still a transition.
        $snap = Get-Content (Join-Path $fx.State 'vacation-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $true ([bool]$snap.people.'oz-Teammate8'.on_vacation)
        Assert-Equal 'carried' "$($snap.people.'oz-Teammate8'.confidence)"
        Assert-Match 'oz-Teammate8' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'genuine return after a carried flake IS detected (end+1) on the next good working-day read' {
        $fx = New-Fixture
        # Prior snapshot was carried (on_vacation true) because the previous tick flaked.
        $prior = '{ "as_of":"2026-06-02","people":{ "oz-Teammate8":{ "on_vacation":true,"start":"2026-06-01","end":"2026-06-02","confidence":"carried" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        # Now Oz resolves cleanly and is back at work on a working day.
        $wq = '{ "as_of":"2026-06-03","people":[{"name":"Teammate8","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-03'
        Assert-Match '"alias":"oz-Teammate8"' $out
        Assert-Match '"return_date":"2026-06-03"' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'weekend return is held Friday, then surfaces Sunday with vacation details' {
        $fx = New-Fixture
        $prior = '{ "as_of":"2026-06-04","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-01","end":"2026-06-04","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wqFri = '{ "as_of":"2026-06-05","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $outFri = Invoke-Scan -fx $fx -wqJson $wqFri -AsOf '2026-06-05'
        Assert-Match '"returnees":\[\]' $outFri
        $lea = Get-Content (Join-Path $fx.People 'lea-Teammate2.md') -Raw -Encoding UTF8
        Assert-Match 'On vacation 2026-06-01\.\.2026-06-04' $lea
        $snapFri = Get-Content (Join-Path $fx.State 'vacation-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $true ([bool]$snapFri.people.'lea-Teammate2'.on_vacation)
        Assert-Equal 'carried' "$($snapFri.people.'lea-Teammate2'.confidence)"

        $wqSun = '{ "as_of":"2026-06-07","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $outSun = Invoke-Scan -fx $fx -wqJson $wqSun -AsOf '2026-06-07'
        Assert-Match '"alias":"lea-Teammate2"' $outSun
        Assert-Match '"return_date":"2026-06-05"' $outSun
        Assert-Match '"vac_start":"2026-06-01"' $outSun
        Assert-Match '"vac_end":"2026-06-04"' $outSun
        Assert-Match '"vac_days":4' $outSun
        Assert-Match '"vac_work_days":4' $outSun
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'weekend-only absence (Fri+Sat) is NEVER welcomed (0 working days)' {
        $fx = New-Fixture
        # Lea OOF Fri 2026-06-05 + Sat 2026-06-06; return would be Sun 2026-06-07.
        $prior = '{ "as_of":"2026-06-06","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-05","end":"2026-06-06","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-07","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-07'
        Assert-Match '"returnees":\[\]' $out
        # No ledger claim is written for a gated absence.
        $ledgerPath = Join-Path $fx.State 'welcomed.json'
        if (Test-Path $ledgerPath) {
            $led = @(Get-Content $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            Assert-Equal 0 (@($led | Where-Object { "$($_.alias)" -eq 'lea-Teammate2' }).Count)
        }
        # Snapshot still correctly flips Lea to not-on-vacation.
        $snap = Get-Content (Join-Path $fx.State 'vacation-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal $false ([bool]$snap.people.'lea-Teammate2'.on_vacation)
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'single working day flanked by the weekend (Thu+Fri+Sat) is NOT welcomed (1 working day)' {
        $fx = New-Fixture
        # Lea OOF Thu 2026-06-04 + Fri + Sat; return would be Sun 2026-06-07. Only Thursday is a working day.
        $prior = '{ "as_of":"2026-06-06","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-04","end":"2026-06-06","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-07","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-07'
        Assert-Match '"returnees":\[\]' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'exactly 2 working days (Wed+Thu) IS welcomed, carrying vac_work_days=2' {
        $fx = New-Fixture
        # Lea OOF Wed 2026-06-03 + Thu 2026-06-04; return Fri 2026-06-05 -> effective Sun 2026-06-07.
        $prior = '{ "as_of":"2026-06-04","people":{ "lea-Teammate2":{ "on_vacation":true,"start":"2026-06-03","end":"2026-06-04","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-07","people":[{"name":"Teammate2","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-07'
        Assert-Match '"alias":"lea-Teammate2"' $out
        Assert-Match '"return_date":"2026-06-05"' $out
        Assert-Match '"vac_work_days":2' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'explicit returned_today for a 1-working-day absence is NOT welcomed (span sourced from the current read)' {
        # Reproduces the Lea 2026-06-24 miss: an earlier run the same day already flipped her
        # to not-on-vacation (prior snapshot has no span), then the live free/busy returned_today
        # signal re-detects the return. The decoder now reports the just-ended OOF run on the
        # current read, so the gate measures 1 working day (Wed) and suppresses the welcome.
        $fx = New-Fixture
        $prior = '{ "as_of":"2026-06-24","people":{ "lea-Teammate2":{ "on_vacation":false,"start":null,"end":null,"confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-25","people":[{"name":"Teammate2","on_vacation":false,"start":"2026-06-24","end":"2026-06-24","returned_today":true,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-25'
        Assert-Match '"returnees":\[\]' $out
        # No ledger claim is written for a gated absence.
        $ledgerPath = Join-Path $fx.State 'welcomed.json'
        if (Test-Path $ledgerPath) {
            $led = @(Get-Content $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            Assert-Equal 0 (@($led | Where-Object { "$($_.alias)" -eq 'lea-Teammate2' }).Count)
        }
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'explicit returned_today for a 2-working-day absence IS welcomed (span from current read)' {
        # Same explicit path, but Tue+Wed (2 working days) clears the min-working-days gate.
        $fx = New-Fixture
        $prior = '{ "as_of":"2026-06-24","people":{ "lea-Teammate2":{ "on_vacation":false,"start":null,"end":null,"confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-25","people":[{"name":"Teammate2","on_vacation":false,"start":"2026-06-23","end":"2026-06-24","returned_today":true,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-25'
        Assert-Match '"alias":"lea-Teammate2"' $out
        Assert-Match '"return_date":"2026-06-25"' $out
        Assert-Match '"vac_work_days":2' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'future-dated return (return_date > today) is NOT welcomed (never welcome before they are back)' {
        $fx = New-Fixture
        # Prior says Oz on vacation through tomorrow; today he reads not-on-vac (e.g. a
        # corrected prior). The computed return_date would be tomorrow -> must not post today.
        $prior = '{ "as_of":"2026-06-03","people":{ "oz-Teammate8":{ "on_vacation":true,"start":"2026-06-01","end":"2026-06-05","confidence":"high" } } }'
        Set-Content (Join-Path $fx.State 'vacation-status.json') $prior -Encoding UTF8
        $wq = '{ "as_of":"2026-06-04","people":[{"name":"Teammate8","on_vacation":false,"start":null,"end":null,"returned_today":false,"confidence":"high"}] }'
        $out = Invoke-Scan -fx $fx -wqJson $wq -AsOf '2026-06-04'   # return would be 2026-06-06 (future)
        Assert-Match '"returnees":\[\]' $out
        Remove-Item $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-DailyOofString' {
    It 'full-day OOF (24/24) collapses to a vacation day "3"' {
        Assert-Equal '3' (ConvertTo-DailyOofString -Hourly ('3' * 24))
    }
    It 'per-meeting OOF noise (only a few OOF hours) collapses to "0" (NOT a vacation)' {
        # Teammate14-like: 2 OOF hours in a busy/free day -> not a vacation.
        $day = '000000000023322020222200'  # 24 slots, two '3's
        Assert-Equal '0' (ConvertTo-DailyOofString -Hourly $day)
    }
    It 'multi-day: a real all-day-OOF run surrounded by noisy days yields one "3" run' {
        $vac  = '3' * 24
        $noise = '000000000023322020222200'
        $hourly = $noise + $vac + $vac + $noise   # day0 noise, day1-2 vacation, day3 noise
        Assert-Equal '0330' (ConvertTo-DailyOofString -Hourly $hourly)
    }
    It 'a truncated final day (short slot count) never counts as vacation' {
        $hourly = ('3' * 24) + ('3' * 5)   # full day + a 5-slot stub
        Assert-Equal '30' (ConvertTo-DailyOofString -Hourly $hourly)
    }
    It 'near-full OOF (22/24) still counts (tolerates boundary slots)' {
        $day = ('3' * 22) + '00'
        Assert-Equal '3' (ConvertTo-DailyOofString -Hourly $day)
    }
    It 'empty input -> empty string' {
        Assert-Equal '' (ConvertTo-DailyOofString -Hourly '')
    }
}

Describe 'Get-FreeBusyVacationStatus' {
    $ws = [datetime]'2026-06-01'   # index 0 = Jun 1
    It 'on vacation: walks the contiguous OOF run to start..end (inclusive)' {
        # idx: 0=Jun1..6=Jun7 ; "0003330" -> OOF Jun4,Jun5,Jun6
        $r = Get-FreeBusyVacationStatus -FreeBusy '0003330' -WindowStart $ws -AsOf ([datetime]'2026-06-04')
        Assert-Equal $true $r.on_vacation
        Assert-Equal '2026-06-04' $r.start
        Assert-Equal '2026-06-06' $r.end
        Assert-Equal 'high' $r.confidence
    }
    It 'returned_today: yesterday OOF, today not -> true, and reports the just-ended run' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '0030000' -WindowStart $ws -AsOf ([datetime]'2026-06-04')
        Assert-Equal $false $r.on_vacation
        Assert-Equal $true $r.returned_today
        # The single-day OOF run that just ended (yesterday = Jun 3) is reported so the
        # min-working-days gate can measure a 1-day absence and suppress the welcome.
        Assert-Equal '2026-06-03' $r.start
        Assert-Equal '2026-06-03' $r.end
        Assert-Equal 'high' $r.confidence
    }
    It 'returned_today: multi-day ended run is walked back to start..end' {
        # idx: 0=Jun1(0) 1=Jun2(3) 2=Jun3(3) 3=Jun4(3) 4=Jun5(0); AsOf Jun5 -> yesterday Jun4 OOF.
        $r = Get-FreeBusyVacationStatus -FreeBusy '0333000' -WindowStart $ws -AsOf ([datetime]'2026-06-05')
        Assert-Equal $false $r.on_vacation
        Assert-Equal $true $r.returned_today
        Assert-Equal '2026-06-02' $r.start
        Assert-Equal '2026-06-04' $r.end
    }
    It 'not on vacation, working all week -> false/false high' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '0000000' -WindowStart $ws -AsOf ([datetime]'2026-06-04')
        Assert-Equal $false $r.on_vacation
        Assert-Equal $false $r.returned_today
        Assert-Equal 'high' $r.confidence
    }
    It 'no yesterday data (today is index 0) -> returned_today false' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '0000000' -WindowStart $ws -AsOf ([datetime]'2026-06-01')
        Assert-Equal $false $r.returned_today
    }
    It 'OOF run truncated at index 0: reports the visible start' {
        # "33300" with AsOf Jun2 (idx1) -> run 0..2 -> start Jun1, end Jun3
        $r = Get-FreeBusyVacationStatus -FreeBusy '33300' -WindowStart $ws -AsOf ([datetime]'2026-06-02')
        Assert-Equal $true $r.on_vacation
        Assert-Equal '2026-06-01' $r.start
        Assert-Equal '2026-06-03' $r.end
    }
    It 'today beyond the published window -> low confidence, not on vacation' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '0000000' -WindowStart $ws -AsOf ([datetime]'2026-06-20')
        Assert-Equal $false $r.on_vacation
        Assert-Equal 'low' $r.confidence
    }
    It 'empty free/busy string -> low confidence, not on vacation' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '' -WindowStart $ws -AsOf ([datetime]'2026-06-04')
        Assert-Equal $false $r.on_vacation
        Assert-Equal 'low' $r.confidence
    }
    It 'Busy/Tentative are NOT vacation (only code 3 counts)' {
        $r = Get-FreeBusyVacationStatus -FreeBusy '0001220' -WindowStart $ws -AsOf ([datetime]'2026-06-04')
        Assert-Equal $false $r.on_vacation
    }
    It 'real Oz string reproduces May26..Jun8 (regression on the live capture)' {
        # Captured 2026-06-04 starting 2026-05-21 (lookback 14): index 14 = Jun 4
        $oz = '00000333333333333332100000000000'
        $r = Get-FreeBusyVacationStatus -FreeBusy $oz -WindowStart ([datetime]'2026-05-21') -AsOf ([datetime]'2026-06-04')
        Assert-Equal $true $r.on_vacation
        Assert-Equal '2026-05-26' $r.start
        Assert-Equal '2026-06-08' $r.end
    }
}

Exit-WithTestResults

