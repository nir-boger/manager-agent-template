# Rebuilds the Nirvana Explorer site (reports/site/nirvana.html) from current
# state of config/skills.json, personas, workspace artifacts, scheduled tasks.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-nirvana-site.ps1
#
# Flags:
#   -OpenAfter   open the generated HTML in the default browser after build
#
# Scheduled by:  DM-NirvanaSiteBuild  (daily 06:00 IST).

[CmdletBinding()]
param(
    [switch] $OpenAfter
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$timestamp = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$logFile   = Join-Path $LogDir "nirvana-site-$timestamp.log"
$buildPy   = Join-Path $AgentRoot '.copilot\skills\nirvana-site\build.py'
$outFile   = Join-Path $AgentRoot 'reports\site\nirvana.html'

if (-not (Test-Path $buildPy)) {
    "[error] build.py not found at $buildPy" | Tee-Object -FilePath $logFile -Append | Write-Error
    exit 2
}

"[info] $(Get-Date -Format 'o') starting nirvana-site build" | Tee-Object -FilePath $logFile -Append | Out-Null
"[info] build.py = $buildPy"                                 | Tee-Object -FilePath $logFile -Append | Out-Null
"[info] out      = $outFile"                                 | Tee-Object -FilePath $logFile -Append | Out-Null

$pyOutput = & python $buildPy 2>&1
$pyExit = $LASTEXITCODE

$pyOutput | Tee-Object -FilePath $logFile -Append | ForEach-Object { Write-Host $_ }

if ($pyExit -ne 0) {
    "[error] python build.py exited with code $pyExit" | Tee-Object -FilePath $logFile -Append | Write-Error
    exit $pyExit
}

if (Test-Path $outFile) {
    $size = (Get-Item $outFile).Length
    "[ok] wrote $outFile ($([math]::Round($size/1024,1)) KB)" | Tee-Object -FilePath $logFile -Append | Out-Null
} else {
    "[error] output file missing at $outFile after build" | Tee-Object -FilePath $logFile -Append | Write-Error
    exit 3
}

if ($OpenAfter) {
    Start-Process $outFile
}

exit 0

