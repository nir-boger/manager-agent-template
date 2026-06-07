# One-shot script: re-announce sprint 2Wk24 on Thursday 2026-05-14.
#
# Background: on 2026-05-11 the daily DM-SprintCreate run posted the 2Wk24
# Teams announcement ~6 days early because the rolling-lookahead rewrite of
# sprint-create/SKILL.md (2026-05-10) dropped the timing guard. Nir asked
# for the announcement to be re-posted on Thursday 2026-05-14 (the workday
# before the 2Wk24 Sunday start).
#
# Mechanics:
#   1. Append a context entry to a side log.
#   2. Scrub any `| 2Wk24 | ... | teams=posted` line(s) from sprint-create.log
#      so the existing idempotency gate releases.
#   3. Invoke run-sprint-create.ps1 — it will see no `teams=posted` for 2Wk24,
#      post the imminent-rollover announcement, and append a fresh log line.
#   4. Self-delete the DM-SprintReannounce-2Wk24 scheduled task so this never
#      runs again.
#
# This is a SPRINT-SPECIFIC one-shot, not a permanent skill. The underlying
# spec bug (see sprint-create/SKILL.md line 110) still exists and will fire
# again for 2Wk25 unless the spec is fixed separately.

$ErrorActionPreference = 'Continue'

$AgentRoot   = '<repo>'
$LogDir      = Join-Path $AgentRoot 'reports\logs'
$SideLog     = Join-Path $LogDir   ('sprint-reannounce-2wk24-' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.log')
$SprintLog   = Join-Path $AgentRoot 'reports\sprint-create.log'
$RunnerPath  = Join-Path $AgentRoot '.copilot\skills\run-sprint-create.ps1'
$TaskName    = 'DM-SprintReannounce-2Wk24'

function Write-SideLog {
    param([string] $msg)
    $ts = (Get-Date).ToString('o')
    "[$ts] $msg" | Add-Content -Path $SideLog -Encoding UTF8
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
Write-SideLog "one-shot reannounce 2Wk24 starting"

try {
    if (Test-Path $SprintLog) {
        $original = Get-Content $SprintLog -Raw -Encoding UTF8
        $lines    = $original -split "`r?`n"
        $kept     = New-Object System.Collections.Generic.List[string]
        $removed  = 0
        foreach ($line in $lines) {
            if ($line -match '\|\s*2Wk24\s*\|' -and $line -match 'teams=posted') {
                Write-SideLog "scrubbing line: $line"
                $removed++
                continue
            }
            $kept.Add($line)
        }
        if ($removed -gt 0) {
            $newContent = ($kept -join "`r`n").TrimEnd("`r","`n") + "`r`n"
            Set-Content -Path $SprintLog -Value $newContent -Encoding UTF8 -NoNewline
            Write-SideLog "scrub complete — removed $removed line(s) for 2Wk24/teams=posted"
        } else {
            Write-SideLog "no matching teams=posted lines found for 2Wk24 — nothing to scrub"
        }
    } else {
        Write-SideLog "sprint-create.log not found at $SprintLog — proceeding to runner anyway"
    }
} catch {
    Write-SideLog "scrub failed: $($_.Exception.Message) — continuing to runner"
}

try {
    Write-SideLog "invoking $RunnerPath (in-process to keep window hidden)"
    # Run in the same hidden pwsh process — spawning a new powershell.exe could
    # pop a console window (see the NirvanaFindDraft_2036896101 incident).
    & $RunnerPath *>&1 | Tee-Object -FilePath $SideLog -Append
    Write-SideLog "runner returned (exit code unavailable for in-process call)"
} catch {
    Write-SideLog "runner invocation threw: $($_.Exception.Message)"
}

try {
    Write-SideLog "self-deleting scheduled task $TaskName"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-SideLog "task deleted"
} catch {
    Write-SideLog "self-delete failed: $($_.Exception.Message)"
}

Write-SideLog "one-shot reannounce 2Wk24 complete"

