#Requires -Version 5.1
# ---------------------------------------------------------------------------
# pr-review-request -- stats & gamification helpers.
#
# Pure functions only. The Read/Write helpers take an explicit path so the whole
# module can be dot-sourced and unit-tested without touching the runner's global
# state. ASCII-only source (PS 5.1 constraint); all glyphs are HTML entities.
#
# Persisted shape (state/review-stats.json):
#   {
#     "ttfr":      { "samples": [<minutes>, ...] },   # time-to-first-review
#     "ttm":       { "samples": [<minutes>, ...] },   # time-to-merge
#     "baseline":  { "ttfr": <p50 min>, "ttm": <p50 min>, "computedAt": "<iso>",
#                    "windowDays": 180, "ttfrSamples": n, "ttmSamples": n,
#                    "ttfrEligiblePrs": n, "ttmEligiblePrs": n, "source": "ado-6mo-p50" },
#     "reviewers": { "<key>": { "displayName", "total", "daily": {"yyyy-MM-dd": n},
#                               "weekly": {"<mondayDate>": n} } },
#     "processed": { "<eventKey>": "<iso>" },          # idempotency guard
#     "updatedAt": "<iso>"
#   }
#
# BASELINE (the comparison yardstick): the status-update text ("X% faster than our
# typical 2h") compares against a *median* (p50), NOT a mean. The mean of a handful
# of samples is wildly noisy (two reviews of 24m + 167m average to ~95m and swing
# hard on the next sample), so Nir asked for a p50 baseline grounded in 6 months of
# real history. seed-baseline.ps1 pulls ~180 days of PRs and writes the persisted
# `baseline` block. Get-PrBaseline prefers that seeded p50; with no seed it falls
# back to the live median of the rolling window (still a median, never the mean).
#
# Reviewer keys are the stable ADO identity id when known, else the normalized
# display name. Daily/weekly buckets use LOCAL business time (the runner host is
# IST), so an evening review lands on the right day. Durations are computed in UTC.
# ---------------------------------------------------------------------------

$script:PrStatSampleCap   = 100   # rolling window for averages
$script:PrProcessedMaxAge = 30    # days to retain idempotency keys
$script:PrBucketMaxAgeDays = 56   # ~8 weeks of daily/weekly buckets

# Render a minutes duration as a compact human string: "under a minute", "45m",
# "1h 23m", "3h", "2d 4h".
function Format-PrDuration {
    param([double] $Minutes)
    if ($Minutes -lt 0) { $Minutes = 0 }
    $m = [int][math]::Round($Minutes)
    if ($m -lt 1)  { return 'under a minute' }
    if ($m -lt 60) { return "${m}m" }
    $h  = [int][math]::Floor($m / 60)
    $rm = $m % 60
    if ($h -lt 24) {
        if ($rm -eq 0) { return "${h}h" }
        return "${h}h ${rm}m"
    }
    $d  = [int][math]::Floor($h / 24)
    $rh = $h % 24
    if ($rh -eq 0) { return "${d}d" }
    return "${d}d ${rh}h"
}

# Monday-date "yyyy-MM-dd" as a culture-independent ISO-week substitute.
function Get-PrWeekKey {
    param([datetime] $Date)
    $offset = (([int]$Date.DayOfWeek) + 6) % 7   # Mon=0 .. Sun=6
    return $Date.Date.AddDays(-$offset).ToString('yyyy-MM-dd')
}

function New-PrReviewStats {
    return @{
        ttfr      = @{ samples = @() }
        ttm       = @{ samples = @() }
        baseline  = $null
        reviewers = @{}
        processed = @{}
        updatedAt = $null
    }
}

# Recursively turn ConvertFrom-Json output (PSCustomObject / Object[]) into plain
# hashtables/arrays/scalars so we can mutate and round-trip cleanly.
function ConvertTo-PrHashtable {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [string] -or $Obj -is [System.ValueType]) { return $Obj }
    if ($Obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($Obj.Keys)) { $h["$k"] = ConvertTo-PrHashtable $Obj[$k] }
        return $h
    }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-PrHashtable $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($item in $Obj) { $list += ,(ConvertTo-PrHashtable $item) }
        return ,$list
    }
    return $Obj
}

# Read stats from disk. Missing/empty -> a fresh empty stats object. A corrupt
# file THROWS (so the caller can choose to skip stats rather than wipe history).
function Read-PrReviewStats {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) { return (New-PrReviewStats) }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-PrReviewStats) }
    $obj = $raw | ConvertFrom-Json   # throws on corrupt JSON -- intentional
    $h   = ConvertTo-PrHashtable $obj
    $stats = New-PrReviewStats
    if ($h.ContainsKey('ttfr') -and $h['ttfr'] -and $h['ttfr'].ContainsKey('samples') -and $h['ttfr']['samples']) {
        $stats.ttfr.samples = @($h['ttfr']['samples'] | ForEach-Object { [double]$_ })
    }
    if ($h.ContainsKey('ttm') -and $h['ttm'] -and $h['ttm'].ContainsKey('samples') -and $h['ttm']['samples']) {
        $stats.ttm.samples = @($h['ttm']['samples'] | ForEach-Object { [double]$_ })
    }
    if ($h.ContainsKey('reviewers') -and $h['reviewers'] -is [hashtable]) { $stats.reviewers = $h['reviewers'] }
    if ($h.ContainsKey('processed') -and $h['processed'] -is [hashtable]) { $stats.processed = $h['processed'] }
    if ($h.ContainsKey('baseline')  -and $h['baseline']  -is [hashtable]) { $stats.baseline  = $h['baseline'] }
    if ($h.ContainsKey('updatedAt')) { $stats.updatedAt = $h['updatedAt'] }
    return $stats
}

# Atomic write (temp + Move-Item -Force), depth 10 so nested reviewer buckets survive.
function Write-PrReviewStats {
    param(
        [Parameter(Mandatory)] [string]    $Path,
        [Parameter(Mandatory)] [hashtable] $Stats
    )
    $Stats.updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Stats | ConvertTo-Json -Depth 10
    $tmp  = "$Path.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-PrStatAverage {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [Parameter(Mandatory)] [ValidateSet('ttfr','ttm')] [string] $Metric
    )
    $s = @($Stats[$Metric].samples)
    if ($s.Count -eq 0) { return 0.0 }
    $sum = 0.0
    foreach ($x in $s) { $sum += [double]$x }
    return ($sum / $s.Count)
}

# p50 (median) of a numeric list. Robust to outliers in a way the mean is not, which
# is exactly why it's our baseline. Numeric (not lexical) sort; ignores nulls, NaN,
# Infinity and negative durations; returns 0.0 for an empty/all-invalid input.
function Get-PrMedian {
    param([double[]] $Values)
    $clean = @()
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        $d = [double]$v
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -lt 0) { continue }
        $clean += $d
    }
    $n = $clean.Count
    if ($n -eq 0) { return 0.0 }
    $sorted = @($clean | Sort-Object)
    if ($n % 2 -eq 1) { return [double]$sorted[[int][math]::Floor($n / 2)] }
    $hi = [int]($n / 2)
    return (([double]$sorted[$hi - 1] + [double]$sorted[$hi]) / 2.0)
}

# Median of the live rolling-window samples for a metric (fallback baseline when no
# seeded 6-month baseline is present).
function Get-PrStatMedian {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [Parameter(Mandatory)] [ValidateSet('ttfr','ttm')] [string] $Metric
    )
    return (Get-PrMedian -Values (@($Stats[$Metric].samples) | ForEach-Object { [double]$_ }))
}

# THE comparison baseline. Prefers the seeded 6-month p50 in $Stats.baseline.<metric>;
# if that's missing or non-positive, falls back to the live rolling-window median.
# Never returns the arithmetic mean.
function Get-PrBaseline {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [Parameter(Mandatory)] [ValidateSet('ttfr','ttm')] [string] $Metric
    )
    $b = $Stats['baseline']
    if ($b -is [hashtable] -and $b.ContainsKey($Metric) -and $null -ne $b[$Metric]) {
        $seed = [double]$b[$Metric]
        if ($seed -gt 0) { return $seed }
    }
    return (Get-PrStatMedian -Stats $Stats -Metric $Metric)
}

# Write/refresh the persisted baseline block for one metric. Seeded by seed-baseline.ps1.
function Set-PrBaseline {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [Parameter(Mandatory)] [ValidateSet('ttfr','ttm')] [string] $Metric,
        [Parameter(Mandatory)] [double] $Minutes,
        [int] $SampleCount = 0,
        [int] $EligiblePrs = 0,
        [int] $WindowDays = 180,
        [string] $Source = 'ado-6mo-p50'
    )
    if (-not ($Stats['baseline'] -is [hashtable])) { $Stats['baseline'] = @{} }
    $b = $Stats['baseline']
    $b[$Metric]              = [double]$Minutes
    $b["${Metric}Samples"]  = [int]$SampleCount
    $b["${Metric}EligiblePrs"] = [int]$EligiblePrs
    $b['windowDays']        = [int]$WindowDays
    $b['source']            = [string]$Source
    $b['computedAt']        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Add-PrStatSample {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [Parameter(Mandatory)] [ValidateSet('ttfr','ttm')] [string] $Metric,
        [Parameter(Mandatory)] [double] $Minutes
    )
    $s = @($Stats[$Metric].samples)
    $s += [double]$Minutes
    if ($s.Count -gt $script:PrStatSampleCap) { $s = @($s | Select-Object -Last $script:PrStatSampleCap) }
    $Stats[$Metric].samples = $s
}

# Idempotency: has this (event) already been folded into the stats?
function Test-PrEventProcessed {
    param([Parameter(Mandatory)] [hashtable] $Stats, [Parameter(Mandatory)] [string] $Key)
    return ([bool]$Stats.processed.ContainsKey($Key))
}

function Add-PrProcessedEvent {
    param([Parameter(Mandatory)] [hashtable] $Stats, [Parameter(Mandatory)] [string] $Key)
    $Stats.processed[$Key] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# Credit a reviewer with one first-review. Returns the post-increment counts plus
# whether they are (co-)top of their week. Keyed by stable id when available.
function Add-PrReviewerCredit {
    param(
        [Parameter(Mandatory)] [hashtable] $Stats,
        [string] $ReviewerKey,
        [string] $DisplayName,
        [datetime] $When = (Get-Date)
    )
    $key = $ReviewerKey
    if ([string]::IsNullOrWhiteSpace($key)) { $key = ([string]$DisplayName).Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = 'unknown' }

    if (-not $Stats.reviewers.ContainsKey($key)) {
        $Stats.reviewers[$key] = @{ displayName = $DisplayName; total = 0; daily = @{}; weekly = @{} }
    }
    $r = $Stats.reviewers[$key]
    if ($DisplayName) { $r.displayName = $DisplayName }
    if (-not $r.ContainsKey('daily')  -or -not ($r.daily  -is [hashtable])) { $r.daily  = @{} }
    if (-not $r.ContainsKey('weekly') -or -not ($r.weekly -is [hashtable])) { $r.weekly = @{} }

    $dayKey  = $When.ToString('yyyy-MM-dd')
    $weekKey = Get-PrWeekKey $When
    $r.total           = [int]$r.total + 1
    $r.daily[$dayKey]  = [int]($r.daily[$dayKey])  + 1
    $r.weekly[$weekKey]= [int]($r.weekly[$weekKey]) + 1

    $myWeek = [int]$r.weekly[$weekKey]
    $isTop  = $true
    foreach ($other in @($Stats.reviewers.Keys)) {
        if ($other -eq $key) { continue }
        $ow = $Stats.reviewers[$other]
        $oc = 0
        if ($ow -is [hashtable] -and $ow.ContainsKey('weekly') -and $ow.weekly -is [hashtable] -and $ow.weekly.ContainsKey($weekKey)) {
            $oc = [int]$ow.weekly[$weekKey]
        }
        if ($oc -gt $myWeek) { $isTop = $false; break }
    }

    return [PSCustomObject]@{
        DailyCount  = [int]$r.daily[$dayKey]
        WeeklyCount = $myWeek
        Total       = [int]$r.total
        IsWeekTop   = $isTop
    }
}

# Prune idempotency keys and stale daily/weekly buckets so the file stays small.
function Optimize-PrReviewStats {
    param([Parameter(Mandatory)] [hashtable] $Stats, [datetime] $Now = (Get-Date))
    $procCutoff = $Now.ToUniversalTime().AddDays(-$script:PrProcessedMaxAge)
    $keep = @{}
    foreach ($k in @($Stats.processed.Keys)) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Stats.processed[$k], [ref]$dt)) {
            if ($dt.ToUniversalTime() -ge $procCutoff) { $keep[$k] = $Stats.processed[$k] }
        } else {
            $keep[$k] = $Stats.processed[$k]
        }
    }
    $Stats.processed = $keep

    $dayCutoff = $Now.Date.AddDays(-$script:PrBucketMaxAgeDays)
    foreach ($name in @($Stats.reviewers.Keys)) {
        $r = $Stats.reviewers[$name]
        if (-not ($r -is [hashtable])) { continue }
        foreach ($bucket in @('daily','weekly')) {
            if ($r.ContainsKey($bucket) -and $r[$bucket] -is [hashtable]) {
                $kept = @{}
                foreach ($dk in @($r[$bucket].Keys)) {
                    $dd = [datetime]::MinValue
                    if ([datetime]::TryParseExact([string]$dk, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dd)) {
                        if ($dd -ge $dayCutoff) { $kept[$dk] = $r[$bucket][$dk] }
                    } else {
                        $kept[$dk] = $r[$bucket][$dk]
                    }
                }
                $r[$bucket] = $kept
            }
        }
    }
}

# "12% faster than our typical 1h 14m" / "right around our typical 1h 14m" /
# "20% slower than our typical ...". "Typical" = our p50 (median) baseline. Empty
# when there is no baseline yet.
function Get-PrCompareClause {
    param([double] $Minutes, [double] $BaselineMinutes)
    if ($BaselineMinutes -le 0) { return '' }
    $baseDur = Format-PrDuration $BaselineMinutes
    $diff   = $BaselineMinutes - $Minutes
    $pct    = [int][math]::Round([math]::Abs($diff) / $BaselineMinutes * 100)
    if ($pct -lt 10) { return "right around our typical $baseDur" }
    if ($diff -gt 0) { return "$pct% faster than our typical $baseDur" }
    return "$pct% slower than our typical $baseDur"
}

# One first-review stat line. A PR is "fast" if reviewed within 30 min, or within
# 60% of the baseline. Includes the baseline comparison when we have history.
function Get-PrSpeedLineHtml {
    param([double] $Minutes, [double] $BaselineMinutes)
    $dur  = Format-PrDuration $Minutes
    $fast = ($Minutes -le 30) -or ($BaselineMinutes -gt 0 -and $Minutes -le 0.6 * $BaselineMinutes)
    if ($BaselineMinutes -gt 0) {
        $cmp = Get-PrCompareClause $Minutes $BaselineMinutes
        if ($fast) { return "&#9889; <b>Fast review!</b> $dur to first look &mdash; $cmp." }
        return "&#128202; $dur to first review &mdash; $cmp."
    }
    if ($fast) { return "&#9889; <b>Fast review!</b> $dur to first look." }
    return "&#128202; $dur to first review."
}

# One completion stat line (merged PRs only).
function Get-PrMergeLineHtml {
    param([double] $Minutes, [double] $BaselineMinutes)
    $dur = Format-PrDuration $Minutes
    if ($BaselineMinutes -gt 0) {
        $cmp = Get-PrCompareClause $Minutes $BaselineMinutes
        return "&#9201; Merged $dur after opening &mdash; $cmp."
    }
    return "&#9201; Merged $dur after opening."
}

# Creative gamification line for an exceptional reviewer. Encodes the name itself.
# Returns at most ONE badge (highest priority) to keep updates terse; '' if nothing
# is exceptional. "Reviews" here means first-review credits (first responder).
function Get-PrReviewerCallout {
    param(
        [string] $DisplayName,
        [int]    $DailyCount,
        [int]    $WeeklyCount,
        [int]    $Total,
        [bool]   $IsWeekTop
    )
    $who    = [System.Net.WebUtility]::HtmlEncode([string]$DisplayName)
    $badges = New-Object System.Collections.Generic.List[string]

    # Weekly milestones (highest signal).
    if ($WeeklyCount -ge 10) {
        $badges.Add("&#128640; <b>$who</b> has picked up <b>$WeeklyCount</b> reviews this week &mdash; absolute machine!")
    } elseif ($WeeklyCount -ge 5) {
        $badges.Add("&#127942; <b>$who</b> is on <b>$WeeklyCount</b> reviews this week &mdash; Reviewer of the Week pace!")
    }
    # Daily streaks.
    if ($DailyCount -ge 5) {
        $badges.Add("&#128293; <b>$who</b> is on fire &mdash; <b>$DailyCount</b> reviews today!")
    } elseif ($DailyCount -eq 3) {
        $badges.Add("&#127913; Hat-trick! That's <b>$who</b>'s 3rd review today.")
    }
    # Week crown (only when not already a weekly-milestone holder).
    if ($IsWeekTop -and $WeeklyCount -ge 3 -and $WeeklyCount -lt 5) {
        $badges.Add("&#128081; <b>$who</b> is this week's top reviewer ($WeeklyCount).")
    }
    # Career milestones.
    if ($Total -eq 25 -or $Total -eq 50 -or $Total -eq 100 -or $Total -eq 250) {
        $badges.Add("&#127881; <b>$who</b>'s <b>$Total</b>th review &mdash; legend!")
    }

    if ($badges.Count -eq 0) { return '' }
    return [string]($badges[0])
}
