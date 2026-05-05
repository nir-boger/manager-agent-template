# Runs the sprint-report-daily skill non-interactively.
# Called by the "DM-SprintDailyReport" Windows Scheduled Task Sun-Thu.
# Repeats every 10 min so a closed laptop doesn't cause a missed day; the
# guard below makes repeated runs cheap (skip when today's report file exists).

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$reportsRoot = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) -Config $AgentConfig
$logFile = Join-Path $LogDir ("daily-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

# --- Per-day idempotency guard --------------------------------------------
# The skill writes <reports_root>/daily/YYYY-MM-DD.md as its canonical output
# (per sprint-report-daily/SKILL.md). Use it as the natural "already ran today"
# marker. This makes the 10-min retry repetition safe.
$todayReport = Join-Path $reportsRoot ("daily\$(Get-Date -Format 'yyyy-MM-dd').md")
if (Test-Path $todayReport) {
    $msg = "$(Get-Date -Format o) Skipping: today's report already exists at $todayReport"
    Add-Content -Path $logFile -Value $msg -Encoding UTF8
    Write-Host $msg
    return
}

$prompt = "Read the skill definition at $AgentRoot\.copilot\skills\sprint-report-daily\SKILL.md and execute it exactly as described. Do not ask me any questions. Write the report and print a one-line summary."

& copilot -p $prompt --allow-all-tools --no-ask-user --model claude-sonnet-4.5 *>&1 | Tee-Object -FilePath $logFile