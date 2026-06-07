# Tests for the sprint-digest skill: working-day + pace math (pure helpers),
# state classification, HTML renderers, runner wiring, and manifest / schedule.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\sprint-digest'
$renderPs1  = Join-Path $skillDir 'render.ps1'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$runnerPs1  = Join-Path $repoRoot '.copilot\skills\run-sprint-digest.ps1'
$skillsJson = Join-Path $repoRoot 'config\skills.json'
$schedJson  = Join-Path $repoRoot 'config\schedules.json'

foreach ($p in @($renderPs1, $skillMd, $runnerPs1, $skillsJson, $schedJson)) {
    if (-not (Test-Path $p)) { throw "missing required file: $p" }
}

. $renderPs1

$runnerText = Get-Content $runnerPs1 -Raw -Encoding UTF8

function New-Unit {
    param($Id, $Type, $State, $AssignedTo = '')
    [pscustomobject]@{
        Id = $Id; Type = $Type; State = $State; AssignedTo = $AssignedTo
        Title = "item $Id"; Class = (Get-WorkItemStateClass -State $State)
    }
}

Describe 'sprint-digest source hygiene' {

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

Describe 'sprint-digest working-day math (Sun-Thu week)' {

    It 'Test-IsWorkingDay: Sun-Thu true, Fri/Sat false' {
        Assert-True  (Test-IsWorkingDay ([datetime]'2026-05-31')) 'Sunday is a working day'   # Sun
        Assert-True  (Test-IsWorkingDay ([datetime]'2026-06-04')) 'Thursday is a working day'  # Thu
        Assert-Equal $false (Test-IsWorkingDay ([datetime]'2026-06-05'))                       # Fri
        Assert-Equal $false (Test-IsWorkingDay ([datetime]'2026-06-06'))                       # Sat
    }
    It 'counts working days inclusive across a two-week sprint' {
        # 2026-05-31 (Sun) .. 2026-06-13 (Sat) -> two Sun-Thu weeks = 10
        Assert-Equal 10 (Get-WorkingDaysInRange -Start ([datetime]'2026-05-31') -End ([datetime]'2026-06-13'))
    }
    It 'returns 0 when End is before Start' {
        Assert-Equal 0 (Get-WorkingDaysInRange -Start ([datetime]'2026-06-13') -End ([datetime]'2026-05-31'))
    }
    It 'elapsed counts through yesterday only (today not yet worked)' {
        # As of Fri 2026-06-05, yesterday=Thu 06-04: Sun..Thu of week 1 = 5
        Assert-Equal 5 (Get-ElapsedWorkingDays -Start ([datetime]'2026-05-31') -Today ([datetime]'2026-06-05'))
    }
    It 'elapsed is 0 on the sprint start day' {
        Assert-Equal 0 (Get-ElapsedWorkingDays -Start ([datetime]'2026-05-31') -Today ([datetime]'2026-05-31'))
    }
    It 'elapsed is 0 before the sprint starts' {
        Assert-Equal 0 (Get-ElapsedWorkingDays -Start ([datetime]'2026-05-31') -Today ([datetime]'2026-05-20'))
    }
}

Describe 'sprint-digest Get-Fraction' {

    It 'returns 0 for a zero or negative denominator' {
        Assert-Equal 0.0 (Get-Fraction -Numerator 5 -Denominator 0)
        Assert-Equal 0.0 (Get-Fraction -Numerator 5 -Denominator -3)
    }
    It 'computes a normal fraction' {
        Assert-Equal 0.5 (Get-Fraction -Numerator 5 -Denominator 10)
    }
    It 'clamps above 1 and below 0' {
        Assert-Equal 1.0 (Get-Fraction -Numerator 12 -Denominator 10)
        Assert-Equal 0.0 (Get-Fraction -Numerator -2 -Denominator 10)
    }
}

Describe 'sprint-digest state classification' {

    It 'classifies done-family states' {
        foreach ($s in @('Done','Closed','Resolved','Completed')) {
            Assert-Equal 'done' (Get-WorkItemStateClass $s) "state '$s'"
        }
    }
    It 'classifies removed/cut as removed' {
        Assert-Equal 'removed' (Get-WorkItemStateClass 'Removed')
        Assert-Equal 'removed' (Get-WorkItemStateClass 'Cut')
    }
    It 'classifies not-started states (incl. To Do / ToDo / New)' {
        Assert-Equal 'notstarted' (Get-WorkItemStateClass 'To Do')
        Assert-Equal 'notstarted' (Get-WorkItemStateClass 'ToDo')
        Assert-Equal 'notstarted' (Get-WorkItemStateClass 'New')
        Assert-Equal 'notstarted' (Get-WorkItemStateClass 'Proposed')
    }
    It 'classifies active-family + unknown + blank as inprogress' {
        Assert-Equal 'inprogress' (Get-WorkItemStateClass 'In Progress')
        Assert-Equal 'inprogress' (Get-WorkItemStateClass 'In Review')
        Assert-Equal 'inprogress' (Get-WorkItemStateClass 'Committed')
        Assert-Equal 'inprogress' (Get-WorkItemStateClass 'Active')
        Assert-Equal 'inprogress' (Get-WorkItemStateClass 'SomethingNew')
        Assert-Equal 'inprogress' (Get-WorkItemStateClass '')
    }
    It 'is case-insensitive' {
        Assert-Equal 'done'       (Get-WorkItemStateClass 'done')
        Assert-Equal 'notstarted' (Get-WorkItemStateClass 'TO DO')
    }
}

Describe 'sprint-digest pace verdict' {

    It 'on track when work keeps up with time (gap <= 5%)' {
        Assert-Equal 'On track' (Get-PaceVerdict -CompletionFraction 0.50 -ElapsedFraction 0.50).Verdict
        Assert-Equal 'On track' (Get-PaceVerdict -CompletionFraction 0.46 -ElapsedFraction 0.50).Verdict
    }
    It 'ahead when well past the line' {
        Assert-Equal 'Ahead of schedule' (Get-PaceVerdict -CompletionFraction 0.70 -ElapsedFraction 0.50).Verdict
    }
    It 'behind for a moderate gap' {
        Assert-Equal 'Behind' (Get-PaceVerdict -CompletionFraction 0.35 -ElapsedFraction 0.50).Verdict
    }
    It 'well behind for a large gap (the live Geneva-sprint case)' {
        Assert-Equal 'Well behind' (Get-PaceVerdict -CompletionFraction 0.12 -ElapsedFraction 0.50).Verdict
    }
    It 'carries a color matching the verdict severity' {
        Assert-Equal '#0f7a3c' (Get-PaceVerdict -CompletionFraction 0.50 -ElapsedFraction 0.50).Color
        Assert-Equal '#b42318' (Get-PaceVerdict -CompletionFraction 0.10 -ElapsedFraction 0.50).Color
    }
}

Describe 'sprint-digest assignee + renderers' {

    It 'Get-AssigneeName falls back to Unassigned' {
        Assert-Equal 'Unassigned' (Get-AssigneeName (New-Unit 9 'Task' 'To Do' ''))
        Assert-Equal 'Teammate2' (Get-AssigneeName (New-Unit 9 'Task' 'To Do' 'Teammate2'))
    }
    It 'Render-ItemTable shows None for an empty set' {
        Assert-Match 'Not started \(0\)' (Render-ItemTable -Heading 'Not started' -Items @())
        Assert-Match 'None\.'             (Render-ItemTable -Heading 'Not started' -Items @())
    }
    It 'Render-ItemTable lists rows and caps overflow' {
        $items = 1..25 | ForEach-Object { New-Unit $_ 'Task' 'To Do' 'X' }
        $html = Render-ItemTable -Heading 'Not started' -Items $items -Cap 20
        Assert-Match 'Not started \(25\)' $html
        Assert-Match 'and 5 more' $html
    }
    It 'Render-PaceRibbon renders the verdict and baseline line' {
        $pace = [pscustomobject]@{
            ElapsedFraction=0.5; CompletionFraction=0.12; BaselineFraction=0.15
            ElapsedDays=5; TotalDays=10; Done=5; Total=43; BaselineDone=6; BaselineTotal=40
            AddedSinceStart=3; WorkingDaysLeft=5; Verdict='Well behind'; Color='#b42318'
        }
        $html = Render-PaceRibbon -Pace $pace
        Assert-Match 'Well behind' $html
        Assert-Match '5 working days left' $html
        Assert-Match 'baseline scope' ($html.ToLower())
        Assert-Match '3 added since sprint start' $html
    }
    It 'Render-DeltaPanel announces the first digest when no prior snapshot' {
        $d = [pscustomobject]@{ Completed=@(); Added=@(); Removed=@(); Reopened=@() }
        Assert-Match 'First digest for this sprint' (Render-DeltaPanel -Delta $d -HasPrev $false)
    }
    It 'Render-DeltaPanel lists changes when a prior snapshot exists' {
        $d = [pscustomobject]@{ Completed=@('#1 a'); Added=@('#2 b'); Removed=@(); Reopened=@('#3 c') }
        $html = Render-DeltaPanel -Delta $d -HasPrev $true
        Assert-Match 'Completed \(1\)' $html
        Assert-Match 'Reopened \(1\)' $html
    }
    It 'Render-ByPersonTable handles empty + populated' {
        Assert-Match 'No assigned' (Render-ByPersonTable -Rows @())
        $rows = @([pscustomobject]@{ Person='Lea'; NotStarted=2; InProgress=1; Done=3; Total=6 })
        Assert-Match 'Lea' (Render-ByPersonTable -Rows $rows)
    }
}

Describe 'sprint-digest runner wiring' {

    It 'dot-sources render.ps1 and the shared signature' {
        Assert-Match "skills\\sprint-digest'" $runnerText
        Assert-Match "Join-Path \`$skillDir 'render\.ps1'" $runnerText
        Assert-Match 'Get-NirvanaSignature' $runnerText
    }
    It 'acquires an ADO token via az and hits the iteration + batch endpoints' {
        Assert-Match 'az account get-access-token' $runnerText
        Assert-Match 'teamsettings/iterations' $runnerText
        Assert-Match 'workitemsbatch' $runnerText
    }
    It 'scopes pace to Task + Bug and excludes removed' {
        Assert-Match "Type -in @\('Task','Bug'\)" $runnerText
        Assert-Match "Class -ne 'removed'" $runnerText
    }
    It 'uses the iterationId|sunday-week-start idempotency key' {
        Assert-Match '\$idemKey\s*=\s*"\$iterId\|\$sundayStartIso"' $runnerText
        Assert-Match 'last-sent\.txt' $runnerText
    }
    It 'persists a per-iteration baseline and a last snapshot' {
        Assert-Match 'baseline-\$iterId\.json' $runnerText
        Assert-Match 'last-snapshot\.json' $runnerText
    }
    It 'only stamps state after a successful send' {
        Assert-Match 'Stamped idempotency key' $runnerText
        Assert-Match 'Add-Content -Path \$sentFile' $runnerText
    }
    It 'guards with migration-mode and Ensure-Outlook' {
        Assert-Match 'Test-MigrationMode' $runnerText
        Assert-Match 'Ensure-OutlookRunning' $runnerText
    }
    It 'has a joke pool' {
        Assert-Match '\$jokes\s*=' $runnerText
    }
    It 'degrades gracefully on no-sprint / zero-items without stamping' {
        Assert-Match 'No current iteration' $runnerText
        Assert-Match 'zero work items' $runnerText
    }
}

Describe 'sprint-digest manifest + schedule' {

    $manifest = Get-Content $skillsJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = $manifest.skills | Where-Object { $_.name -eq 'sprint-digest' }
    $sched = Get-Content $schedJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $task = $sched.tasks | Where-Object { $_.suffix -eq 'SprintDigest' }

    It 'registers sprint-digest in skills.json' {
        Assert-True ($null -ne $entry) 'sprint-digest entry exists'
        Assert-Equal '.copilot/skills/sprint-digest' $entry.path
        Assert-Equal '.copilot/skills/run-sprint-digest.ps1' $entry.entrypoint_path
        Assert-Equal 'sprint-pbis' $entry.category
        Assert-True $entry.show_in_agents 'show_in_agents true'
        Assert-True $entry.ship_in_snapshot 'ship_in_snapshot true'
        Assert-True ($entry.summary.Length -gt 0) 'summary non-empty'
    }
    It 'declares the DM-SprintDigest weekly Sunday task with a PT20M limit' {
        Assert-True ($null -ne $task) 'SprintDigest task exists'
        Assert-True $task.manage 'managed'
        Assert-Equal 'weekly' $task.schedule.kind
        Assert-Equal '09:00' $task.schedule.time
        Assert-Equal 'Sunday' ($task.schedule.days -join ',')
        Assert-Equal 'PT20M' $task.execution_time_limit
    }
}

Exit-WithTestResults

