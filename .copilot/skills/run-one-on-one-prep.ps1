#Requires -Version 5.1
<#
.SYNOPSIS
    one-on-one-prep runner - sends pre-1:1 prep emails to direct reports
    ~24 hours before scheduled 1:1 meetings.

.DESCRIPTION
    See .copilot/skills/one-on-one-prep/SKILL.md for the full spec.

    Scans the Outlook calendar for meetings starting in (Now+22h, Now+26h)
    whose subject matches the 1:1 regex and whose required attendees
    include a recognized direct report. Sends a deep-context prep email
    (scope, open follow-ups, LLM-suggested topics) to the direct, Cc Nir.
    Idempotent via reports/one-on-one-prep/state/sent.txt and an Outlook
    UserProperty stamp on the sent mail.

.PARAMETER DryRun
    Build everything but DO NOT send the email or stamp anything.

.PARAMETER WhatIf
    Alias for DryRun semantics around side effects.

.PARAMETER Force
    Currently a no-op (state file is the only idempotency layer the
    runner consults; -Force is reserved for future use).
#>

param(
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$Force,
    [string]$OnlySlug         = '',
    [string]$PreviewOut       = '',
    [switch]$SummaryMode,
    [string]$SummaryNotesFile = '',
    [int]   $SendHoursMin     = 22,
    [int]   $SendHoursMax     = 26,
    [int]   $PerTickCap       = 5
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$dry = ($DryRun.IsPresent -or $WhatIf.IsPresent)

# --- Preflight ---
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isElevated) {
    Write-Output "ABORT: PowerShell is elevated; Outlook COM will fail. Relaunch as a standard user."
    exit 1
}

# Verify Outlook is reachable.
try {
    $probe = New-Object -ComObject Outlook.Application
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($probe) | Out-Null
} catch {
    Write-Output "SKIP: Outlook unavailable: $($_.Exception.Message)"
    exit 0
}

$implPath = Join-Path $PSScriptRoot 'one-on-one-prep\one-on-one-prep-impl.ps1'
if (-not (Test-Path $implPath)) {
    Write-Output "ABORT: impl missing at $implPath"
    exit 1
}

if ($dry) {
    & $implPath -DryRun -OnlySlug $OnlySlug -PreviewOut $PreviewOut -SummaryMode:$SummaryMode.IsPresent -SummaryNotesFile $SummaryNotesFile -SendHoursMin $SendHoursMin -SendHoursMax $SendHoursMax -PerTickCap $PerTickCap
} else {
    & $implPath -OnlySlug $OnlySlug -PreviewOut $PreviewOut -SummaryMode:$SummaryMode.IsPresent -SummaryNotesFile $SummaryNotesFile -SendHoursMin $SendHoursMin -SendHoursMax $SendHoursMax -PerTickCap $PerTickCap
}

exit 0
