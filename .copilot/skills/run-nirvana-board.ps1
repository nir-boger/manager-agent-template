# Starts (or stops) the local Nirvana Board web app at http://localhost:<port>.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-nirvana-board.ps1
#
# Flags:
#   -Port        Port to listen on (default 5180).
#   -NoBrowser   Start the server but don't open a browser tab.
#   -Stop        Stop a running board (kills the PID stored in state\server.pid).
#   -Status      Print whether the board is up + version, then exit.
#   -Foreground  Run the server in this PS console attached (useful for debugging).
#
# Not scheduled. Opened on demand only.

[CmdletBinding()]
param(
    [int]    $Port = 5180,
    [switch] $NoBrowser,
    [switch] $Stop,
    [switch] $Status,
    [switch] $Foreground
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# Suppress Invoke-WebRequest progress bars - they can deadlock the runner
# when stdout is redirected (e.g. by another shell or wscript hosting).
$ProgressPreference = 'SilentlyContinue'

$skillRoot = Join-Path $AgentRoot '.copilot\skills\nirvana-board'
$serveScript = Join-Path $skillRoot 'serve.py'
$stateDir = Join-Path $skillRoot 'state'
$pidFile = Join-Path $stateDir 'server.pid'
$portFile = Join-Path $stateDir 'server.port'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$timestamp = (Get-Date).ToString('yyyy-MM-dd_HHmm')
$logFile = Join-Path $LogDir "nirvana-board-$timestamp.log"

function Get-RunningPid {
    if (-not (Test-Path $pidFile)) { return $null }
    $raw = (Get-Content -Path $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw) { return $null }
    $parsedPid = 0
    if (-not [int]::TryParse($raw, [ref] $parsedPid)) { return $null }
    $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if ($proc.HasExited) { return $null }
    return $parsedPid
}

function Get-RunningPort {
    if (-not (Test-Path $portFile)) { return $null }
    $raw = (Get-Content -Path $portFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw) { return $null }
    $parsedPort = 0
    if (-not [int]::TryParse($raw, [ref] $parsedPort)) { return $null }
    return $parsedPort
}

function Test-BoardHealth {
    param([int] $ProbePort)
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$ProbePort/api/health" -TimeoutSec 2
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

if ($Status) {
    $runningPid = Get-RunningPid
    $runningPort = Get-RunningPort
    if ($runningPid -and $runningPort -and (Test-BoardHealth -ProbePort $runningPort)) {
        Write-Host "nirvana-board: UP   pid=$runningPid port=$runningPort url=http://localhost:$runningPort/"
        exit 0
    }
    Write-Host "nirvana-board: DOWN"
    exit 1
}

if ($Stop) {
    $runningPid = Get-RunningPid
    if (-not $runningPid) {
        Write-Host "nirvana-board: nothing to stop (no live PID file)."
        Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
        Remove-Item -Path $portFile -ErrorAction SilentlyContinue
        exit 0
    }
    try {
        Stop-Process -Id $runningPid -Force
        Write-Host "nirvana-board: stopped pid=$runningPid."
    } catch {
        Write-Warning "nirvana-board: failed to stop pid=$runningPid -- $_"
    } finally {
        Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
        Remove-Item -Path $portFile -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not (Test-Path $serveScript)) {
    Write-Error "serve.py not found at $serveScript"
    exit 2
}

# Stop any leftover stale instance silently before launching a fresh one.
$existingPid = Get-RunningPid
if ($existingPid) {
    $existingPort = Get-RunningPort
    if ($existingPort -and (Test-BoardHealth -ProbePort $existingPort)) {
        Write-Host "nirvana-board: already running pid=$existingPid port=$existingPort"
        if (-not $NoBrowser) { Start-Process "http://localhost:$existingPort/" | Out-Null }
        exit 0
    }
    # Stale PID -- best-effort stop, then continue.
    try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch { }
}

"[info] $(Get-Date -Format 'o') starting nirvana-board on port $Port" | Tee-Object -FilePath $logFile -Append | Out-Null

if ($Foreground) {
    # Run attached for debugging. CTRL+C exits.
    & python $serveScript --port $Port 2>&1 | Tee-Object -FilePath $logFile -Append
    exit $LASTEXITCODE
}

$serverLog = Join-Path $stateDir 'server.log'
"[info] $(Get-Date -Format 'o') starting (detached) on port $Port" | Out-File -FilePath $serverLog -Encoding utf8 -Append

$proc = Start-Process -FilePath 'python' `
    -ArgumentList @($serveScript, '--port', "$Port") `
    -WorkingDirectory $AgentRoot `
    -RedirectStandardOutput $serverLog `
    -RedirectStandardError "$serverLog.err" `
    -WindowStyle Hidden `
    -PassThru

if (-not $proc) {
    "[error] failed to launch python serve.py" | Tee-Object -FilePath $logFile -Append | Write-Error
    exit 3
}

$proc.Id | Out-File -FilePath $pidFile -Encoding ascii -NoNewline
$Port | Out-File -FilePath $portFile -Encoding ascii -NoNewline

# Poll /api/health for up to 10s.
$deadline = (Get-Date).AddSeconds(10)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) { break }
    if (Test-BoardHealth -ProbePort $Port) { $ready = $true; break }
}

if ($proc.HasExited) {
    "[error] server process exited with code $($proc.ExitCode) -- check $serverLog" `
        | Tee-Object -FilePath $logFile -Append | Write-Error
    Remove-Item -Path $pidFile -ErrorAction SilentlyContinue
    Remove-Item -Path $portFile -ErrorAction SilentlyContinue
    exit 4
}

if (-not $ready) {
    "[warn] server didn't answer /api/health within 10s; check $serverLog" `
        | Tee-Object -FilePath $logFile -Append | Write-Warning
    # Leave it running -- user can decide whether to stop it.
}

$url = "http://localhost:$Port/"
"[ok] nirvana-board listening pid=$($proc.Id) url=$url" | Tee-Object -FilePath $logFile -Append | Out-Null
Write-Host "nirvana-board: UP   pid=$($proc.Id) port=$Port url=$url"

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

exit 0

