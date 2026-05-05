<#
.SYNOPSIS
    Thin wrapper around whatsapp.js. Auto-installs Playwright on first run.

.EXAMPLES
    .\whatsapp.ps1 list-allowed
    .\whatsapp.ps1 read --chat 'Partner Name' --limit 20
    .\whatsapp.ps1 send --chat 'Partner Name' --message 'on my way'
    .\whatsapp.ps1 send --chat 'Partner Name' --message 'on my way' --confirm SEND
    .\whatsapp.ps1 login
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RestArgs
)

$ErrorActionPreference = 'Stop'
$skillDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# First-run: install Playwright and the Chromium browser binary.
$nodeModules = Join-Path $skillDir 'node_modules'
if (-not (Test-Path (Join-Path $nodeModules 'playwright'))) {
    Write-Host '[whatsapp] First run — installing Playwright...' -ForegroundColor Cyan
    Push-Location $skillDir
    try {
        & npm install --no-audit --no-fund --loglevel=error
        if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE)." }
        & npx --yes playwright install chromium
        if ($LASTEXITCODE -ne 0) { throw "playwright install chromium failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

$entry = Join-Path $skillDir 'whatsapp.js'
& node $entry @RestArgs
exit $LASTEXITCODE

