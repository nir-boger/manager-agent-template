# Tests for team-agenda's two-table renderer and Kind-grouping logic.
#
# Verifies:
#   - render.ps1 exists and dot-sources cleanly
#   - Get-AgendaKind defaults missing/blank to 'discussion'
#   - Get-AgendaKind treats anything starting with 'follow' (any case) as 'follow-up'
#   - Render-TwoTableAgenda always emits both <h3> headings, even when one Kind is empty
#   - Format-AgendaSubjectTail produces the expected human-readable tails
#   - The current open-discussions.md has the Kind field on every open item
#   - Both runners' parsers capture the Kind field
#   - Both runners dot-source render.ps1 and use Format-AgendaSubjectTail in subject

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\team-agenda'
$renderPs1  = Join-Path $skillDir 'render.ps1'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$weeklyPs1  = Join-Path $repoRoot '.copilot\skills\run-team-agenda-reminder.ps1'
$meetingPs1 = Join-Path $repoRoot '.copilot\skills\run-team-meeting-reminder.ps1'
$agendaMd   = Join-Path $repoRoot 'reports\team-agenda\open-discussions.md'

if (-not (Test-Path $renderPs1))  { throw "render.ps1 missing: $renderPs1" }
if (-not (Test-Path $skillMd))    { throw "SKILL.md missing: $skillMd" }
if (-not (Test-Path $weeklyPs1))  { throw "Mon runner missing: $weeklyPs1" }
if (-not (Test-Path $meetingPs1)) { throw "pre-meeting runner missing: $meetingPs1" }
if (-not (Test-Path $agendaMd))   { throw "open-discussions.md missing: $agendaMd" }

. $renderPs1

$weeklyText  = Get-Content $weeklyPs1  -Raw -Encoding UTF8
$meetingText = Get-Content $meetingPs1 -Raw -Encoding UTF8
$agendaText  = Get-Content $agendaMd   -Raw -Encoding UTF8

Describe 'team-agenda render helpers' {

    It 'is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($renderPs1)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'Get-AgendaKind defaults missing field to discussion' {
        Assert-Equal 'discussion' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x' }))
    }

    It 'Get-AgendaKind treats blank Kind as discussion' {
        Assert-Equal 'discussion' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = '' }))
        Assert-Equal 'discussion' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = '   ' }))
    }

    It 'Get-AgendaKind matches Follow-up case-insensitively' {
        Assert-Equal 'follow-up' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = 'Follow-up' }))
        Assert-Equal 'follow-up' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = 'FOLLOW-UP' }))
        Assert-Equal 'follow-up' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = 'follow up' }))
        Assert-Equal 'follow-up' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = 'followup' }))
        Assert-Equal 'follow-up' (Get-AgendaKind ([pscustomobject]@{ Id = 'TA-001'; Title = 'x'; Kind = 'fu' }))
    }

    It 'Get-AgendaCounts splits items correctly' {
        $items = @(
            [pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Follow-up' },
            [pscustomobject]@{ Id='TA-002'; Title='b'; Kind='Discussion' },
            [pscustomobject]@{ Id='TA-003'; Title='c'; Kind='' },
            [pscustomobject]@{ Id='TA-004'; Title='d'; Kind='follow up' }
        )
        $c = Get-AgendaCounts -Items $items
        Assert-Equal 2 $c.Discuss
        Assert-Equal 2 $c.FollowUp
        Assert-Equal 4 $c.Total
    }

    It 'Format-AgendaSubjectTail handles plural follow-ups and singular discuss' {
        $items = @(
            [pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Follow-up' },
            [pscustomobject]@{ Id='TA-002'; Title='b'; Kind='Follow-up' },
            [pscustomobject]@{ Id='TA-003'; Title='c'; Kind='Discussion' }
        )
        Assert-Equal '2 follow-ups, 1 to discuss' (Format-AgendaSubjectTail -Items $items)
    }

    It 'Format-AgendaSubjectTail handles only discussion' {
        $items = @([pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Discussion' })
        Assert-Equal '1 to discuss' (Format-AgendaSubjectTail -Items $items)
    }

    It 'Format-AgendaSubjectTail handles only follow-up (singular)' {
        $items = @([pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Follow-up' })
        Assert-Equal '1 follow-up' (Format-AgendaSubjectTail -Items $items)
    }

    It 'Format-AgendaSubjectTail returns nothing-tracked on empty list' {
        Assert-Equal 'nothing tracked' (Format-AgendaSubjectTail -Items @())
    }

    It 'Render-TwoTableAgenda emits both headings even when one Kind is empty' {
        $only = @([pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Discussion' })
        $html = Render-TwoTableAgenda -Items $only
        Assert-Match 'Things to discuss \(1\)' $html
        Assert-Match 'Follow-ups \(0\)'        $html
        # Empty Kind must render the empty-state italic line, not an empty table.
        Assert-Match 'No follow-ups outstanding' $html
    }

    It 'Render-TwoTableAgenda renders both tables when both Kinds present' {
        $both = @(
            [pscustomobject]@{ Id='TA-001'; Title='a'; Kind='Follow-up' ; OpenedBy='Nir'; OpenedOn='2026-05-01'; Summary='s'; NextStep='n' },
            [pscustomobject]@{ Id='TA-002'; Title='b'; Kind='Discussion'; OpenedBy='Ron'; OpenedOn='2026-05-02'; Summary='s'; NextStep='n' }
        )
        $html = Render-TwoTableAgenda -Items $both
        Assert-Match '<table'        $html
        Assert-Match 'TA-001'        $html
        Assert-Match 'TA-002'        $html
        Assert-Match 'Things to discuss \(1\)' $html
        Assert-Match 'Follow-ups \(1\)'        $html
    }

    It 'Render-AgendaTable escapes generics in titles (<T> -> &lt;T&gt;)' {
        $items = @([pscustomobject]@{ Id='TA-001'; Title='Prefer `IReadOnlyCollection<T>`'; Kind='Discussion' })
        $html = Render-TwoTableAgenda -Items $items
        Assert-Match 'IReadOnlyCollection&lt;T&gt;' $html
        Assert-NotMatch 'IReadOnlyCollection<T>'    $html
    }
}

Describe 'open-discussions.md uses the Kind field' {

    It 'every Open item has a Kind field' {
        $sections = [regex]::Split($agendaText, '(?=^###\s+TA-\d{3}\b)', 'Multiline')
        $taSections = @($sections | Where-Object { $_ -match '^###\s+TA-\d{3}\b' })
        Assert-True ($taSections.Count -ge 1) "expected at least one TA-NNN section"
        foreach ($s in $taSections) {
            # Only check items in ## Open (TA-NNN under ## Closed will appear later).
            # Naive heuristic: every TA in the file currently lives under ## Open.
            Assert-Match '\*\*Kind:\*\*\s+(Discussion|Follow-up)' $s
        }
    }
}

Describe 'runners capture the Kind field' {

    It 'Mon runner switch includes the kind branch' {
        Assert-Match "'kind'\s*\{\s*\`$current\.Kind" $weeklyText
    }

    It 'Pre-meeting runner switch includes the kind branch' {
        Assert-Match "'kind'\s*\{\s*\`$current\.Kind" $meetingText
    }

    It 'Mon runner dot-sources the shared renderer' {
        Assert-Match "render\.ps1"             $weeklyText
        Assert-Match 'Render-TwoTableAgenda'   $weeklyText
        Assert-Match 'Format-AgendaSubjectTail' $weeklyText
    }

    It 'Pre-meeting runner dot-sources the shared renderer' {
        Assert-Match "render\.ps1"             $meetingText
        Assert-Match 'Render-TwoTableAgenda'   $meetingText
        Assert-Match 'Format-AgendaSubjectTail' $meetingText
    }
}

Exit-WithTestResults
