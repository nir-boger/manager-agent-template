# Runs the pbi-assign-tasks skill non-interactively.
# Can be triggered on demand, e.g. at sprint start.

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$reportsRoot = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) -Config $AgentConfig
New-Item -ItemType Directory -Force -Path (Join-Path $reportsRoot 'pbi-assign') | Out-Null
$logFile = Join-Path $LogDir ("pbi-assign-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

$prompt = "Read the skill definition at $AgentRoot\.copilot\skills\pbi-assign-tasks\SKILL.md and execute it exactly as described. Do not ask me any questions - proceed autonomously. When done, print a one-line summary."

& copilot -p $prompt --allow-all-tools --no-ask-user --model claude-sonnet-4.5 *>&1 | Tee-Object -FilePath $logFile