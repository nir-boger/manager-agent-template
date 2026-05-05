<#
.SYNOPSIS
  Bootstrap-only smoke test: parse, render, doctor, portable tests, build-only
  email composition. Does NOT execute runners end-to-end.

.DESCRIPTION
  This is the canonical "did I break the install?" check after edits, and the
  CI-gate for the public template snapshot. It runs:
    1. parse-check on every .ps1 (via doctor.ps1)
    2. doctor.ps1 (asset / render / config validation)
    3. portable test subset (no Nir-specific characterization)
    4. compose-only Build-RunnerSummaryEmail
  It does NOT call .Send(), does NOT register scheduled tasks, does NOT touch
  Outlook COM beyond what individual tests require.

.PARAMETER Root
  Forwarded to doctor.ps1. Use to smoke-test a snapshot output root instead of
  the live tree.
#>
[CmdletBinding()]
param(
    [string] $Root
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Write-Section($s) { Write-Host ""; Write-Host ("=" * 60) -ForegroundColor DarkGray; Write-Host $s -ForegroundColor Cyan; Write-Host ("=" * 60) -ForegroundColor DarkGray }

$here = if ($Root) { (Resolve-Path $Root).Path } else { $PSScriptRoot }

# --- 1. doctor.ps1 -------------------------------------------------------
Write-Section "1/3 doctor.ps1"
$doctor = Join-Path $here 'doctor.ps1'
if ($Root) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -Root $Root
} else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor
}
if ($LASTEXITCODE -ne 0) { Write-Host "smoke: doctor failed" -ForegroundColor Red; exit 1 }

# --- 2. portable tests ---------------------------------------------------
Write-Section "2/3 portable tests"
$portable = Join-Path $here 'tests\run-portable.ps1'
if (-not (Test-Path $portable)) {
    Write-Host "smoke: tests\run-portable.ps1 not found" -ForegroundColor Red
    exit 1
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $portable
if ($LASTEXITCODE -ne 0) { Write-Host "smoke: portable tests failed" -ForegroundColor Red; exit 1 }

# --- 3. compose-only Build-RunnerSummaryEmail ----------------------------
Write-Section "3/3 compose-only email"
. (Join-Path $here '.copilot\skills\_shared\config.ps1')
. (Join-Path $here '.copilot\skills\_runner-email.ps1')
$msg = Build-RunnerSummaryEmail `
    -RunnerName 'smoke-test' `
    -SubjectSuffix 'OK' `
    -BodyHtml '<p>smoke summary</p>' `
    -NoJoke
if ($null -eq $msg -or [string]::IsNullOrWhiteSpace($msg.Recipient)) {
    Write-Host "smoke: Build-RunnerSummaryEmail produced no recipient" -ForegroundColor Red
    exit 1
}
Write-Host ("  [PASS] composed for {0} | subject: {1}" -f $msg.Recipient, $msg.Subject) -ForegroundColor Green

Write-Host ""
Write-Host "smoke: OK" -ForegroundColor Green
exit 0
