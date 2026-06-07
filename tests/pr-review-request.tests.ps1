# Tests for the pr-review-request skill -- stats & gamification helpers (stats.ps1)
# plus runner-wiring assertions on run-pr-review-request.ps1.
#
# stats.ps1 is a pure module (no top-level side effects) so we dot-source it and
# call the functions directly. The runner has top-level side effects, so we only
# assert on its source text for the wiring.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$skillDir = Join-Path $repoRoot '.copilot\skills\pr-review-request'
$statsPs1 = Join-Path $skillDir 'stats.ps1'
$runner   = Join-Path $repoRoot '.copilot\skills\run-pr-review-request.ps1'
$skillMd  = Join-Path $skillDir 'SKILL.md'

if (-not (Test-Path $statsPs1)) { throw "stats.ps1 missing: $statsPs1" }
if (-not (Test-Path $runner))   { throw "runner missing: $runner" }

. $statsPs1
$runnerText = Get-Content $runner -Raw -Encoding UTF8

$tmpRoot = Join-Path $env:TEMP ("prrr-stats-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

Describe 'stats.ps1 source hygiene' {
    It 'is ASCII-only (PS 5.1 constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($statsPs1)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        Assert-Equal 0 $nonAscii "stats.ps1 must be ASCII-only; found $nonAscii non-ASCII byte(s)"
    }
    It 'parses without errors' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($statsPs1, [ref]$null, [ref]$errs) | Out-Null
        Assert-Equal 0 @($errs).Count "stats.ps1 should parse cleanly"
    }
}

Describe 'Format-PrDuration' {
    It 'renders sub-minute, minutes, hours and days' {
        Assert-Equal 'under a minute' (Format-PrDuration 0.4)
        Assert-Equal '23m'    (Format-PrDuration 23)
        Assert-Equal '1h 15m' (Format-PrDuration 75)
        Assert-Equal '3h'     (Format-PrDuration 180)
        Assert-Equal '1d 1h'  (Format-PrDuration 1500)
        Assert-Equal '2d'     (Format-PrDuration 2880)
    }
    It 'never goes negative' {
        Assert-Equal 'under a minute' (Format-PrDuration -10)
    }
}

Describe 'Get-PrWeekKey (Monday-date ISO-week substitute)' {
    It 'maps every day of a week to that week''s Monday' {
        Assert-Equal '2026-06-01' (Get-PrWeekKey ([datetime]'2026-06-04'))  # Thu
        Assert-Equal '2026-06-01' (Get-PrWeekKey ([datetime]'2026-06-07'))  # Sun
        Assert-Equal '2026-06-08' (Get-PrWeekKey ([datetime]'2026-06-08'))  # next Mon
        Assert-Equal '2026-06-01' (Get-PrWeekKey ([datetime]'2026-06-01'))  # Mon itself
    }
}

Describe 'Get-PrStatAverage / Add-PrStatSample' {
    It 'returns 0 with no samples' {
        $s = New-PrReviewStats
        Assert-Equal 0 (Get-PrStatAverage -Stats $s -Metric 'ttfr')
    }
    It 'averages the samples' {
        $s = New-PrReviewStats
        Add-PrStatSample -Stats $s -Metric 'ttfr' -Minutes 100
        Add-PrStatSample -Stats $s -Metric 'ttfr' -Minutes 140
        Assert-Equal 120 (Get-PrStatAverage -Stats $s -Metric 'ttfr')
    }
    It 'caps the rolling window at 100 samples' {
        $s = New-PrReviewStats
        1..150 | ForEach-Object { Add-PrStatSample -Stats $s -Metric 'ttm' -Minutes $_ }
        Assert-Equal 100 (@($s.ttm.samples).Count)
        # last 100 of 1..150 -> 51..150, average 100.5
        Assert-Equal 100.5 (Get-PrStatAverage -Stats $s -Metric 'ttm')
    }
}

Describe 'Get-PrMedian (p50)' {
    It 'returns 0 for an empty list' {
        Assert-Equal 0 (Get-PrMedian -Values @())
    }
    It 'returns the middle value for an odd count' {
        Assert-Equal 5 (Get-PrMedian -Values @(1, 5, 9))
    }
    It 'averages the two middle values for an even count' {
        Assert-Equal 7 (Get-PrMedian -Values @(1, 5, 9, 13))
    }
    It 'sorts numerically, not lexically' {
        # lexical sort would put 100 before 9 and pick the wrong middle
        Assert-Equal 9 (Get-PrMedian -Values @(100, 9, 2))
    }
    It 'is robust to a single huge outlier (unlike the mean)' {
        $vals = @(10, 12, 11, 13, 100000)
        Assert-Equal 12 (Get-PrMedian -Values $vals)
        Assert-True ((Get-PrMedian -Values $vals) -lt 1000)
    }
    It 'ignores nulls, NaN, Infinity and negatives' {
        Assert-Equal 5 (Get-PrMedian -Values @(1, 5, 9, -4, [double]::NaN))
    }
}

Describe 'Get-PrStatMedian / Get-PrBaseline / Set-PrBaseline' {
    It 'Get-PrStatMedian takes the median of rolling samples (not the mean)' {
        $s = New-PrReviewStats
        @(2, 4, 90) | ForEach-Object { Add-PrStatSample -Stats $s -Metric 'ttfr' -Minutes $_ }
        Assert-Equal 4 (Get-PrStatMedian -Stats $s -Metric 'ttfr')   # mean would be 32
    }
    It 'Get-PrBaseline falls back to the rolling median with no seed' {
        $s = New-PrReviewStats
        @(10, 20, 30) | ForEach-Object { Add-PrStatSample -Stats $s -Metric 'ttm' -Minutes $_ }
        Assert-Equal 20 (Get-PrBaseline -Stats $s -Metric 'ttm')
    }
    It 'Get-PrBaseline prefers the seeded p50 when present' {
        $s = New-PrReviewStats
        @(10, 20, 30) | ForEach-Object { Add-PrStatSample -Stats $s -Metric 'ttm' -Minutes $_ }
        Set-PrBaseline -Stats $s -Metric 'ttm' -Minutes 240 -SampleCount 50 -EligiblePrs 80
        Assert-Equal 240 (Get-PrBaseline -Stats $s -Metric 'ttm')
    }
    It 'Set-PrBaseline records sample/eligibility metadata' {
        $s = New-PrReviewStats
        Set-PrBaseline -Stats $s -Metric 'ttfr' -Minutes 95 -SampleCount 37 -EligiblePrs 82 -WindowDays 180
        Assert-Equal 95  ([double]$s.baseline.ttfr)
        Assert-Equal 37  ([int]$s.baseline.ttfrSamples)
        Assert-Equal 82  ([int]$s.baseline.ttfrEligiblePrs)
        Assert-Equal 180 ([int]$s.baseline.windowDays)
        Assert-Match 'ado-6mo-p50' ([string]$s.baseline.source)
    }
    It 'ignores a non-positive seed and uses the rolling median' {
        $s = New-PrReviewStats
        @(10, 20, 30) | ForEach-Object { Add-PrStatSample -Stats $s -Metric 'ttfr' -Minutes $_ }
        Set-PrBaseline -Stats $s -Metric 'ttfr' -Minutes 0
        Assert-Equal 20 (Get-PrBaseline -Stats $s -Metric 'ttfr')
    }
}

Describe 'Get-PrCompareClause' {
    It 'is empty without a baseline' {
        Assert-Empty (Get-PrCompareClause 50 0)
    }
    It 'says faster when under the baseline' {
        Assert-Match 'faster than our typical 2h' (Get-PrCompareClause 60 120)
    }
    It 'says slower when over the baseline' {
        Assert-Match 'slower than our typical 2h' (Get-PrCompareClause 150 120)
    }
    It 'says "right around" when within 10%' {
        Assert-Match 'right around our typical 2h' (Get-PrCompareClause 115 120)
    }
    It 'no longer uses the word "average"' {
        Assert-NotMatch 'average' (Get-PrCompareClause 60 120)
    }
}

Describe 'Get-PrSpeedLineHtml' {
    It 'flags a sub-30m review as fast even with no history' {
        Assert-Match 'Fast review!' (Get-PrSpeedLineHtml -Minutes 23 -BaselineMinutes 0)
    }
    It 'flags fast and includes the comparison when well under the baseline' {
        $line = Get-PrSpeedLineHtml -Minutes 65 -BaselineMinutes 120
        Assert-Match 'Fast review!' $line
        Assert-Match 'faster than our typical 2h' $line
    }
    It 'is not fast but still compares when slower than baseline' {
        $line = Get-PrSpeedLineHtml -Minutes 150 -BaselineMinutes 120
        Assert-NotMatch 'Fast review!' $line
        Assert-Match 'slower than our typical 2h' $line
    }
}

Describe 'Get-PrMergeLineHtml' {
    It 'states merge time without a baseline' {
        Assert-Match 'Merged 3h after opening' (Get-PrMergeLineHtml -Minutes 180 -BaselineMinutes 0)
    }
    It 'compares to the baseline merge time' {
        Assert-Match 'faster than our typical 4h' (Get-PrMergeLineHtml -Minutes 120 -BaselineMinutes 240)
    }
}

Describe 'Add-PrReviewerCredit' {
    It 'increments daily, weekly and total and reports week-top' {
        $s = New-PrReviewStats
        $when = [datetime]'2026-06-04T18:00:00'
        $c = $null
        1..3 | ForEach-Object { $c = Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-a' -DisplayName 'Reviewer A' -When $when }
        Assert-Equal 3 $c.DailyCount
        Assert-Equal 3 $c.WeeklyCount
        Assert-Equal 3 $c.Total
        Assert-True  $c.IsWeekTop
    }
    It 'loses week-top when another reviewer pulls ahead in the same week' {
        $s = New-PrReviewStats
        $when = [datetime]'2026-06-04T18:00:00'
        1..2 | ForEach-Object { [void](Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-a' -DisplayName 'A' -When $when) }
        $cb = $null
        1..3 | ForEach-Object { $cb = Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-b' -DisplayName 'B' -When $when }
        Assert-True $cb.IsWeekTop  # B has 3 vs A's 2
        $ca = Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-a' -DisplayName 'A' -When $when  # A now 3, ties B
        Assert-True $ca.IsWeekTop  # co-top counts as top
    }
    It 'falls back to normalized display name when no key supplied' {
        $s = New-PrReviewStats
        $c = Add-PrReviewerCredit -Stats $s -ReviewerKey '' -DisplayName 'Casey Jones'
        Assert-Equal 1 $c.Total
        Assert-True ($s.reviewers.ContainsKey('casey jones'))
    }
}

Describe 'Get-PrReviewerCallout' {
    It 'is empty when nothing is exceptional' {
        Assert-Empty (Get-PrReviewerCallout -DisplayName 'A' -DailyCount 1 -WeeklyCount 1 -Total 4 -IsWeekTop $false)
    }
    It 'celebrates a weekly milestone' {
        Assert-Match 'Reviewer of the Week' (Get-PrReviewerCallout -DisplayName 'A' -DailyCount 1 -WeeklyCount 5 -Total 9 -IsWeekTop $true)
    }
    It 'celebrates a daily hat-trick' {
        Assert-Match 'Hat-trick' (Get-PrReviewerCallout -DisplayName 'A' -DailyCount 3 -WeeklyCount 3 -Total 8 -IsWeekTop $false)
    }
    It 'HTML-encodes the reviewer name (no raw tags leak)' {
        $out = Get-PrReviewerCallout -DisplayName 'X <b>y</b>' -DailyCount 3 -WeeklyCount 3 -Total 8 -IsWeekTop $false
        Assert-NotMatch '<b>y</b>' $out
        Assert-Match '&lt;b&gt;y&lt;/b&gt;' $out
    }
    It 'returns at most one badge line (no internal line breaks)' {
        $out = Get-PrReviewerCallout -DisplayName 'A' -DailyCount 5 -WeeklyCount 10 -Total 25 -IsWeekTop $true
        Assert-True ($out.Length -gt 0)
        Assert-NotMatch '<br' $out
    }
}

Describe 'Read/Write-PrReviewStats round-trip' {
    It 'creates a fresh empty object when the file is missing' {
        $p = Join-Path $tmpRoot 'missing.json'
        $s = Read-PrReviewStats -Path $p
        Assert-Equal 0 (@($s.ttfr.samples).Count)
        Assert-Equal 0 (@($s.reviewers.Keys).Count)
    }
    It 'preserves samples, processed keys and reviewer buckets through a save/load' {
        $p = Join-Path $tmpRoot 'rt.json'
        $s = New-PrReviewStats
        Add-PrStatSample -Stats $s -Metric 'ttfr' -Minutes 42
        Add-PrProcessedEvent -Stats $s -Key 'fr:777'
        [void](Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-z' -DisplayName 'Zoe' -When ([datetime]'2026-06-04T10:00:00'))
        Write-PrReviewStats -Path $p -Stats $s
        $s2 = Read-PrReviewStats -Path $p
        Assert-Equal 42 (Get-PrStatAverage -Stats $s2 -Metric 'ttfr')
        Assert-True (Test-PrEventProcessed -Stats $s2 -Key 'fr:777')
        Assert-Equal 1 ([int]$s2.reviewers['id-z'].total)
    }
    It 'survives a single-sample array (no collapse)' {
        $p = Join-Path $tmpRoot 'single.json'
        $s = New-PrReviewStats
        Add-PrStatSample -Stats $s -Metric 'ttm' -Minutes 99
        Write-PrReviewStats -Path $p -Stats $s
        $s2 = Read-PrReviewStats -Path $p
        Assert-Equal 1 (@($s2.ttm.samples).Count)
        Assert-Equal 99 (Get-PrStatAverage -Stats $s2 -Metric 'ttm')
    }
    It 'round-trips the seeded baseline block' {
        $p = Join-Path $tmpRoot 'baseline-rt.json'
        $s = New-PrReviewStats
        Set-PrBaseline -Stats $s -Metric 'ttfr' -Minutes 78.5 -SampleCount 40 -EligiblePrs 95 -WindowDays 180
        Set-PrBaseline -Stats $s -Metric 'ttm'  -Minutes 540  -SampleCount 60 -EligiblePrs 60 -WindowDays 180
        Write-PrReviewStats -Path $p -Stats $s
        $s2 = Read-PrReviewStats -Path $p
        Assert-Equal 78.5 (Get-PrBaseline -Stats $s2 -Metric 'ttfr')
        Assert-Equal 540  (Get-PrBaseline -Stats $s2 -Metric 'ttm')
        Assert-Equal 40   ([int]$s2.baseline.ttfrSamples)
    }
    It 'THROWS on a corrupt file (so the caller can skip rather than wipe)' {
        $p = Join-Path $tmpRoot 'corrupt.json'
        Set-Content -Path $p -Value '{ this is not json' -Encoding UTF8
        $threw = $false
        try { Read-PrReviewStats -Path $p | Out-Null } catch { $threw = $true }
        Assert-True $threw
    }
}

Describe 'Optimize-PrReviewStats pruning' {
    It 'drops processed keys older than the retention window' {
        $s = New-PrReviewStats
        $s.processed['old'] = (Get-Date).AddDays(-90).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $s.processed['new'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Optimize-PrReviewStats -Stats $s
        Assert-False ($s.processed.ContainsKey('old'))
        Assert-True  ($s.processed.ContainsKey('new'))
    }
    It 'drops daily/weekly buckets older than ~8 weeks but keeps recent ones' {
        $s = New-PrReviewStats
        [void](Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-a' -DisplayName 'A' -When (Get-Date).AddDays(-200))
        [void](Add-PrReviewerCredit -Stats $s -ReviewerKey 'id-a' -DisplayName 'A' -When (Get-Date))
        Optimize-PrReviewStats -Stats $s
        Assert-Equal 1 (@($s.reviewers['id-a'].daily.Keys).Count)
    }
}

Describe 'runner wiring (run-pr-review-request.ps1)' {
    It 'dot-sources the stats module' {
        Assert-Match "stats\.ps1" $runnerText
    }
    It 'dot-sources the shared ADO helpers module' {
        Assert-Match "ado-helpers\.ps1" $runnerText
    }
    It 'defines and uses the review-stats.json state file' {
        Assert-Match "review-stats\.json" $runnerText
    }
    It 'reads stats defensively via Get-ReviewStatsSafe' {
        Assert-Match 'Get-ReviewStatsSafe' $runnerText
    }
    It 'uses the p50 baseline (Get-PrBaseline), not the mean' {
        Assert-Match 'Get-PrBaseline' $runnerText
        Assert-Match 'p50 baseline' $runnerText
        Assert-NotMatch 'Get-PrStatAverage' $runnerText
    }
    It 'guards stat mutation with idempotency keys (fr:/ttm:)' {
        Assert-Match 'Test-PrEventProcessed' $runnerText
        Assert-Match '"fr:\$eid"' $runnerText
        Assert-Match '"ttm:\$eid"' $runnerText
    }
    It 'persists stats before sending the update email' {
        Assert-Match 'Persist stats BEFORE the send' $runnerText
    }
    It 'prefers ADO closedDate for time-to-merge' {
        Assert-Match 'closedDate' $runnerText
    }
    It 'passes ExtraHtml into the first-review body' {
        Assert-Match '-ExtraHtml \$extra' $runnerText
    }
}

# cleanup
Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue

Exit-WithTestResults
