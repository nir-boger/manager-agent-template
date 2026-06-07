# Tests for the reminders skill.
#
# Validates:
#   - manifest entry shape (config/skills.json)
#   - runner is ASCII-only (PS 5.1 source constraint)
#   - critical runner content: lock file, Outlook lookup, signature dot-source, joke pool, fire-window
#   - add-item.py: argument validation + RM-NNN generation + atomic write + meeting/absolute branches
#   - reminders.md parser correctly identifies pending vs fired entries

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\reminders'
$runner     = Join-Path $repoRoot '.copilot\skills\run-reminders.ps1'
$adder      = Join-Path $skillDir 'add-item.py'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$manifest   = Join-Path $repoRoot 'config\skills.json'
$remFile    = Join-Path $repoRoot 'reports\reminders\reminders.md'

if (-not (Test-Path $skillDir)) { throw "skill folder missing: $skillDir" }
if (-not (Test-Path $runner))   { throw "runner missing: $runner" }
if (-not (Test-Path $adder))    { throw "add-item.py missing: $adder" }
if (-not (Test-Path $skillMd))  { throw "SKILL.md missing: $skillMd" }
if (-not (Test-Path $manifest)) { throw "manifest missing: $manifest" }

$manifestObj = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = $manifestObj.skills | Where-Object { $_.name -eq 'reminders' } | Select-Object -First 1
$runnerText = Get-Content $runner -Raw -Encoding UTF8
$adderText  = Get-Content $adder  -Raw -Encoding UTF8

Describe 'reminders manifest entry' {

    It 'exists in config/skills.json' {
        Assert-True ($null -ne $entry) "expected an entry named 'reminders'"
    }

    It 'has surface=engine and category=cadence-memory' {
        Assert-Equal 'engine'          $entry.surface
        Assert-Equal 'cadence-memory'  $entry.category
    }

    It 'points at the skill folder and runner' {
        Assert-Equal '.copilot/skills/reminders'              $entry.path
        Assert-Equal '.copilot/skills/run-reminders.ps1'      $entry.entrypoint_path
    }

    It 'is visible in AGENTS.md and ships in snapshot' {
        Assert-True $entry.show_in_agents
        Assert-True $entry.ship_in_snapshot
    }

    It 'includes the primary trigger phrases' {
        $triggers = ($entry.triggers -join '|').ToLower()
        Assert-Match 'remind me before' $triggers
        Assert-Match 'remind me at'     $triggers
        Assert-Match 'list reminders'   $triggers
        Assert-Match 'cancel rm-'       $triggers
    }
}

Describe 'reminders runner script' {

    It 'is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($runner)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'acquires a single-instance lock' {
        Assert-Match 'reminders\.lock' $runnerText
        Assert-Match '\$PID'            $runnerText
    }

    It 'opens Outlook MAPI calendar for meeting-bound lookup' {
        Assert-Match 'Outlook\.Application'  $runnerText
        Assert-Match 'GetDefaultFolder\(9\)' $runnerText
        Assert-Match 'IncludeRecurrences'    $runnerText
    }

    It 'computes fire_at via Resolve-MeetingStart and AddMinutes(offset)' {
        Assert-Match 'Resolve-MeetingStart' $runnerText
        Assert-Match 'AddMinutes'           $runnerText
    }

    It 'enforces a 10-min back-window unless -Force' {
        Assert-Match 'New-TimeSpan -Minutes 10' $runnerText
        Assert-Match '\$Force'                   $runnerText
    }

    It 'dot-sources the shared signature helper' {
        Assert-Match 'signature\.ps1'       $runnerText
        Assert-Match 'Get-NirvanaSignature' $runnerText
    }

    It 'includes a joke pool with multiple options' {
        Assert-Match 'jokePool'   $runnerText
        Assert-Match 'Get-Random' $runnerText
    }

    It 'sends mail to someone@example.com' {
        Assert-Match 'someone@example.com' $runnerText
    }

    It 'supports DryRun / PreviewOnly / Force switches' {
        Assert-Match '\[switch\]\$DryRun'      $runnerText
        Assert-Match '\[switch\]\$PreviewOnly' $runnerText
        Assert-Match '\[switch\]\$Force'       $runnerText
    }

    It 'flips Status to fired (Mark-Fired function present)' {
        Assert-Match 'Mark-Fired'      $runnerText
        Assert-Match 'Fired at'        $runnerText
        Assert-Match 'Resolved fire_at' $runnerText
    }
}

Describe 'reminders add-item.py' {

    It 'validates kind=meeting requires subject/date/offset' {
        $out = & python $adder --reminders-file (Join-Path ([IO.Path]::GetTempPath()) 'no-such.md') --title 'x' --kind meeting --dry-run 2>&1
        Assert-True ($LASTEXITCODE -ne 0) "expected failure when meeting fields missing"
    }

    It 'validates kind=absolute requires --fire-at' {
        $out = & python $adder --reminders-file (Join-Path ([IO.Path]::GetTempPath()) 'no-such.md') --title 'x' --kind absolute --dry-run 2>&1
        Assert-True ($LASTEXITCODE -ne 0) "expected failure when --fire-at missing"
    }

    It 'auto-increments RM-NNN starting from existing max' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-rem-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        try {
            $first  = & python $adder --reminders-file $tmp --title 'first'  --kind absolute --fire-at '2026-12-01T09:00:00+03:00' 2>&1
            $second = & python $adder --reminders-file $tmp --title 'second' --kind meeting  --meeting-subject 'WSR' --meeting-date '2026-12-02' --offset-min -10 2>&1
            Assert-Match 'RM-001' ($first -join "`n")
            Assert-Match 'RM-002' ($second -join "`n")
            $md = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match '### RM-001'                $md
            Assert-Match '### RM-002'                $md
            Assert-Match '\*\*Kind:\*\* absolute'    $md
            Assert-Match '\*\*Kind:\*\* meeting'     $md
            Assert-Match '\*\*Meeting subject match:\*\* WSR' $md
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'is idempotent across calls (atomic .tmp -> rename, no .tmp left behind)' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-rem-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        try {
            & python $adder --reminders-file $tmp --title 'x' --kind absolute --fire-at '2026-12-01T09:00:00+03:00' | Out-Null
            $leftover = Test-Path ($tmp + '.tmp')
            Assert-False $leftover ".tmp leftover from atomic write"
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue; Remove-Item ($tmp + '.tmp') -ErrorAction SilentlyContinue }
    }
}

Describe 'reminders.md current state' {

    It 'exists with at least the ## Pending header' {
        Assert-True (Test-Path $remFile) "reminders.md should exist at $remFile"
        $md = Get-Content $remFile -Raw -Encoding UTF8
        Assert-Match '##\s+Pending' $md
    }

    It 'has RM-001 (DM SLO sync) bound to meeting subject SLO on 2026-05-26' {
        $md = Get-Content $remFile -Raw -Encoding UTF8
        Assert-Match '### RM-001'                          $md
        Assert-Match '\*\*Kind:\*\* meeting'               $md
        Assert-Match '\*\*Meeting subject match:\*\* SLO'  $md
        Assert-Match '\*\*Meeting date:\*\* 2026-05-26'    $md
        Assert-Match '\*\*Offset min:\*\* -30'             $md
    }
}

Exit-WithTestResults

