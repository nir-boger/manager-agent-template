# Run every *.tests.ps1 under tests/ and report a combined pass/fail summary.
#
# Usage:
#   pwsh -NoProfile -File tests\run-all.ps1
#   powershell -NoProfile -File tests\run-all.ps1
#
# Exit code: 0 if all tests pass, 1 otherwise.

$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot
$testFiles = Get-ChildItem -Path $testsDir -Filter '*.tests.ps1' -File | Sort-Object Name

if (-not $testFiles) {
    Write-Host "No *.tests.ps1 files found under $testsDir" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Nirvana characterization tests" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor DarkGray
Write-Host "Discovered $($testFiles.Count) test file(s):"
foreach ($f in $testFiles) { Write-Host "  - $($f.Name)" }
Write-Host ""

$totalFailed = 0
$totalPassed = 0
$failedFiles = @()

foreach ($f in $testFiles) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host "Running: $($f.Name)" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkGray

    # Run each test file in its own PowerShell child so test state doesn't bleed
    # between files (each file calls Exit-WithTestResults which calls `exit`).
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        $totalFailed++
        $failedFiles += $f.Name
    } else {
        $totalPassed++
    }
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor DarkGray
Write-Host "Summary" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor DarkGray
Write-Host "Test files: $totalPassed passed, $totalFailed failed."

if ($totalFailed -gt 0) {
    Write-Host "Failed file(s):" -ForegroundColor Red
    foreach ($n in $failedFiles) { Write-Host "  - $n" -ForegroundColor Red }
    exit 1
}

Write-Host "All test files green." -ForegroundColor Green
exit 0
