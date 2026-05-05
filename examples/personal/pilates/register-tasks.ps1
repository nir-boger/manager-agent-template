<#
.SYNOPSIS
  (Re)create the per-slot Windows scheduled tasks that auto-book Pilates.

.DESCRIPTION
  Creates one task per row in targets.json. Each task fires
  `registration_lead_hours` before the class start time, minus a small
  buffer (default 10s). When the task fires:
    pilates.ps1 register-target --target-id <id> --confirm BOOK --wait --max-seconds 90

  Tasks run as the current interactive user (not SYSTEM) because the email
  helper uses Outlook COM, which needs an interactive session.

.NOTES
  Idempotent - re-running unregisters and re-creates each task.
  Tasks are named <prefix>-PilatesAuto-<TARGET_ID> (e.g. DM-PilatesAuto-mon-10),
  where <prefix> comes from config/agent.json -> tasks.prefix (default 'DM').
#>
[CmdletBinding()]
param(
  [int] $PreFireSeconds = 10,
  [switch] $Remove,
  [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSCommandPath
$wrapper = Join-Path $here "pilates.ps1"
$targetsPath = Join-Path $here "targets.json"

# Self-bootstrap config (lives under examples/personal/pilates/, can't use runner-prelude)
$repoRoot  = (Resolve-Path (Join-Path $here "..\..\..")).Path
$configPs1 = Join-Path $repoRoot ".copilot\skills\_shared\config.ps1"
$taskPrefix = 'DM'
if (Test-Path $configPs1) {
  . $configPs1
  $taskPrefix = Get-AgentField -Path 'tasks.prefix' -Default 'DM'
}

if (-not (Test-Path $wrapper))     { throw "missing $wrapper" }
if (-not (Test-Path $targetsPath)) { throw "missing $targetsPath" }

$config = Get-Content $targetsPath -Raw | ConvertFrom-Json
$targets = if ($config.targets) { $config.targets } else { $config }

# Map target.day_of_week (0=Sun..6=Sat) -> Windows DaysOfWeek string
$dowMap = @{
  0 = "Sunday";    1 = "Monday";    2 = "Tuesday";  3 = "Wednesday"
  4 = "Thursday";  5 = "Friday";    6 = "Saturday"
}

foreach ($t in $targets) {
  $taskName = "$taskPrefix-PilatesAuto-$($t.id)"

  # Always remove the old version first (idempotent re-create)
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task: $taskName" -ForegroundColor DarkGray
    if (-not $WhatIf) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
  }

  if ($Remove) { continue }
  if (-not $t.enabled) {
    Write-Host "Skipping disabled target: $($t.id)" -ForegroundColor DarkYellow
    continue
  }

  # Compute fire time for this target.
  #   registration_open = class_dt - registration_lead_hours
  #   fire = registration_open - PreFireSeconds
  # We honor whatever lead value targets.json carries (default 167h for Wellbe).
  $hh, $mm = $t.time.Split(":")
  $lead = if ($null -ne $t.registration_lead_hours) { [int]$t.registration_lead_hours } else { 167 }

  # Find the next occurrence of (class_dow, class_time) strictly in the future.
  # .NET DayOfWeek and our 0=Sun..6=Sat scheme match: Sunday=0..Saturday=6.
  $todayAtClassTime = (Get-Date -Hour ([int]$hh) -Minute ([int]$mm) -Second 0)
  $daysAhead = ((([int]$t.day_of_week) - [int]$todayAtClassTime.DayOfWeek) + 7) % 7
  $classDt = $todayAtClassTime.AddDays($daysAhead)
  if ($classDt -le (Get-Date)) { $classDt = $classDt.AddDays(7) }

  $registrationOpen = $classDt.AddHours(-$lead)
  $fire = $registrationOpen.AddSeconds(-$PreFireSeconds)

  $classDayName   = $dowMap[[int]$t.day_of_week]
  $triggerDayName = $dowMap[[int]$fire.DayOfWeek]
  $fireTimeStr    = $fire.ToString("HH:mm:ss")

  Write-Host "Creating task: $taskName"
  Write-Host "  -> fires every $triggerDayName at $fireTimeStr  (registration opens $($registrationOpen.ToString('ddd HH:mm:ss')), lead ${lead}h)"
  Write-Host "  -> class: $($t.name) on $classDayName at $($t.time)"

  if ($WhatIf) { continue }

  # Build the action: pwsh -File pilates.ps1 register-target ...
  $argLine = (
    "-NoProfile -ExecutionPolicy Bypass " +
    "-File `"$wrapper`" register-target " +
    "--target-id $($t.id) --confirm BOOK --wait " +
    "--max-seconds 90 --interval 0.5 --pre-fire-seconds 2 " +
    "--max-wait-seconds 60"
  )
  $action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $argLine `
    -WorkingDirectory $here

  $trigger = New-ScheduledTaskTrigger `
    -Weekly -DaysOfWeek $triggerDayName -At $fire

  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -RestartCount 0

  $principal = New-ScheduledTaskPrincipal `
    -UserId ([Environment]::UserName) `
    -LogonType Interactive `
    -RunLevel Limited

  Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Nirvana auto-book Pilates ($($t.name) every $classDayName at $($t.time))" | Out-Null
}

Write-Host "`nDone. Listing $taskPrefix-PilatesAuto-* tasks:`n" -ForegroundColor Green
Get-ScheduledTask -TaskName "$taskPrefix-PilatesAuto-*" -ErrorAction SilentlyContinue |
  Select-Object TaskName, State, @{N='NextRun';E={(Get-ScheduledTaskInfo $_).NextRunTime}} |
  Format-Table -AutoSize
