# pilates.ps1 - wrapper around pilates.py with auto-install of deps.
#
# Usage:
#   pwsh -File pilates.ps1 list --days 14
#   pwsh -File pilates.ps1 status
#   pwsh -File pilates.ps1 upcoming
#   pwsh -File pilates.ps1 register-target --target-id wed-10 --confirm BOOK --wait
#
# Forwards all args to `python pilates.py`. First run installs `requests`
# and `python-dateutil` if missing; subsequent runs are pass-through.

[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]] $Args
)

$ErrorActionPreference = "Stop"

# Locate Python - prefer the per-user 3.12 install; fall back to PATH.
$py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
if (-not (Test-Path $py)) {
  $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
  if (-not $py) { throw "Python not found. Install Python 3.12+ or fix PATH." }
}

$here = Split-Path -Parent $PSCommandPath
$marker = Join-Path $here ".deps-installed"

if (-not (Test-Path $marker)) {
  Write-Host "[pilates] First run - installing Python deps..." -ForegroundColor DarkGray
  & $py -m pip install --quiet requests python-dateutil
  if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (rc=$LASTEXITCODE)"
  }
  New-Item -ItemType File -Path $marker -Force | Out-Null
}

# Pass through every arg to pilates.py. -X utf8 forces UTF-8 mode for stdio
# so we don't crash on Unicode prints (e.g. arrows, hebrew) when the script
# is launched non-interactively from scheduled tasks under Windows PowerShell
# 5.1, where stdout otherwise falls back to cp1252.
& $py -X utf8 (Join-Path $here "pilates.py") @Args
exit $LASTEXITCODE
