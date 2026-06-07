# Tests for _shared/comms.ps1 (P3 additive channel-adapter).
# Pure registry/validation/compose logic only -- never calls .Send() / COM.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$commsPath = Join-Path $PSScriptRoot '..\.copilot\skills\_shared\comms.ps1'
. $commsPath

Describe 'comms.ps1 - channel registry' {
    It 'exposes the three known channels' {
        $names = @(Get-CommsChannels | ForEach-Object { $_.Name })
        Assert-Contains 'email' ($names -join ' ')
        Assert-Contains 'whatsapp' ($names -join ' ')
        Assert-Contains 'teams' ($names -join ' ')
    }
    It 'email is native, teams + whatsapp are agent-orchestrated' {
        Assert-Equal 'native' (Get-CommsChannelKind -Channel 'email')
        Assert-Equal 'agent-orchestrated' (Get-CommsChannelKind -Channel 'teams')
        Assert-Equal 'agent-orchestrated' (Get-CommsChannelKind -Channel 'whatsapp')
    }
    It 'is case-insensitive on channel name' {
        Assert-True (Test-CommsChannel -Channel 'EMAIL')
    }
    It 'rejects unknown channels' {
        Assert-False (Test-CommsChannel -Channel 'carrier-pigeon')
        Assert-True ($null -eq (Get-CommsChannelKind -Channel 'carrier-pigeon'))
    }
}

Describe 'comms.ps1 - Test-CommsRecipient' {
    It 'accepts a single valid email' {
        Assert-True (Test-CommsRecipient -Channel 'email' -To 'a@b.com')
    }
    It 'accepts a separated list of valid emails' {
        Assert-True (Test-CommsRecipient -Channel 'email' -To 'a@b.com; c@d.org, e@f.net')
    }
    It 'rejects a malformed email' {
        Assert-False (Test-CommsRecipient -Channel 'email' -To 'not-an-email')
    }
    It 'rejects a list containing one bad email' {
        Assert-False (Test-CommsRecipient -Channel 'email' -To 'a@b.com; nope')
    }
    It 'rejects blank' {
        Assert-False (Test-CommsRecipient -Channel 'email' -To '   ')
    }
    It 'allows free-form recipients for non-email channels' {
        Assert-True (Test-CommsRecipient -Channel 'whatsapp' -To 'Partner')
        Assert-True (Test-CommsRecipient -Channel 'teams' -To 'Your Team channel')
    }
}

Describe 'comms.ps1 - Build-CommsEmail' {
    It 'prefixes the subject and wraps the body + signature' {
        $m = Build-CommsEmail -To 'a@b.com' -Subject 'Hello' -BodyHtml '<p>hi</p>' -SubjectPrefix '[X]'
        Assert-Equal '[X] Hello' $m.Subject
        Assert-Match '<p>hi</p>' $m.HtmlBody
        Assert-Match '<html>' $m.HtmlBody
    }
    It 'omits the signature when -NoSignature is set' {
        $withSig = Build-CommsEmail -To 'a@b.com' -Subject 'S' -BodyHtml '<p>b</p>' -SubjectPrefix '[X]'
        $noSig   = Build-CommsEmail -To 'a@b.com' -Subject 'S' -BodyHtml '<p>b</p>' -SubjectPrefix '[X]' -NoSignature
        Assert-True ($noSig.HtmlBody.Length -lt $withSig.HtmlBody.Length)
    }
}

Describe 'comms.ps1 - Send-NirvanaMessage (no real send)' {
    It 'returns an error object for an unknown channel (never throws)' {
        $r = Send-NirvanaMessage -Channel 'pigeon' -To 'a@b.com' -Subject 'S' -BodyHtml '<p>b</p>'
        Assert-False ([bool]$r.Sent)
        Assert-Match 'unknown channel' $r.Error
    }
    It 'returns an error object for an invalid email recipient' {
        $r = Send-NirvanaMessage -Channel 'email' -To 'bad' -Subject 'S' -BodyHtml '<p>b</p>'
        Assert-False ([bool]$r.Sent)
        Assert-Match 'invalid recipient' $r.Error
    }
    It 'DryRun email composes without sending (Sent=true, Skipped=dry-run)' {
        $r = Send-NirvanaMessage -Channel 'email' -To 'a@b.com' -Subject 'S' -BodyHtml '<p>b</p>' -DryRun
        Assert-True ([bool]$r.Sent)
        Assert-Equal 'dry-run' $r.Skipped
    }
    It 'DryRun applies the subject prefix to the result' {
        $r = Send-NirvanaMessage -Channel 'email' -To 'a@b.com' -Subject 'S' -BodyHtml '<p>b</p>' -SubjectPrefix '[Z]' -DryRun
        Assert-Equal '[Z] S' $r.Subject
    }
    It 'agent-orchestrated channel DryRun is a compose-only success' {
        $r = Send-NirvanaMessage -Channel 'teams' -To 'channel' -Subject 'S' -BodyHtml '<p>b</p>' -DryRun
        Assert-True ([bool]$r.Sent)
        Assert-Equal 'agent-orchestrated' $r.Skipped
    }
    It 'agent-orchestrated channel real send is refused with guidance' {
        $r = Send-NirvanaMessage -Channel 'whatsapp' -To 'Partner' -Subject 'S' -BodyHtml '<p>b</p>'
        Assert-False ([bool]$r.Sent)
        Assert-Match 'agent-orchestrated' $r.Error
    }
}

Describe 'comms.ps1 - source guarantees' {
    $src = Get-Content -Raw -Path $commsPath
    It 'releases COM objects after the email send' {
        Assert-Match 'ReleaseComObject' $src
    }
    It 'gates the real send behind migration mode' {
        Assert-Match 'Test-MigrationMode' $src
    }
}

Exit-WithTestResults

