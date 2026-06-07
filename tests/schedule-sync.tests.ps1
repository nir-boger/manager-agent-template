# Tests for the declarative scheduled-task layer (P2 refactor):
#   - config/schedules.json schema/integrity (portable: no live scheduler access)
#   - tools/schedule-sync-helpers.ps1 pure reconciliation logic
#
# These tests never call Get-ScheduledTask / Register-ScheduledTask; the live
# scheduler is machine-specific and out of scope for portable CI.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$root        = Resolve-Path (Join-Path $PSScriptRoot '..')
$manifestPath = Join-Path $root 'config\schedules.json'
$helpersPath  = Join-Path $root 'tools\schedule-sync-helpers.ps1'
. $helpersPath
$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

$validKinds = @('daily', 'daily-interval', 'weekly', 'weekly-interval', 'interval', 'once')

Describe 'schedules.json - schema integrity' {

    It 'parses as JSON and has a tasks array' {
        Assert-True ($null -ne $manifest.tasks)
        Assert-True (@($manifest.tasks).Count -gt 0)
    }

    It 'declares a launcher exec + wrapper' {
        Assert-Equal 'wscript.exe' $manifest.launcher.exec
        Assert-Match 'run-hidden\.vbs$' $manifest.launcher.wrapper
    }

    It 'every task has a non-empty suffix' {
        foreach ($t in $manifest.tasks) { Assert-True (-not [string]::IsNullOrWhiteSpace($t.suffix)) }
    }

    It 'task suffixes are unique' {
        $suffixes = @($manifest.tasks | ForEach-Object { $_.suffix })
        $uniq = $suffixes | Select-Object -Unique
        Assert-Equal $suffixes.Count $uniq.Count
    }

    It 'every task schedule.kind is recognized' {
        foreach ($t in $manifest.tasks) { Assert-Contains $t.schedule.kind ($validKinds -join ' ') }
    }

    It 'interval-style kinds carry every + duration' {
        foreach ($t in $manifest.tasks) {
            if ($t.schedule.kind -in @('interval', 'daily-interval', 'weekly-interval')) {
                Assert-Match '^P' ([string]$t.schedule.duration)
                Assert-Match '^PT?' ([string]$t.schedule.every)
            }
        }
    }

    It 'weekly-style kinds carry days' {
        foreach ($t in $manifest.tasks) {
            if ($t.schedule.kind -in @('weekly', 'weekly-interval')) {
                Assert-True (@($t.schedule.days).Count -ge 1)
            }
        }
    }

    It 'durations + intervals are valid ISO-8601 timespans' {
        foreach ($t in $manifest.tasks) {
            if ($t.schedule.PSObject.Properties['every']) {
                $null = [System.Xml.XmlConvert]::ToTimeSpan([string]$t.schedule.every)
            }
            if ($t.schedule.PSObject.Properties['duration']) {
                $null = [System.Xml.XmlConvert]::ToTimeSpan([string]$t.schedule.duration)
            }
        }
        Assert-True $true
    }

    It 'every managed task runner script exists on disk' {
        foreach ($t in $manifest.tasks) {
            if ($t.manage -eq $true) {
                $runnerAbs = Join-Path $root ($t.runner -replace '/', '\')
                Assert-True (Test-Path $runnerAbs) "missing runner for $($t.suffix): $runnerAbs"
            }
        }
    }

    It 'pilates + one-shot entries are marked manage:false' {
        $pilates = @($manifest.tasks | Where-Object { $_.suffix -like 'PilatesAuto*' })
        foreach ($p in $pilates) { Assert-False ([bool]$p.manage) }
        $lea = @($manifest.tasks | Where-Object { $_.suffix -eq 'LeaWelcome' })
        if ($lea.Count -gt 0) { Assert-False ([bool]$lea[0].manage) }
    }
}

Describe 'schedule-sync-helpers - Get-ScheduleTaskName' {
    It 'joins prefix and suffix with a hyphen' {
        Assert-Equal 'DM-InboxWatch' (Get-ScheduleTaskName -Prefix 'DM' -Suffix 'InboxWatch')
    }
}

Describe 'schedule-sync-helpers - Get-RunnerLeaf' {
    It 'extracts the bare filename from a relative path' {
        Assert-Equal 'run-inbox-watch.ps1' (Get-RunnerLeaf -RunnerPath '.copilot/skills/run-inbox-watch.ps1')
    }
    It 'returns empty for blank input' {
        Assert-Equal '' (Get-RunnerLeaf -RunnerPath '')
    }
}

Describe 'schedule-sync-helpers - Get-ManagedScheduleEntries' {
    It 'excludes manage:false entries' {
        $managed = Get-ManagedScheduleEntries -Manifest $manifest
        $names = @($managed | ForEach-Object { $_.suffix }) -join ' '
        Assert-NotContains 'PilatesAuto-mon-10' $names
        Assert-NotContains 'LeaWelcome' $names
    }
    It 'includes a known managed entry' {
        $managed = Get-ManagedScheduleEntries -Manifest $manifest
        $names = @($managed | ForEach-Object { $_.suffix }) -join ' '
        Assert-Contains 'InboxWatch' $names
    }
}

Describe 'schedule-sync-helpers - Compare-ScheduleState' {

    # Build a synthetic mini-manifest so the reconciliation logic is tested in isolation.
    $mini = [pscustomobject]@{
        tasks = @(
            [pscustomobject]@{ suffix = 'Alpha'; runner = '.copilot/skills/run-alpha.ps1'; enabled = $true;  manage = $true },
            [pscustomobject]@{ suffix = 'Beta';  runner = '.copilot/skills/run-beta.ps1';  enabled = $false; manage = $true },
            [pscustomobject]@{ suffix = 'Pil';   runner = 'pilates/pilates.ps1';           enabled = $true;  manage = $false }
        )
    }

    It 'reports InSync when live matches manifest' {
        $live = @(
            [pscustomobject]@{ Name = 'DM-Alpha'; Enabled = $true;  RunnerLeaf = 'run-alpha.ps1' },
            [pscustomobject]@{ Name = 'DM-Beta';  Enabled = $false; RunnerLeaf = 'run-beta.ps1' }
        )
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $alpha = $r | Where-Object { $_.Name -eq 'DM-Alpha' }
        Assert-Equal 'InSync' $alpha.State
    }

    It 'reports Missing when a managed task is absent' {
        $live = @([pscustomobject]@{ Name = 'DM-Beta'; Enabled = $false; RunnerLeaf = 'run-beta.ps1' })
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $alpha = $r | Where-Object { $_.Name -eq 'DM-Alpha' }
        Assert-Equal 'Missing' $alpha.State
    }

    It 'reports EnabledDrift when live enabled-state differs' {
        $live = @(
            [pscustomobject]@{ Name = 'DM-Alpha'; Enabled = $true;  RunnerLeaf = 'run-alpha.ps1' },
            [pscustomobject]@{ Name = 'DM-Beta';  Enabled = $true;  RunnerLeaf = 'run-beta.ps1' }
        )
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $beta = $r | Where-Object { $_.Name -eq 'DM-Beta' }
        Assert-Equal 'EnabledDrift' $beta.State
    }

    It 'reports RunnerDrift when the runner script name differs' {
        $live = @(
            [pscustomobject]@{ Name = 'DM-Alpha'; Enabled = $true;  RunnerLeaf = 'run-WRONG.ps1' },
            [pscustomobject]@{ Name = 'DM-Beta';  Enabled = $false; RunnerLeaf = 'run-beta.ps1' }
        )
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $alpha = $r | Where-Object { $_.Name -eq 'DM-Alpha' }
        Assert-Equal 'RunnerDrift' $alpha.State
    }

    It 'does not flag manage:false tasks as Extra' {
        $live = @(
            [pscustomobject]@{ Name = 'DM-Alpha'; Enabled = $true;  RunnerLeaf = 'run-alpha.ps1' },
            [pscustomobject]@{ Name = 'DM-Beta';  Enabled = $false; RunnerLeaf = 'run-beta.ps1' },
            [pscustomobject]@{ Name = 'DM-Pil';   Enabled = $true;  RunnerLeaf = 'pilates.ps1' }
        )
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $pil = $r | Where-Object { $_.Name -eq 'DM-Pil' }
        Assert-True ($null -eq $pil)
    }

    It 'flags genuinely unknown DM-* tasks as ExtraUnmanaged' {
        $live = @(
            [pscustomobject]@{ Name = 'DM-Alpha';   Enabled = $true;  RunnerLeaf = 'run-alpha.ps1' },
            [pscustomobject]@{ Name = 'DM-Beta';    Enabled = $false; RunnerLeaf = 'run-beta.ps1' },
            [pscustomobject]@{ Name = 'DM-Ghost';   Enabled = $true;  RunnerLeaf = 'run-ghost.ps1' }
        )
        $r = Compare-ScheduleState -Manifest $mini -Prefix 'DM' -LiveTasks $live
        $ghost = $r | Where-Object { $_.Name -eq 'DM-Ghost' }
        Assert-Equal 'ExtraUnmanaged' $ghost.State
    }
}

Describe 'schedule-sync-helpers - Resolve-TaskExecutionLimit' {
    $miniManifest = [pscustomobject]@{ defaults = [pscustomobject]@{ execution_time_limit = 'PT10M' } }

    It 'falls back to the global default when no per-task override is present' {
        $entry = [pscustomobject]@{ suffix = 'Alpha' }
        Assert-Equal 'PT10M' (Resolve-TaskExecutionLimit -Entry $entry -Manifest $miniManifest)
    }
    It 'prefers a per-task execution_time_limit override' {
        $entry = [pscustomobject]@{ suffix = 'Beta'; execution_time_limit = 'PT45M' }
        Assert-Equal 'PT45M' (Resolve-TaskExecutionLimit -Entry $entry -Manifest $miniManifest)
    }
    It 'ignores a blank per-task override and falls back to default' {
        $entry = [pscustomobject]@{ suffix = 'Gamma'; execution_time_limit = '' }
        Assert-Equal 'PT10M' (Resolve-TaskExecutionLimit -Entry $entry -Manifest $miniManifest)
    }
    It 'returns a valid ISO-8601 timespan for the real DailyCapture entry, if present' {
        $dc = @($manifest.tasks | Where-Object { $_.suffix -eq 'DailyCapture' })
        if ($dc.Count -gt 0) {
            $etl = Resolve-TaskExecutionLimit -Entry $dc[0] -Manifest $manifest
            $null = [System.Xml.XmlConvert]::ToTimeSpan($etl)
            Assert-Match '^PT' $etl
        } else {
            Assert-True $true
        }
    }
}

Exit-WithTestResults
