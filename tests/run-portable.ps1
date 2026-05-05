<#
.SYNOPSIS
  Runs the portable test subset — tests that work on any fork without
  characterization expectations on the manager's specific name / email / team.

.DESCRIPTION
  Used by smoke-test.ps1 to validate fork installs. Excludes Nir-specific
  characterization tests (signature wording, runner-email wording,
  AGENTS.md-content) which only pass on Nir's install.

  Portable tests rely on synthetic fixtures, structural inspection, or path
  existence checks — never the live config values.
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'

# Whitelist (alphabetical):
$portable = @(
    'config.tests.ps1',
    'migration-mode.tests.ps1',
    'render-template.tests.ps1',
    'runner-prelude.tests.ps1',
    'runners-bootstrap.tests.ps1',
    'skills-manifest.tests.ps1'
)

# Characterization (skipped here, runs separately via run-all.ps1):
#   agents-md-render.tests.ps1   - asserts "Nirvana" / "Your Team" / "your-ado-org"
#   runner-email.tests.ps1       - asserts you@example.com + [Nirvana]
#   signature.tests.ps1          - asserts "Nir" / "Nirvana" / Hebrew sig wording

$here = $PSScriptRoot
Write-Host "Portable test subset" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor DarkGray

$failed = 0
$failedFiles = @()
foreach ($t in $portable) {
    $path = Join-Path $here $t
    if (-not (Test-Path $path)) {
        Write-Host "  [MISSING] $t" -ForegroundColor Red
        $failed++; $failedFiles += $t
        continue
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        $failed++
        $failedFiles += $t
    }
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor DarkGray
if ($failed -eq 0) {
    Write-Host "Portable tests: $($portable.Count) files passed." -ForegroundColor Green
    exit 0
}
Write-Host ("Portable tests: {0} file(s) failed." -f $failed) -ForegroundColor Red
foreach ($n in $failedFiles) { Write-Host "  - $n" -ForegroundColor Red }
exit 1

