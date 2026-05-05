# Shared helper for runner scripts to send the manager a short summary email
# after a scheduled task completes.
#
# Usage (dot-source from a runner):
#   . 'c:\...\_runner-email.ps1'
#   Send-RunnerSummaryEmail -RunnerName 'DailySummary import' `
#                           -SubjectSuffix '2026-05-01: 3 directs, 10 contacts' `
#                           -BodyHtml $htmlSummary
#
# Behavior:
#   - Recipient defaults to manager.email from config/agent.json (you@example.com on Nir's install).
#   - Subject is prefixed with agent.mail_subject_prefix from config (e.g. "[Nirvana]") so inbox-watch
#     ignores it.
#   - Body is wrapped with a short standard footer that identifies the runner.
#   - A short, relevant joke is appended (saved Nir preference) unless -NoJoke is set.
#   - Errors are caught and logged via Write-Log if available; never throws.
#   - Returns $true on send, $false on failure.
#
# Migration-mode freeze
#   When _shared/migration-mode.ps1 reports active (env var or flag file), the
#   send is short-circuited with a log line and the function returns $true.
#   This lets the templatize-Nirvana refactor proceed without sending real
#   emails to the manager.

# Build-RunnerSummaryEmail composes the message without sending. Useful for tests.
function Build-RunnerSummaryEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunnerName,
        [Parameter(Mandatory)] [string] $SubjectSuffix,
        [Parameter(Mandatory)] [string] $BodyHtml,
        [string]   $Recipient,
        [string]   $SubjectPrefix,
        [string[]] $JokePool = @(),
        [switch]   $NoJoke,
        [switch]   $NoNotice
    )

    # Resolve config-driven defaults inside the body (NEVER in param defaults --
    # parameter binding runs before the function can catch errors, so a broken
    # config would crash the call).
    . (Join-Path $PSScriptRoot '_shared\config.ps1')
    if (-not $Recipient) {
        $Recipient = Get-AgentField -Path 'manager.email'              -Default 'you@example.com'
    }
    if (-not $SubjectPrefix) {
        $SubjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'
    }

    $subject = "$SubjectPrefix $RunnerName - $SubjectSuffix"

    $jokeHtml = ''
    if (-not $NoJoke -and $JokePool -and $JokePool.Count -gt 0) {
        $joke = $JokePool | Get-Random
        $jokeHtml = "<p style='color:#666;font-style:italic;margin-top:14px'>$joke</p>"
    }

    # Centralized signature (canonical wording + optional notice from config/signature-notice.txt).
    . (Join-Path $PSScriptRoot '_shared\signature.ps1')
    $signature = Get-NirvanaSignature -Variant RunnerHeartbeat -RunnerName $RunnerName -NoNotice:$NoNotice

    $html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
            $BodyHtml +
            $jokeHtml +
            $signature +
            "</body></html>"

    return [PSCustomObject]@{
        Recipient = $Recipient
        Subject   = $subject
        HtmlBody  = $html
    }
}

function Send-RunnerSummaryEmail {
    param(
        [Parameter(Mandatory)] [string] $RunnerName,
        [Parameter(Mandatory)] [string] $SubjectSuffix,
        [Parameter(Mandatory)] [string] $BodyHtml,
        [string]   $Recipient,
        [string]   $SubjectPrefix,
        [string[]] $JokePool = @(),
        [switch]   $NoJoke,
        [switch]   $NoNotice
    )

    $logFn = Get-Command Write-Log -ErrorAction SilentlyContinue
    function _log { param([string]$m) if ($logFn) { Write-Log $m } else { Write-Host $m } }

    # Migration-mode freeze: when active, log + return $true without touching COM.
    # This stays BEFORE config resolution so a broken config doesn't prevent the freeze.
    . (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')
    if (Test-MigrationMode) {
        _log "  Migration mode active - skipping send (Runner: $RunnerName, Suffix: $SubjectSuffix)."
        return $true
    }

    try {
        $msg = Build-RunnerSummaryEmail -RunnerName $RunnerName -SubjectSuffix $SubjectSuffix `
            -BodyHtml $BodyHtml -Recipient $Recipient -SubjectPrefix $SubjectPrefix `
            -JokePool $JokePool -NoJoke:$NoJoke -NoNotice:$NoNotice

        $ol = New-Object -ComObject Outlook.Application
        $mail = $ol.CreateItem(0)   # olMailItem
        $mail.To = $msg.Recipient
        $mail.Subject = $msg.Subject
        $mail.HTMLBody = $msg.HtmlBody
        $mail.Send() | Out-Null

        # Release COM objects.
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null

        _log "  Sent runner summary email to $($msg.Recipient) (subject: $($msg.Subject))."
        return $true
    }
    catch {
        _log "  WARN: failed to send runner summary email: $($_.Exception.Message)"
        return $false
    }
}
