# _shared/comms.ps1 -- canonical channel-adapter for Nirvana outbound messages.
#
# Single send primitive behind a small channel registry, so every NEW comms path
# routes through one tested entry point instead of hand-rolling Outlook COM.
#
#   . 'c:\...\_shared\comms.ps1'
#   Send-NirvanaMessage -Channel email -To 'a@b.com' -Subject 'Hi' -BodyHtml '<p>...</p>'
#
# Channels:
#   email    -- PS-native (Outlook COM, same proven recipe as _runner-email.ps1)
#   whatsapp -- agent-orchestrated today (whatsapp/whatsapp.ps1); adapter exposes
#               metadata + DryRun compose, real send not yet wired here.
#   teams    -- agent-orchestrated (post-to-teams SKILL.md); metadata + DryRun only.
#
# Design notes:
#   * Self-contained: dot-sources config / signature / migration-mode lazily INSIDE
#     functions (never at top), preserving the shared-helper lazy-load invariant.
#   * Additive: existing 7 comms flows are untouched. This is the forward path.
#   * Send-NirvanaMessage NEVER throws on a send failure -- it returns a result
#     object with Sent=$false + Error, mirroring Send-RunnerSummaryEmail.
#   * Migration-mode freeze short-circuits the real send (returns Sent=$true,
#     Skipped='migration-mode') so the templatize refactor can't email anyone.

function Get-CommsChannels {
    # Ordered registry. 'kind' = how the message is actually delivered today.
    return @(
        [pscustomobject]@{ Name = 'email';    Kind = 'native' },
        [pscustomobject]@{ Name = 'whatsapp'; Kind = 'agent-orchestrated' },
        [pscustomobject]@{ Name = 'teams';    Kind = 'agent-orchestrated' }
    )
}

function Test-CommsChannel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Channel)
    return @(Get-CommsChannels | ForEach-Object { $_.Name }) -contains $Channel.ToLowerInvariant()
}

function Get-CommsChannelKind {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Channel)
    $c = Get-CommsChannels | Where-Object { $_.Name -eq $Channel.ToLowerInvariant() } | Select-Object -First 1
    if (-not $c) { return $null }
    return $c.Kind
}

function Test-CommsRecipient {
    # Pure recipient validation. Email recipients must look like SMTP addresses
    # (allow ';'/',' separated lists). whatsapp/teams recipients are free-form.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Channel,
        [Parameter(Mandatory)] [string] $To
    )
    if ([string]::IsNullOrWhiteSpace($To)) { return $false }
    if ($Channel.ToLowerInvariant() -ne 'email') { return $true }
    $parts = $To -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($parts.Count -eq 0) { return $false }
    foreach ($p in $parts) {
        if ($p -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return $false }
    }
    return $true
}

function Build-CommsEmail {
    # Pure-ish composer: wraps the body in the standard shell + canonical signature.
    # No send side-effects. Returned object is what Send-NirvanaMessage delivers.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $To,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $BodyHtml,
        [string] $SubjectPrefix,
        [switch] $NoSignature,
        [switch] $NoNotice
    )

    . (Join-Path $PSScriptRoot 'config.ps1')
    if (-not $PSBoundParameters.ContainsKey('SubjectPrefix') -or [string]::IsNullOrEmpty($SubjectPrefix)) {
        $SubjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'
    }

    $finalSubject = if ($SubjectPrefix) { "$SubjectPrefix $Subject" } else { $Subject }

    $sig = ''
    if (-not $NoSignature) {
        . (Join-Path $PSScriptRoot 'signature.ps1')
        $sig = Get-NirvanaSignature -Variant Default -NoNotice:$NoNotice
    }

    $html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>" +
            $BodyHtml + $sig + "</body></html>"

    return [pscustomobject]@{
        Channel  = 'email'
        To       = $To
        Subject  = $finalSubject
        HtmlBody = $html
    }
}

function Send-NirvanaMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Channel,
        [Parameter(Mandatory)] [string] $To,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $BodyHtml,
        [string] $SubjectPrefix,
        [switch] $NoSignature,
        [switch] $NoNotice,
        [switch] $DryRun
    )

    $chan = $Channel.ToLowerInvariant()
    $result = [pscustomobject]@{
        Channel = $chan
        To      = $To
        Subject = $Subject
        Sent    = $false
        DryRun  = [bool]$DryRun
        Skipped = $null
        Error   = $null
    }

    if (-not (Test-CommsChannel -Channel $chan)) {
        $result.Error = "unknown channel: '$Channel'"
        return $result
    }
    if (-not (Test-CommsRecipient -Channel $chan -To $To)) {
        $result.Error = "invalid recipient for channel '$chan': '$To'"
        return $result
    }

    # Only the email channel is delivered natively here. The others carry valid
    # metadata + DryRun compose, but real send stays with their existing flows.
    if ($chan -ne 'email') {
        $result.Skipped = 'agent-orchestrated'
        if ($DryRun) { $result.Sent = $true }   # compose-only "success"
        else { $result.Error = "channel '$chan' is agent-orchestrated; use its skill flow to send" }
        return $result
    }

    $msg = Build-CommsEmail -To $To -Subject $Subject -BodyHtml $BodyHtml `
        -SubjectPrefix $SubjectPrefix -NoSignature:$NoSignature -NoNotice:$NoNotice
    $result.Subject = $msg.Subject

    if ($DryRun) { $result.Sent = $true; $result.Skipped = 'dry-run'; return $result }

    # Migration-mode freeze BEFORE any COM call.
    . (Join-Path $PSScriptRoot 'migration-mode.ps1')
    if (Test-MigrationMode) {
        $result.Sent = $true; $result.Skipped = 'migration-mode'
        return $result
    }

    try {
        $ol = New-Object -ComObject Outlook.Application
        $mail = $ol.CreateItem(0)   # olMailItem
        $mail.To = $msg.To
        $mail.Subject = $msg.Subject
        $mail.HTMLBody = $msg.HtmlBody
        $mail.Send() | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
        $result.Sent = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}
