# Single source of truth for the agent's email signature.
#
# Usage (dot-source from any runner / skill helper):
#   . 'c:\...\_shared\signature.ps1'
#   $sig = Get-NirvanaSignature                      # default user-facing
#   $sig = Get-NirvanaSignature -Variant InboxAuto   # auto-replies (adds disclosure)
#   $sig = Get-NirvanaSignature -Variant RunnerHeartbeat -RunnerName 'DailySummary import'
#   $sig = Get-NirvanaSignature -NoSig               # honors NOSIG -> returns ''
#   $sig = Get-NirvanaSignature -NoNotice            # suppress the optional notice line
#
# Wording is config-driven (see config/agent.json):
#   manager.first_name                       -> "Nir"  (Nir's install)
#   agent.name                               -> "Nirvana"
#   signature.auto_reply_disclosure          -> "{first} is on the thread; reply directly if I got it wrong."
#   signature.whatsapp_group_signature_he    -> "- נירוונה, הסוכן של ניר" (Hebrew literal; empty in template defaults)
#   signature.brand_html                     -> optional HTML override for the agent brand line
#                                              (default: bold the manager's first name as a prefix
#                                              of the agent name when it starts with it; e.g. Nir + Nirvana
#                                              -> <strong>Nir</strong>vana). Empty = use auto-detect.
#   signature.notice_path                    -> optional file with a one-line announcement
#                                              (default: config/signature-notice.txt, relative to agent root)
#
# For Nir's agent.json the default variant produces the canonical wording:
#   "Sent on Nir's behalf by <strong>Nir</strong>vana &mdash; Nir's agent."
#
# Notice mechanism
#   The notice file holds an OPTIONAL one-line announcement. When non-empty,
#   every signature gets it as a small footer paragraph. Empty/whitespace-only
#   file = no notice. Edit that file to change/disable the notice in one place.

# Self-bootstrap config helper. Idempotent dot-source; safe to dot-source many times.
. (Join-Path $PSScriptRoot 'config.ps1')

function _Format-AgentBrand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AgentName,
        [Parameter(Mandatory)] [string] $FirstName,
        # Optional explicit HTML override from config. When non-empty, returned as-is.
        [string] $BrandHtml
    )
    if (-not [string]::IsNullOrWhiteSpace($BrandHtml)) { return $BrandHtml }
    if ([string]::IsNullOrWhiteSpace($FirstName))      { return "<strong>$AgentName</strong>" }
    if ($AgentName.StartsWith($FirstName, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Preserve the casing of the agent name's prefix segment.
        $prefix = $AgentName.Substring(0, $FirstName.Length)
        $rest   = $AgentName.Substring($FirstName.Length)
        return "<strong>$prefix</strong>$rest"
    }
    return "<strong>$AgentName</strong>"
}

function _Resolve-NoticePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Config)
    $rel = Get-AgentField -Path 'signature.notice_path' -Config $Config -Default 'config/signature-notice.txt'
    if (-not $rel) { return $null }
    return Resolve-AgentPath -Path $rel -Config $Config
}

function Get-NirvanaSignature {
    [CmdletBinding()]
    param(
        [ValidateSet('Default', 'InboxAuto', 'RunnerHeartbeat')]
        [string] $Variant = 'Default',

        # Used only by the RunnerHeartbeat variant - identifies which runner sent the email.
        [string] $RunnerName,

        # When set, returns an empty string. Honors the global NOSIG override.
        [switch] $NoSig,

        # When set, omits the optional notice line even if the notice file has content.
        [switch] $NoNotice
    )

    if ($NoSig) { return '' }

    $cfg          = Get-AgentConfig
    $first        = Get-AgentField -Path 'manager.first_name'                   -Config $cfg -Default 'Manager'
    $agentName    = Get-AgentField -Path 'agent.name'                           -Config $cfg -Default 'Agent'
    $brandOverride= Get-AgentField -Path 'signature.brand_html'                 -Config $cfg -Default ''
    $disclosure   = Get-AgentField -Path 'signature.auto_reply_disclosure'      -Config $cfg -Default '{first} is on the thread; reply directly if I got it wrong.'
    $tzAbbr       = Get-AgentField -Path 'locale.timezone_abbreviation'         -Config $cfg -Default ''

    $brand = _Format-AgentBrand -AgentName $agentName -FirstName $first -BrandHtml $brandOverride
    $disclosure = $disclosure -replace '\{first\}', $first

    switch ($Variant) {
        'InboxAuto' {
            $coreLine = "Sent on $first's behalf by $brand &mdash; $first's agent. $disclosure"
        }
        'RunnerHeartbeat' {
            $stamp  = Get-Date -Format 'yyyy-MM-dd HH:mm'
            $tzPart = if ($tzAbbr) { " $tzAbbr" } else { '' }
            $src    = if ([string]::IsNullOrWhiteSpace($RunnerName)) { '' } else { " Source: <code>$RunnerName</code> on $stamp$tzPart." }
            $coreLine = "Automated heartbeat from $brand &mdash; $first's agent.$src"
        }
        default {
            $coreLine = "Sent on $first's behalf by $brand &mdash; $first's agent."
        }
    }

    $sig = "<hr><p style=`"color:#666;`"><em>$coreLine</em></p>"

    if (-not $NoNotice) {
        $noticePath = _Resolve-NoticePath -Config $cfg
        if ($noticePath -and (Test-Path $noticePath)) {
            $notice = (Get-Content $noticePath -Raw -Encoding UTF8).Trim()
            $lines  = $notice -split "`r?`n"
            $body   = ($lines | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join ' '
            $body   = $body.Trim()
            if ($body) {
                $sig += "<p style=`"color:#666;font-size:90%;margin-top:4px;`"><em>&#128226; $body</em></p>"
            }
        }
    }

    return $sig
}

# Convenience: also expose the canonical core text without HTML, for skills that need plain text.
# WhatsAppGroupHe is the Hebrew plain-text variant used by the `whatsapp` skill in the
# Your Team Group group (mandatory there; nowhere else on WhatsApp).
function Get-NirvanaSignatureText {
    [CmdletBinding()]
    param(
        [ValidateSet('Default', 'InboxAuto', 'WhatsAppGroupHe')]
        [string] $Variant = 'Default'
    )

    $cfg        = Get-AgentConfig
    $first      = Get-AgentField -Path 'manager.first_name'              -Config $cfg -Default 'Manager'
    $agentName  = Get-AgentField -Path 'agent.name'                      -Config $cfg -Default 'Agent'
    $disclosure = Get-AgentField -Path 'signature.auto_reply_disclosure' -Config $cfg -Default '{first} is on the thread; reply directly if I got it wrong.'
    $disclosure = $disclosure -replace '\{first\}', $first

    switch ($Variant) {
        'InboxAuto'       { "Sent on $first's behalf by $agentName - $first's agent. $disclosure" }
        'WhatsAppGroupHe' { Get-AgentField -Path 'signature.whatsapp_group_signature_he' -Config $cfg -Default '' }
        default           { "Sent on $first's behalf by $agentName - $first's agent." }
    }
}
