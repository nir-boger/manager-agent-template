# Tests for the semester-plan-report skill.
#
# Strategy:
#   - Validate the manifest entry shape (config/skills.json).
#   - Validate the runner is ASCII-only (PS 5.1 source constraint).
#   - Confirm critical content rules in the runner: hardcoded recipients,
#     joke pool present, signature helper dot-sourced, single-instance lock.
#   - Smoke-test the Python builder against the checked-in fixtures
#     (state/link-tree.json + state/all-items.json) into a temp output so
#     production state is not touched.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\semester-plan-report'
$runner     = Join-Path $repoRoot '.copilot\skills\run-semester-plan-report.ps1'
$builder    = Join-Path $skillDir 'build.py'
$manifest   = Join-Path $repoRoot 'config\skills.json'

if (-not (Test-Path $skillDir))   { throw "skill folder missing: $skillDir" }
if (-not (Test-Path $runner))     { throw "runner missing: $runner" }
if (-not (Test-Path $builder))    { throw "build.py missing: $builder" }
if (-not (Test-Path $manifest))   { throw "manifest missing: $manifest" }

$manifestObj = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = $manifestObj.skills | Where-Object { $_.name -eq 'semester-plan-report' } | Select-Object -First 1

$runnerText = Get-Content $runner -Raw -Encoding UTF8

Describe 'semester-plan-report manifest entry' {

    It 'exists in config/skills.json' {
        Assert-True ($null -ne $entry) "expected an entry named 'semester-plan-report'"
    }

    It 'has surface=engine and category=reviews-dri' {
        Assert-Equal 'engine'      $entry.surface
        Assert-Equal 'reviews-dri' $entry.category
    }

    It 'points at the skill folder and runner' {
        Assert-Equal '.copilot/skills/semester-plan-report'              $entry.path
        Assert-Equal '.copilot/skills/run-semester-plan-report.ps1'      $entry.entrypoint_path
    }

    It 'is visible in AGENTS.md and ships in snapshot' {
        Assert-True $entry.show_in_agents
        Assert-True $entry.ship_in_snapshot
    }

    It 'includes the primary trigger phrases' {
        $triggers = ($entry.triggers -join '|').ToLower()
        Assert-Match 'run semester plan'         $triggers
        Assert-Match 'semester pulse'            $triggers
        Assert-Match 'build semester plan'       $triggers
    }
}

Describe 'semester-plan-report runner script' {

    It 'is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($runner)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'hardcodes the three external recipients' {
        Assert-Match 'someone@example.com'  $runnerText
        Assert-Match 'someone@example.com'   $runnerText
        Assert-Match 'someone@example.com' $runnerText
    }

    It 'puts Nir on CC for external sends' {
        Assert-Match 'Nir\someone@example.com' $runnerText
    }

    It 'puts the team alias (team@example.com) on CC for external sends' {
        Assert-Match 'someone@example.com' $runnerText
    }

    It 'dot-sources the shared signature helper' {
        Assert-Match 'signature\.ps1'      $runnerText
        Assert-Match 'Get-NirvanaSignature' $runnerText
    }

    It 'includes a joke pool (multiple options for rotation)' {
        Assert-Match 'jokePool'            $runnerText
        Assert-Match 'Get-Random'          $runnerText
    }

    It 'acquires a single-instance lock' {
        Assert-Match 'semester-plan-report\.lock' $runnerText
        Assert-Match '\$PID'                       $runnerText
    }

    It 'self-gates against the current ADO iteration finishDate' {
        Assert-Match 'finishDate'          $runnerText
        Assert-Match 'Your Team' $runnerText
    }

    It 'supports DryRun / Force / PreviewOnly switches' {
        Assert-Match '\[switch\]\$DryRun'      $runnerText
        Assert-Match '\[switch\]\$Force'       $runnerText
        Assert-Match '\[switch\]\$PreviewOnly' $runnerText
    }

    It 'records an idempotency stamp after sending' {
        Assert-Match 'last-sent\.json' $runnerText
    }
}

Describe 'semester-plan-report build.py' {

    It 'reads its inputs relative to the skill folder (no absolute session-state path)' {
        $py = Get-Content $builder -Raw -Encoding UTF8
        Assert-NotMatch 'session-state'  $py
        Assert-Match    'Path\(__file__\)' $py
    }

    It 'produces a single-file HTML dashboard' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-semester-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try {
            $env:SEMESTER_PLAN_OUT = $tmp
            $out = & python $builder 2>&1
            if ($LASTEXITCODE -ne 0) { throw "build.py exit $LASTEXITCODE  out=$out" }
            Assert-True (Test-Path $tmp) "expected dashboard at $tmp"
            $html = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match '<!doctype html>' $html.ToLower()
            Assert-Match 'cp-bg'           $html      # Clawpilot theme variable
            Assert-Match 'pulse-verdict'   $html      # Semester Pulse block rendered
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $env:SEMESTER_PLAN_OUT = $null
        }
    }

    It 'reports a sensible Semester Pulse summary' {
        $out = (& python $builder 2>&1) -join "`n"
        Assert-Match 'features:\s*27'       $out
        Assert-Match 'pbis-done:\s*\d+/\d+' $out
        Assert-Match 'verdict:'             $out
    }

    It 'v3: renders the Capacity & Pace section' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-semester-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try {
            $env:SEMESTER_PLAN_OUT = $tmp
            $out = & python $builder 2>&1
            if ($LASTEXITCODE -ne 0) { throw "build.py exit $LASTEXITCODE  out=$out" }
            $html = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match 'capacity-head'        $html
            Assert-Match 'Capacity &amp; Pace'  $html
            Assert-Match 'cap-verdict'          $html
            Assert-Match '212\.75'              $html     # budget constant must appear in the ribbon
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $env:SEMESTER_PLAN_OUT = $null
        }
    }

    It 'v3: renders the "What changed since last refresh" panel' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-semester-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try {
            $env:SEMESTER_PLAN_OUT = $tmp
            $out = & python $builder 2>&1
            if ($LASTEXITCODE -ne 0) { throw "build.py exit $LASTEXITCODE  out=$out" }
            $html = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match 'changes-head'                       $html
            Assert-Match 'What changed since last refresh'    $html
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $env:SEMESTER_PLAN_OUT = $null
        }
    }

    It 'v3: reports capacity + diff line in stdout summary' {
        $out = (& python $builder 2>&1) -join "`n"
        Assert-Match 'capacity:\s*commit=\d+'                 $out
        Assert-Match 'budget=212\.75'                         $out
        Assert-Match 'diff vs'                                $out
        Assert-Match 'snapshot:\s*\d{4}-\d{2}-\d{2}\.json'    $out
    }

    It 'v3: renders the S-curve target vs actual SVG' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-semester-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".html")
        try {
            $env:SEMESTER_PLAN_OUT = $tmp
            $out = & python $builder 2>&1
            if ($LASTEXITCODE -ne 0) { throw "build.py exit $LASTEXITCODE  out=$out" }
            $html = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match 'class="pace-svg"'    $html
            Assert-Match '<polyline points='  $html
            Assert-Match 'Target curve'        $html
            Assert-Match 'Actual:\s*\d'        $html
            Assert-Match 'Target:\s*\d'        $html
        } finally {
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $env:SEMESTER_PLAN_OUT = $null
        }
    }
}

Exit-WithTestResults

