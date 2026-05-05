# Runs the sprint-create skill non-interactively.
# Called by the "DM-SprintCreate" Windows Scheduled Task every Thursday.

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$logFile = Join-Path $LogDir ("sprint-create-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

$prompt = "Read the skill definition at $AgentRoot\.copilot\skills\sprint-create\SKILL.md and execute it exactly as described. Do not ask me any questions - proceed autonomously with the fixed context in that file. When done, print a one-line summary."

& copilot -p $prompt --allow-all-tools --no-ask-user --model claude-sonnet-4.5 *>&1 | Tee-Object -FilePath $logFile