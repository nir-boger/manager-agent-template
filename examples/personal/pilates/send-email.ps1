<#
.SYNOPSIS
  Send a pilates-confirmation email via Outlook COM.

.DESCRIPTION
  Used by pilates.py after a successful booking. The body file is HTML and
  contains the booking confirmation + a table of all upcoming bookings. The
  pilates.py script renders the body and writes it to a temp file, then
  invokes us with -BodyFile pointing at it.

  Honors the standard Nirvana voice rules:
    - Single joke (loaded via the shared joke-helper)
    - "Sent on Nir's behalf by Nirvana - Nir's agent." signature (shared helper)
    - NOJOKE / NOSIG overrides (passed via params)

  Always sends, never auto-marks as read or archives. Saves nothing to drafts.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Subject,
  [Parameter(Mandatory)] [string] $BodyFile,
  [string] $To,
  [switch] $NoJoke,
  [switch] $NoSig
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path $here "..\..\..")).Path
$signaturePs1 = Join-Path $repoRoot ".copilot\skills\_shared\signature.ps1"
$configPs1    = Join-Path $repoRoot ".copilot\skills\_shared\config.ps1"
$migrationPs1 = Join-Path $repoRoot ".copilot\skills\_shared\migration-mode.ps1"

# Lazy config load (DON'T resolve in param defaults -- Phase 5a invariant)
if (-not $To) {
  if (Test-Path $configPs1) {
    . $configPs1
    $To = Get-AgentField -Path 'manager.email' -Default 'you@example.com'
  } else {
    $To = 'you@example.com'
  }
}

if (-not (Test-Path $BodyFile)) {
  throw "BodyFile not found: $BodyFile"
}
$bodyHtml = Get-Content -Raw -LiteralPath $BodyFile

# Append the canonical signature (NOSIG -> omit entirely)
if (-not $NoSig.IsPresent) {
  if (Test-Path $signaturePs1) {
    . $signaturePs1
    $sig = Get-NirvanaSignature
    $bodyHtml += "`r`n" + $sig
  } else {
    $bodyHtml += "`r`n<hr><p style='color:#666;'><em>Sent on Nir's behalf by <strong>Nir</strong>vana &mdash; Nir's agent.</em></p>"
  }
}

try {
  $outlook = New-Object -ComObject Outlook.Application
  $mail = $outlook.CreateItem(0)  # 0 = olMailItem
  $mail.Subject = $Subject
  $mail.HTMLBody = $bodyHtml
  $mail.To = $To
  if (Test-Path $migrationPs1) { . $migrationPs1 }
  if ((Get-Command Test-MigrationMode -ErrorAction SilentlyContinue) -and (Test-MigrationMode)) {
    Write-Output "[migration-mode] Skipping pilates email send to=$To subject=$Subject"
    return
  }
  $mail.Send()
  Write-Output "EMAIL_SENT to=$To subject=$Subject"
} catch {
  Write-Error "EMAIL_FAILED: $($_.Exception.Message)"
  exit 2
}

