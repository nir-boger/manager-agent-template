# Runs the sprint-create skill non-interactively.
# Called by the "DM-SprintCreate" Windows Scheduled Task daily.
# Maintains a rolling 2-month (60-day) lookahead window of pre-created sprints — see SKILL.md for details.

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$logFile = Join-Path $LogDir ("sprint-create-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

# Compute "today" in Asia/Jerusalem (IST/IDT) so the Thursday-before-start Teams gate
# (SKILL.md step 5) never depends on UTC or the agent's own clock.
try {
    $istTz = [TimeZoneInfo]::FindSystemTimeZoneById('Israel Standard Time')
    $todayLocal = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $istTz)
} catch {
    $todayLocal = Get-Date
}
$todayIso = $todayLocal.ToString('yyyy-MM-dd')
$todayDow = $todayLocal.DayOfWeek.ToString()
$isThursday = ($todayLocal.DayOfWeek -eq [DayOfWeek]::Thursday)

$dateContext = @"

DATE CONTEXT (authoritative — use this, not UTC or your own clock):
- TODAY (Asia/Jerusalem) = $todayIso ($todayDow)

TEAMS POST GATE (SKILL.md step 5, MANDATORY):
- The new-sprint Teams announcement may ONLY be posted on the Thursday immediately before the next sprint's Sunday startDate (announceDate = nextSprint.startDate - 3 days).
- Compare announceDate against TODAY above. If TODAY != announceDate, you MUST suppress the Teams post for that sprint and log 'teams=skipped:not-thursday-before'. This gate fires BEFORE the awaiting-admin and already-announced checks.
"@
if (-not $isThursday) {
    $dateContext += "- TODAY IS $todayDow, NOT A THURSDAY. The Thursday-before-start gate MUST suppress the Teams post for every sprint on this run.`n"
}

$prompt = "Read the skill definition at $AgentRoot\.copilot\skills\sprint-create\SKILL.md and execute it exactly as described. Do not ask me any questions - proceed autonomously with the fixed context in that file. When done, print a one-line summary.$dateContext"

Invoke-CopilotAgent -Prompt $prompt -LogFile $logFile | Out-Null