# WhatsApp preview email helper — emails the proposed WhatsApp send to Nir's own
# mailbox so he can review Hebrew rendering properly (terminal RTL is ugly).
#
# Usage (from any agent):
#   . '<repo>\.copilot\skills\whatsapp\send-preview-email.ps1'
#   Send-WhatsAppPreviewEmail `
#       -Recipient 'Partner Name' `
#       -Message  $hebrewBody `
#       -IsGroup:$false `
#       -ReplyingTo 'אני יכולה להתכתב איתך בלילות?' `
#       -Joke 'In Bloom: she likes all my pretty messages, but she knows not what they mean.'
#
# Sends to the signed-in Outlook user (Nir) and only to him. Subject:
#   [Nirvana] - WhatsApp preview → <recipient> — review
#
# To confirm and actually send, Nir replies `send` in the agent CLI; the agent
# then runs `node whatsapp.js send --chat <recipient> --message <body> --confirm SEND`.

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Send-WhatsAppPreviewEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Recipient,
        [Parameter(Mandatory)] [string] $Message,
        [switch] $IsGroup,
        [string] $ReplyingTo,
        [string] $Joke,
        [switch] $NoJoke
    )

    Add-Type -AssemblyName System.Web | Out-Null

    # Self-bootstrap config (this script may be dot-sourced from the agent CLI,
    # not from a runner -- so we cannot rely on runner-prelude having run).
    . (Join-Path $PSScriptRoot '..\_shared\config.ps1')
    . (Join-Path $PSScriptRoot '..\_shared\signature.ps1')
    . (Join-Path $PSScriptRoot '..\_shared\migration-mode.ps1')
    $subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'
    $sig = Get-NirvanaSignature

    $encRecipient = [System.Web.HttpUtility]::HtmlEncode($Recipient)
    $encMsg       = [System.Web.HttpUtility]::HtmlEncode($Message) -replace "`r?`n", '<br>'
    $kindLabel    = if ($IsGroup) { 'group' } else { '1:1' }

    $replyingBlock = ''
    if ($ReplyingTo) {
        $encReplying = [System.Web.HttpUtility]::HtmlEncode($ReplyingTo) -replace "`r?`n", '<br>'
        $replyingBlock = @"
<p style="margin:14px 0 4px 0;color:#666;font-size:90%;">Replying to:</p>
<div dir="rtl" lang="he" style="font-family:'Segoe UI','Arial Hebrew',Arial,sans-serif;border-left:3px solid #bbb;padding:6px 10px;background:#fafafa;color:#555;font-size:95%;">
$encReplying
</div>
"@
    }

    $jokeBlock = ''
    if (-not $NoJoke -and $Joke) {
        $encJoke = [System.Web.HttpUtility]::HtmlEncode($Joke)
        $jokeBlock = "<p style=`"color:#444;font-style:italic;margin-top:18px;`">$encJoke</p>"
    }

    $htmlBody = @"
<html>
<body style="font-family:'Segoe UI','Arial Hebrew',Arial,sans-serif;color:#222;">
<h2 style="margin:0 0 8px 0;">WhatsApp preview &mdash; review please</h2>
<p style="margin:0 0 6px 0;color:#444;">
<strong>To:</strong> $encRecipient <span style="color:#888;">[$kindLabel]</span>
</p>
$replyingBlock
<p style="margin:14px 0 4px 0;color:#666;font-size:90%;">Proposed message:</p>
<div dir="rtl" lang="he" style="font-family:'Segoe UI','Arial Hebrew',Arial,sans-serif;border-left:4px solid #25D366;padding:10px 14px;background:#f6fff8;line-height:1.5;">
$encMsg
</div>
<p style="margin-top:16px;color:#444;">Reply <code>send</code> in the agent CLI to confirm, or send a corrected version.</p>
$jokeBlock
$sig
</body>
</html>
"@

    $ol = New-Object -ComObject Outlook.Application
    $me = $ol.Session.CurrentUser
    try {
        $smtp = $me.AddressEntry.GetExchangeUser().PrimarySmtpAddress
    } catch {
        $smtp = $me.Address
    }
    $mail = $ol.CreateItem(0)
    $mail.To = $smtp
    $mail.Subject = "$subjectPrefix - WhatsApp preview $([char]0x2192) $Recipient $([char]0x2014) review"
    $mail.HTMLBody = $htmlBody
    if (Test-MigrationMode) {
        Write-Host "[migration-mode] Skipping preview email send to $smtp."
        return
    }
    $mail.Send()

    Write-Host "Preview email sent to $smtp."
}

