# Single source of truth for ensuring Outlook desktop is running before COM calls.
#
# Usage (dot-source from any runner):
#   . '<repo>\.copilot\skills\_shared\ensure-outlook.ps1'
#   if (-not (Ensure-OutlookRunning)) { exit 0 }
#
# Behavior:
#   - If Outlook process is already running, returns $true immediately (no-op).
#   - Otherwise launches OUTLOOK.EXE /recycle (silent, no main window) and waits
#     up to MaxWaitSec for the process AND COM Outlook.Application to respond.
#   - Returns $true on ready, $false on timeout. Caller should exit 0 cleanly
#     on $false (we never throw).
#
# Why /recycle: if an Outlook session is already up (e.g. minimized to tray)
# /recycle is a near no-op that just reattaches; if not, it spins one up.
# Combined with the HKCU Run-key auto-start entry (set by register-outlook-
# autostart.ps1), this keeps Outlook continuously available for scheduled
# tasks even if Nir manually closed it earlier.

function Ensure-OutlookRunning {
    [CmdletBinding()]
    param(
        [int] $MaxWaitSec = 60,
        [string] $LogFile
    )

    $writeLog = {
        param([string] $msg)
        if ($LogFile) {
            try {
                "[$((Get-Date).ToString('o'))] ensure-outlook: $msg" |
                    Add-Content -Path $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    if (Get-Process OUTLOOK -ErrorAction SilentlyContinue) {
        & $writeLog 'already running'
        return $true
    }

    $exe = $null
    try {
        $exe = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' -ErrorAction SilentlyContinue).'(default)'
    } catch { }
    if (-not $exe -or -not (Test-Path $exe)) { $exe = 'OUTLOOK.EXE' }

    & $writeLog "launching $exe /recycle"
    try {
        Start-Process -FilePath $exe -ArgumentList '/recycle' -WindowStyle Minimized -ErrorAction Stop | Out-Null
    } catch {
        & $writeLog "Start-Process failed: $($_.Exception.Message)"
        return $false
    }

    $start = Get-Date
    $deadline = $start.AddSeconds($MaxWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process OUTLOOK -ErrorAction SilentlyContinue) {
            $ol = $null
            try {
                $ol = New-Object -ComObject Outlook.Application
                $null = $ol.GetNamespace('MAPI').DefaultStore
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)
                $elapsed = [int]((Get-Date) - $start).TotalSeconds
                & $writeLog "ready after ${elapsed}s"
                return $true
            } catch {
                if ($ol) {
                    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) } catch { }
                }
                Start-Sleep -Seconds 2
                continue
            }
        }
        Start-Sleep -Seconds 1
    }

    & $writeLog "timed out after ${MaxWaitSec}s"
    return $false
}

