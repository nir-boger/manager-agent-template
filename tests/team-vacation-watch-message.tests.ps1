# Tests for team-vacation-watch welcome-back message composer.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\team-vacation-watch-message.tests.ps1

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$skillDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.copilot\skills\team-vacation-watch'
$composer = Join-Path $skillDir 'welcome-message.ps1'
. $composer

Describe 'Build-WelcomeBackMessage' {
    It 'contains the first name and waving hand entity' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacDays $null -Highlights @()
        Assert-Match 'Oz' $html
        Assert-Match '&#128075;' $html
    }

    It 'uses short-break phrasing for one vacation day' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacStart '2026-06-01' -VacEnd '2026-06-01' -VacDays 1 -Highlights @()
        Assert-Match 'quick' $html
    }

    It 'uses a long qualitative phrase (no dates) for a long vacation' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacStart '2026-05-20' -VacEnd '2026-06-06' -VacDays 18 -Highlights @()
        Assert-Match 'long stretch off' $html
        Assert-NotMatch '2026-05-20' $html
        Assert-NotMatch '2026-06-06' $html
    }

    It 'renders escaped while-you-were-out highlights as a list' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacDays 5 -Highlights @('Shipped X & Y','Merged PR <123>')
        Assert-Match 'While you were out' $html
        Assert-Match '<ul>' $html
        Assert-Match 'Shipped X &amp; Y' $html
        Assert-Match 'Merged PR &lt;123&gt;' $html
    }

    It 'uses a generic catch-up line without a list when highlights are empty' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacDays 5 -Highlights @()
        Assert-Equal $false ($html.Contains('<ul'))
        Assert-Match 'catch-up' $html
    }

    It 'is unsigned and not wrapped with a bracketed subject' {
        $html = Build-WelcomeBackMessage -FirstName 'Oz' -VacDays 5 -Highlights @('Merged PR 123')
        Assert-Equal $false ($html.Contains('Nirvana'))
        Assert-Equal $false ($html.Contains('[NirvanaTeams'))
    }
}

Exit-WithTestResults
