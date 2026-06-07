# Generic reports/logs housekeeping pruner.
#
# Prunes the runtime-only (gitignored) reports/logs/ folder so it doesn't grow
# unbounded. Flow-agnostic: it operates on the whole folder by age, so every
# current AND future skill is covered automatically -- no per-skill wiring.
#
# Rules:
#   - *.log files: deleted when older than the retention window, EXCEPT the
#     newest N per flow prefix are always kept (so a rarely-run flow never loses
#     all its history).
#   - non-.log scratch debris (temp-*.py, *.json, stray *.ps1, ...): deleted
#     purely by age when -IncludeScratch (default on). No keep-N protection.
#   - Grace period: nothing modified within the last few hours is ever touched,
#     so an actively-appending log from a running flow is never truncated.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-logs-cleanup.ps1 -DryRun
# Flags:
#   -RetentionDays N      override retention window (default from config/agent.json, else 14)
#   -KeepMinPerPrefix N   newest .log files kept per flow prefix (default from config, else 5)
#   -GraceHours N         never touch files modified in the last N hours (default from config, else 6)
#   -IncludeScratch:$false  prune *.log only, leave non-log files alone
#   -DryRun               compute + log what would be deleted, delete nothing
# Scheduled by:  DM-LogsCleanup (daily 05:30 IST).

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 3650)]
    [int] $RetentionDays = 0,

    [ValidateRange(0, 1000)]
    [int] $KeepMinPerPrefix = -1,

    [ValidateRange(0, 720)]
    [int] $GraceHours = -1,

    [bool] $IncludeScratch = $true,

    [switch] $DryRun
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# --- Resolve effective settings (param overrides config overrides default) ----
$cfgRetention = [int](Get-AgentField -Path 'logs.retention_days'      -Default 14 -Config $AgentConfig)
$cfgKeep      = [int](Get-AgentField -Path 'logs.keep_min_per_prefix' -Default 5  -Config $AgentConfig)
$cfgGrace     = [int](Get-AgentField -Path 'logs.grace_hours'         -Default 6  -Config $AgentConfig)

if ($RetentionDays    -le 0) { $RetentionDays    = $cfgRetention }
if ($KeepMinPerPrefix -lt 0) { $KeepMinPerPrefix = $cfgKeep }
if ($GraceHours       -lt 0) { $GraceHours       = $cfgGrace }

$logFile = Join-Path $LogDir ("logs-cleanup-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")
$selfLogFull = [System.IO.Path]::GetFullPath($logFile)

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Safety guard: $LogDir MUST resolve to <agent-root>\reports\logs ----------
$expectedLogDir = [System.IO.Path]::GetFullPath((Join-Path $AgentRoot 'reports\logs'))
$actualLogDir   = [System.IO.Path]::GetFullPath($LogDir)
if ($actualLogDir.TrimEnd('\') -ne $expectedLogDir.TrimEnd('\')) {
    Write-Log "ABORT: refusing to prune unexpected LogDir '$actualLogDir' (expected '$expectedLogDir')."
    throw "Unsafe LogDir: $actualLogDir"
}

$now    = Get-Date
$cutoff = $now.AddDays(-$RetentionDays)
$grace  = $now.AddHours(-$GraceHours)

Write-Log "logs-cleanup start: retentionDays=$RetentionDays keepMinPerPrefix=$KeepMinPerPrefix graceHours=$GraceHours includeScratch=$IncludeScratch dryRun=$($DryRun.IsPresent)"
Write-Log "cutoff=$($cutoff.ToString('o'))  grace(no-touch-after)=$($grace.ToString('o'))"

# --- Enumerate (non-recursive; this folder is flat) ---------------------------
$files = @(Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue)
Write-Log "Found $($files.Count) file(s) in reports/logs."
if ($files.Count -eq 0) { Write-Log "Nothing to do."; return }

# --- Group .log files by flow prefix; compute the protected (newest-N) set ----
# Anchored date-suffix match avoids treating arbitrary digits as a boundary.
$dateSuffixRe = '^(?<prefix>.+?)-\d{4}-\d{2}-\d{2}(?:[_-]\d{2,6})*$'
function Get-FlowPrefix {
    param([string]$BaseName)
    if ($BaseName -match $dateSuffixRe) { return $Matches['prefix'] }
    return $BaseName
}

$logFiles = @($files | Where-Object { $_.Extension -ieq '.log' })
$protected = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

$logFiles |
    Group-Object { Get-FlowPrefix $_.BaseName } |
    ForEach-Object {
        $_.Group |
            Sort-Object @{E='LastWriteTime';Descending=$true}, @{E='Name';Descending=$true} |
            Select-Object -First $KeepMinPerPrefix |
            ForEach-Object { [void]$protected.Add([System.IO.Path]::GetFullPath($_.FullName)) }
    }

# --- Decide per file ----------------------------------------------------------
$toDelete  = New-Object System.Collections.Generic.List[object]
$keptRecent = 0; $keptGrace = 0; $keptProtected = 0; $keptScratch = 0

foreach ($f in $files) {
    $full = [System.IO.Path]::GetFullPath($f.FullName)

    if ($full -ieq $selfLogFull)        { $keptGrace++;  continue }   # never delete my own log
    if ($f.LastWriteTime -ge $grace)    { $keptGrace++;  continue }   # actively-appending guard
    if ($f.LastWriteTime -ge $cutoff)   { $keptRecent++; continue }   # within retention

    if ($f.Extension -ieq '.log') {
        if ($protected.Contains($full)) { $keptProtected++; continue }
        $toDelete.Add($f)
    }
    else {
        if (-not $IncludeScratch)        { $keptScratch++; continue }
        $toDelete.Add($f)
    }
}

$bytes = ($toDelete | Measure-Object Length -Sum).Sum
Write-Log ("Plan: delete {0} file(s) ({1:N1} MB). Kept: {2} within-retention, {3} grace/self, {4} newest-N-per-flow, {5} scratch-protected." -f `
    $toDelete.Count, ($bytes/1MB), $keptRecent, $keptGrace, $keptProtected, $keptScratch)

if ($DryRun) {
    $toDelete | Sort-Object LastWriteTime | Select-Object -First 25 | ForEach-Object {
        Write-Log "  [would delete] $($_.Name)  ($($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
    }
    if ($toDelete.Count -gt 25) { Write-Log "  ... and $($toDelete.Count - 25) more." }
    Write-Log "DryRun set - deleted nothing."
    return
}

# --- Delete (locked files are non-fatal warnings) -----------------------------
$deleted = 0; $failed = 0
foreach ($f in $toDelete) {
    if ($PSCmdlet.ShouldProcess($f.FullName, 'Remove log file')) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deleted++
        }
        catch {
            $failed++
            Write-Log "  WARN: could not delete $($f.Name): $($_.Exception.Message)"
        }
    }
}

Write-Log "logs-cleanup complete: deleted=$deleted failed=$failed (freed ~$([math]::Round($bytes/1MB,1)) MB)."

