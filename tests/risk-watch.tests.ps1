# Tests for the risk-watch skill: RAG rendering, checkpoint badges, the
# RK-NNN add helper, the runner wiring, the seeded register, and the manifest /
# schedule entries.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot    = Split-Path $PSScriptRoot -Parent
$skillDir    = Join-Path $repoRoot '.copilot\skills\risk-watch'
$renderPs1   = Join-Path $skillDir 'render.ps1'
$addItemPy   = Join-Path $skillDir 'add-item.py'
$skillMd     = Join-Path $skillDir 'SKILL.md'
$runnerPs1   = Join-Path $repoRoot '.copilot\skills\run-risk-watch-pulse.ps1'
$registerMd  = Join-Path $repoRoot 'reports\risks\register.md'
$skillsJson  = Join-Path $repoRoot 'config\skills.json'
$schedJson   = Join-Path $repoRoot 'config\schedules.json'

foreach ($p in @($renderPs1, $addItemPy, $skillMd, $runnerPs1, $registerMd, $skillsJson, $schedJson)) {
    if (-not (Test-Path $p)) { throw "missing required file: $p" }
}

. $renderPs1

$runnerText   = Get-Content $runnerPs1  -Raw -Encoding UTF8
$registerText = Get-Content $registerMd -Raw -Encoding UTF8

function New-Risk {
    param($Id, $Risk, $Checkpoint = '-', $Owner = 'TBD', $Area = '', $Title = 'x', $Why = '', $Mitigation = '')
    [pscustomobject]@{
        Id = $Id; Risk = $Risk; NextCheckpoint = $Checkpoint; Owner = $Owner
        Area = $Area; Title = $Title; Why = $Why; Mitigation = $Mitigation
    }
}

Describe 'risk-watch source hygiene' {

    It 'render.ps1 is ASCII-only (PS 5.1 source constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($renderPs1)
        $bad = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad++ } }
        Assert-Equal 0 $bad "render.ps1 has $bad non-ASCII byte(s)"
    }

    It 'runner is ASCII-only (PS 5.1 source constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($runnerPs1)
        $bad = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad++ } }
        Assert-Equal 0 $bad "runner has $bad non-ASCII byte(s)"
    }
}

Describe 'risk-watch RAG normalization' {

    It 'maps red/r to red' {
        Assert-Equal 'red' (Get-RiskRag (New-Risk 'RK-001' 'Red'))
        Assert-Equal 'red' (Get-RiskRag (New-Risk 'RK-001' 'r'))
    }
    It 'maps amber/yellow/blank to amber' {
        Assert-Equal 'amber' (Get-RiskRag (New-Risk 'RK-001' 'Amber'))
        Assert-Equal 'amber' (Get-RiskRag (New-Risk 'RK-001' 'yellow'))
        Assert-Equal 'amber' (Get-RiskRag (New-Risk 'RK-001' ''))
    }
    It 'maps green/g to green' {
        Assert-Equal 'green' (Get-RiskRag (New-Risk 'RK-001' 'Green'))
        Assert-Equal 'green' (Get-RiskRag (New-Risk 'RK-001' 'g'))
    }
}

Describe 'risk-watch counts and subject tail' {

    $items = @(
        (New-Risk 'RK-001' 'Red'),
        (New-Risk 'RK-002' 'Amber'),
        (New-Risk 'RK-003' 'Amber'),
        (New-Risk 'RK-004' 'Green')
    )

    It 'counts by band' {
        $c = Get-RiskCounts -Items $items
        Assert-Equal 1 $c.Red
        Assert-Equal 2 $c.Amber
        Assert-Equal 1 $c.Green
        Assert-Equal 4 $c.Total
    }
    It 'subject tail lists red then amber' {
        Assert-Equal '1 red, 2 amber' (Format-RiskSubjectTail -Items $items)
    }
    It 'subject tail says all green when only green open' {
        Assert-Equal 'all green' (Format-RiskSubjectTail -Items @((New-Risk 'RK-001' 'Green')))
    }
    It 'subject tail says nothing tracked when empty' {
        Assert-Equal 'nothing tracked' (Format-RiskSubjectTail -Items @())
    }
}

Describe 'risk-watch checkpoint badges' {

    $today = [DateTime]'2026-06-15'

    It 'flags an overdue checkpoint with days late' {
        $info = Get-RiskCheckpointInfo -Item (New-Risk 'RK-001' 'Red' '2026-06-12') -Today $today
        Assert-Equal 'overdue' $info.Kind
        Assert-Equal -3 $info.DaysTo
        Assert-Match 'overdue 3 days' $info.Label
    }
    It 'flags a checkpoint within 7 days as due this week' {
        $info = Get-RiskCheckpointInfo -Item (New-Risk 'RK-001' 'Amber' '2026-06-20') -Today $today
        Assert-Equal 'soon' $info.Kind
        Assert-Equal 'due this week' $info.Label
    }
    It 'renders a far checkpoint as a scheduled date' {
        $info = Get-RiskCheckpointInfo -Item (New-Risk 'RK-001' 'Amber' '2026-07-30') -Today $today
        Assert-Equal 'scheduled' $info.Kind
        Assert-Match 'by 2026-07-30' $info.Label
    }
    It 'handles a missing checkpoint and sorts it last' {
        $info = Get-RiskCheckpointInfo -Item (New-Risk 'RK-001' 'Amber' '-') -Today $today
        Assert-Equal 'none' $info.Kind
        Assert-Equal ([int]::MaxValue) $info.DaysTo
    }
}

Describe 'risk-watch pulse rendering' {

    $today = [DateTime]'2026-06-15'
    $items = @(
        (New-Risk 'RK-001' 'Red'   '2026-06-12' 'Saeed' 'Geneva' 'Min instances'),
        (New-Risk 'RK-002' 'Amber' '2026-06-20' 'TBD'   'Geneva' 'SDK to .NET 10'),
        (New-Risk 'RK-003' 'Green' '-'          'TBD'   'Misc'   'Low concern')
    )
    $html = Render-RiskPulse -Items $items -Today $today

    It 'emits a Red table heading with the count' {
        Assert-Match 'Red \(1\)' $html
    }
    It 'emits an Amber table heading with the count' {
        Assert-Match 'Amber \(1\)' $html
    }
    It 'omits Green from tables but reports the count' {
        Assert-Match 'Green risk omitted' $html
        Assert-NotContains 'Low concern' $html
    }
    It 'surfaces the overdue badge for the red risk' {
        Assert-Match 'overdue 3 days' $html
    }
}

Describe 'risk-watch add-item.py' {

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("risk-watch-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpReg = Join-Path $tmpDir 'register.md'
    $seed = @(
        '# Risk Register', '',
        '## Open', '',
        '_(Empty placeholder.)_', '',
        '---', '',
        '## Closed', '',
        '_(Empty - none yet.)_', ''
    ) -join "`n"
    Set-Content -Path $tmpReg -Value $seed -Encoding UTF8 -NoNewline

    It 'assigns RK-001 to the first risk and strips the empty-state line' {
        $out = & python $addItemPy --register-file $tmpReg --title 'First risk' --rag red --area Geneva 2>&1
        Assert-Match '^RK-001\t' ($out -join "`n")
        $body = Get-Content $tmpReg -Raw -Encoding UTF8
        Assert-Match '### RK-001' $body
        Assert-Match '\*\*Risk:\*\* Red' $body
        Assert-NotContains 'Empty placeholder' $body
    }
    It 'increments to RK-002 on the next add' {
        $out = & python $addItemPy --register-file $tmpReg --title 'Second risk' --rag green 2>&1
        Assert-Match '^RK-002\t' ($out -join "`n")
    }
    It 'rejects an invalid RAG value' {
        & python $addItemPy --register-file $tmpReg --title 'Bad' --rag purple 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -ne 0) 'invalid rag should exit non-zero'
    }

    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Describe 'risk-watch runner wiring' {

    It 'dot-sources render.ps1' {
        Assert-Match "render\.ps1" $runnerText
    }
    It 'uses the subject-tail helper' {
        Assert-Match 'Format-RiskSubjectTail' $runnerText
    }
    It 'appends the Nirvana signature' {
        Assert-Match 'Get-NirvanaSignature' $runnerText
    }
    It 'has a joke pool' {
        Assert-Match '\$jokes\s*=' $runnerText
    }
    It 'guards with migration-mode and Ensure-Outlook' {
        Assert-Match 'Test-MigrationMode' $runnerText
        Assert-Match 'Ensure-OutlookRunning' $runnerText
    }
    It 'uses ISO-week idempotency via last-sent.txt' {
        Assert-Match 'last-sent\.txt' $runnerText
        Assert-Match 'Get-IsoWeekTag' $runnerText
    }
}

Describe 'risk-watch seeded register' {

    It 'has both Geneva risks open' {
        Assert-Match '### RK-001' $registerText
        Assert-Match '### RK-002' $registerText
    }
    It 'both seeded risks carry a Risk (RAG) and Status field' {
        Assert-Match '\*\*Status:\*\* Open' $registerText
        Assert-Match '\*\*Risk:\*\* Amber' $registerText
    }
    It 'has Open and Closed sections' {
        Assert-Match '(?m)^## Open' $registerText
        Assert-Match '(?m)^## Closed' $registerText
    }
}

Describe 'risk-watch manifest + schedule' {

    $manifest = Get-Content $skillsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $manifest.skills | Where-Object { $_.name -eq 'risk-watch' }
    $sched = Get-Content $schedJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $task = $sched.tasks | Where-Object { $_.suffix -eq 'RiskWatchPulse' }

    It 'registers risk-watch in skills.json' {
        Assert-True ($null -ne $entry) 'risk-watch entry exists'
        Assert-Equal '.copilot/skills/risk-watch' $entry.path
        Assert-Equal '.copilot/skills/run-risk-watch-pulse.ps1' $entry.entrypoint_path
        Assert-True $entry.show_in_agents 'show_in_agents true'
        Assert-True $entry.ship_in_snapshot 'ship_in_snapshot true'
    }
    It 'declares the DM-RiskWatchPulse weekly Monday task' {
        Assert-True ($null -ne $task) 'RiskWatchPulse task exists'
        Assert-True $task.manage 'managed'
        Assert-Equal 'weekly' $task.schedule.kind
        Assert-Equal '08:45' $task.schedule.time
        Assert-Equal 'Sunday' ($task.schedule.days -join ',')
    }
}

Exit-WithTestResults
