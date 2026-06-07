# Personal Todos daily reminder runner.
#
# Parses reports/personal-todos/todos.md, builds the fancy HTML body via
# build-daily.py, and emails Nir a one-page daily reminder.
#
# Triggered daily at 07:00 IST by scheduled task DM-PersonalTodosDaily, or on demand.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\copilot\skills\run-personal-todos-daily.ps1
# Flags:
#   -DryRun    build HTML + state snapshot; do NOT send email
#   -Force     bypass per-day idempotency check
#   -NoEmail   alias of -DryRun
#   -NoSuggest skip the auto-suggest block
#   -Today     YYYY-MM-DD override (testing)
#
# Per-day idempotency: state\last-sent.txt prevents duplicate sends in the same calendar day.
# Single-instance lock: reports\logs\personal-todos.lock (30-min stale window).
# Weekday skip: config\personal-todos.yaml -> skip_days suppresses the send on the
#   listed days (Friday + Saturday by default, since Nir's work week is Sun-Thu).
#   -Force always bypasses the skip (and idempotency), so on-demand sends work any day.

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [switch] $NoEmail,
    [switch] $NoSuggest,
    [string] $Today
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_runner-email.ps1')
. (Join-Path $PSScriptRoot 'personal-todos\skip-days.ps1')

if ($NoEmail) { $DryRun = $true }

$skillDir    = Join-Path $AgentRoot '.copilot\skills\personal-todos'
$stateDir    = Join-Path $skillDir 'state'
$lastSent    = Join-Path $stateDir 'last-sent.txt'
$reportsRoot = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) -Config $AgentConfig
$todosFile   = Join-Path $reportsRoot 'personal-todos\todos.md'
$configFile  = Join-Path $AgentRoot 'config\personal-todos.yaml'
$builderPy   = Join-Path $skillDir 'build-daily.py'
$pythonExe   = Get-AgentField -Path 'paths.python_exe' -Default 'python' -Config $AgentConfig

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$now       = if ($Today) { [DateTime]::ParseExact($Today, 'yyyy-MM-dd', $null) } else { Get-Date }
$dayKey    = $now.ToString('yyyy-MM-dd')
$logFile   = Join-Path $LogDir ("personal-todos-" + $dayKey + ".log")

function Write-Log {
    param([string] $Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Single-instance lock -------------------------------------------------
$lockPath = Join-Path $LogDir 'personal-todos.lock'
if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) {
        Write-Log "Another instance is running (lock age $([int]$lockAge.TotalMinutes)m). Exiting silently."
        exit 0
    }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    Write-Log "=== personal-todos-daily start (DryRun=$DryRun, Force=$Force, Today=$dayKey) ==="

    if (-not (Test-Path $todosFile)) {
        Write-Log "Todos file not found at $todosFile. Nothing to send."
        exit 0
    }
    if (-not (Test-Path $builderPy)) {
        Write-Log "Builder script missing: $builderPy"
        exit 1
    }
    if (-not (Test-Path $configFile)) {
        Write-Log "Config missing: $configFile"
        exit 1
    }

    # --- Weekday skip gate ---------------------------------------------------
    # Nir's work week is Sun-Thu; the daily reminder is suppressed on the days
    # listed in config\personal-todos.yaml -> skip_days (Friday + Saturday by
    # default). Gating here -- before the Python builder runs -- means a skipped
    # day also leaves the prior day's last-suggest.json snapshot untouched, so a
    # weekend "PT accept N" reply still maps to the email Nir actually received.
    # -Force (the on-demand "send now" path) always bypasses.
    if (-not $Force) {
        $skipDays = Get-TodosSkipDays -ConfigFile $configFile
        if (Test-TodosSkipDay -SkipDays $skipDays -Date $now) {
            Write-Log "Today is $($now.DayOfWeek) (in skip_days: $($skipDays -join ', ')). Skipping daily reminder. Use -Force to send anyway."
            exit 0
        }
    }

    # --- Idempotency check ---------------------------------------------------
    if (-not $Force -and -not $DryRun -and (Test-Path $lastSent)) {
        $sentLines = Get-Content $lastSent -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($sentLines -contains $dayKey) {
            Write-Log "Reminder already sent today ($dayKey). Use -Force to override. Exiting."
            exit 0
        }
    }

    # --- Invoke Python builder ----------------------------------------------
    $outHtml = Join-Path $reportsRoot ("personal-todos\daily-$dayKey.html")
    New-Item -ItemType Directory -Force -Path (Split-Path $outHtml) | Out-Null

    $pyArgs = @(
        $builderPy,
        '--todos-file',   $todosFile,
        '--config',       $configFile,
        '--reports-root', $reportsRoot,
        '--state-dir',    $stateDir,
        '--out-html',     $outHtml,
        '--today',        $dayKey
    )
    if ($NoSuggest) { $pyArgs += '--no-suggest' }

    Write-Log "Invoking: $pythonExe $($pyArgs -join ' ')"
    $summaryJson = & $pythonExe @pyArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Python builder exited with code $LASTEXITCODE"
        exit 1
    }
    $summary = $summaryJson | ConvertFrom-Json
    Write-Log "Builder OK. today=$($summary.today_count) overdue=$($summary.overdue_count) open=$($summary.open_count) suggest=$($summary.suggest_count) weekly_done=$($summary.weekly_done)"

    # --- Compose subject + body ---------------------------------------------
    # Send-RunnerSummaryEmail builds: "$SubjectPrefix $RunnerName - $SubjectSuffix"
    # So RunnerName='Your day' becomes the human label; suffix is just the metric mix.
    $subjectBits = @($dayKey)
    if ($summary.today_count -gt 0)   { $subjectBits += "$($summary.today_count) due today" }
    if ($summary.overdue_count -gt 0) { $subjectBits += "$($summary.overdue_count) overdue" }
    if ($summary.today_count -eq 0 -and $summary.overdue_count -eq 0 -and $summary.open_count -eq 0) {
        $subjectBits += "inbox zero"
    }
    $subjectSuffix = ($subjectBits -join ' - ')

    # UTF-8 read — critical to preserve emoji + em-dashes (PowerShell 5.1
    # defaults to CP1252 in fresh process / scheduled task contexts).
    $htmlBody = Get-Content $outHtml -Raw -Encoding UTF8

    # Joke pool — Nirvana-band lyric headliner where it lands clean.
    # ASCII-only here: PS 5.1 reads .ps1 files via the active codepage and
    # mangles non-ASCII (em-dashes, smart quotes) when there's no BOM,
    # producing parser errors on the next line. The renderer's HTML body
    # is read via Get-Content -Encoding UTF8 above, so emoji/em-dashes
    # there are safe; only the source file itself must stay ASCII.
    $jokePool = @(
        "I'm so happy 'cause today I found my todo list. Just kidding - it's right where I left it.",
        "Come as you are, with one item closed.",
        "Lithium for the open queue: pick one and ship it.",
        "Heart-shaped box, PT-shaped list - same vibe, different storage.",
        "All apologies if PT-007 is still here next week.",
        "Stay away from the snoozed section, it bites.",
        "On a plain markdown file, no less.",
        "Drain you, one item at a time.",
        "About a girl, a credit card, and a dentist appointment.",
        "In bloom - one of these will close today, I can feel it.",
        "I think I'm dumb, or maybe just unparsed. (Not the todos. They're fine.)"
    )

    if ($DryRun) {
        Write-Log "DryRun: skipping send. HTML written to $outHtml"
        exit 0
    }

    Write-Log "Sending personal-todos daily via Send-RunnerSummaryEmail..."
    $ok = Send-RunnerSummaryEmail `
        -RunnerName 'Your day' `
        -SubjectSuffix $subjectSuffix `
        -BodyHtml $htmlBody `
        -JokePool $jokePool
    if ($ok) {
        Add-Content -Path $lastSent -Value $dayKey -Encoding UTF8
        Write-Log "Personal-todos daily sent. Stamped state/last-sent.txt with $dayKey."
    } else {
        Write-Log "Send returned false. State NOT updated."
    }

    Write-Log "=== personal-todos-daily done ==="
}
finally {
    Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
}
