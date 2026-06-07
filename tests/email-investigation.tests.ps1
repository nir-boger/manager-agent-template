# Tests for the investigation-email renderer (_shared/investigation-email.ps1)
# and the email-investigation skill (config + SKILL.md presence).

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$rendererPs = Join-Path $repoRoot '.copilot\skills\_shared\investigation-email.ps1'
$skillDir   = Join-Path $repoRoot '.copilot\skills\email-investigation'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$manifest   = Join-Path $repoRoot 'config\skills.json'

if (-not (Test-Path $rendererPs)) { throw "renderer missing: $rendererPs" }
if (-not (Test-Path $skillMd))    { throw "SKILL.md missing: $skillMd" }
if (-not (Test-Path $manifest))   { throw "skills.json missing: $manifest" }

. $rendererPs

$manifestObj = Get-Content -Raw -Encoding UTF8 $manifest | ConvertFrom-Json
$skillEntry  = $manifestObj.skills | Where-Object { $_.name -eq 'email-investigation' } | Select-Object -First 1

Describe 'investigation-email renderer - source hygiene' {

    It 'renderer file is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($rendererPs)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'exposes Build-InvestigationEmailHtml as a function' {
        $cmd = Get-Command Build-InvestigationEmailHtml -ErrorAction SilentlyContinue
        Assert-True ($null -ne $cmd)
    }

    It 'exposes the tone map and palette helpers' {
        Assert-True ($null -ne (Get-Command Get-InvEmailTone     -ErrorAction SilentlyContinue))
        Assert-True ($null -ne (Get-Command Get-InvEmailPalette  -ErrorAction SilentlyContinue))
    }
}

Describe 'investigation-email renderer - schema enforcement' {

    It 'throws when Spec.Title is missing' {
        $threw = $false
        try { Build-InvestigationEmailHtml -Spec @{} | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Spec.Title is required'
    }

    It 'throws when a Section is missing BodyHtml' {
        $spec = @{ Title = 'X'; Sections = @( @{ Title = 'a' } ) }
        $threw = $false
        try { Build-InvestigationEmailHtml -Spec $spec | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Section without BodyHtml must throw'
    }

    It 'throws when a Recommendation is missing Title' {
        $spec = @{ Title = 'X'; Recommendations = @( @{ BodyHtml = 'body' } ) }
        $threw = $false
        try { Build-InvestigationEmailHtml -Spec $spec | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Recommendation without Title must throw'
    }
}

Describe 'investigation-email renderer - tone mapping' {

    It 'maps known tone names case-insensitively' {
        $bad   = Get-InvEmailTone -Tone 'bad'
        $BAD   = Get-InvEmailTone -Tone 'BAD'
        Assert-Equal $bad.fg $BAD.fg
        Assert-Equal '#b42318' $bad.fg
    }

    It 'falls back to neutral for unknown tones' {
        $u = Get-InvEmailTone -Tone 'pumpkin'
        $n = Get-InvEmailTone -Tone 'neutral'
        Assert-Equal $n.fg $u.fg
    }

    It 'maps hero chip tones with dark-on-dark colors' {
        $heroMap = $script:InvEmailHeroChipMap
        $bad = $heroMap['bad']
        Assert-Equal '#5c1e1e' $bad.bg -Because 'hero bad chip should use the dark red background'
        Assert-Equal '#ffd0c5' $bad.fg
    }
}

Describe 'investigation-email renderer - minimal happy path' {

    $html = Build-InvestigationEmailHtml -Spec @{
        Title = 'Smoke test'
        Tldr  = '<strong>It works.</strong>'
    }

    It 'emits a complete html document' {
        Assert-Contains '<html>' $html
        Assert-Contains '</body></html>' $html
    }

    It 'includes the title in the hero' {
        Assert-Contains 'Smoke test' $html
    }

    It 'renders the eyebrow as "Investigation" by default' {
        Assert-Contains 'Investigation' $html
    }

    It 'renders the TL;DR card with the eyebrow label' {
        Assert-Contains 'TL;DR' $html
        Assert-Contains 'It works.' $html
    }

    It 'uses the Clawpilot accent purple' {
        Assert-Contains '#6e40c9' $html
    }

    It 'gives the hero no background panel at all (transparent, no dark/purple banner)' {
        Assert-Contains 'background:transparent' $html
        if ($html -match '#1b1230') { throw "hero should not use the dark purple background #1b1230" }
    }
}

Describe 'investigation-email renderer - full spec' {

    $spec = @{
        Title    = 'Full spec test'
        Eyebrow  = 'Post-mortem'
        Subtitle = 'Lede with <strong>bold</strong>.'
        Chips    = @(
            @{ Label = '2026-04-20'; Tone = 'neutral' }
            @{ Label = '2 BAD';      Tone = 'bad'     }
            @{ Label = '55 OK';      Tone = 'good'    }
            @{ Label = 'WARN';       Tone = 'warn'    }
        )
        Tldr  = 'Tl;dr body'
        Stats = @(
            @{ Label = 'Broken'; Value = '2';    Sublabel = 'D&K';      Tone = 'bad'  }
            @{ Label = 'Calls';  Value = '3055'; Sublabel = 'all fail'; Tone = 'bad'  }
            @{ Label = 'OK';     Value = '55';   Sublabel = 'peers';    Tone = 'good' }
            @{ Label = 'Share';  Value = '3.5%'; Sublabel = 'traffic';  Tone = 'warn' }
        )
        Sections = @(
            @{ Title = 'Data'; BodyHtml = '<p>data here</p>'; Callout = @{ Tone = 'accent'; Html = '<strong>Punchline.</strong>' } }
            @{ Title = 'Why';  BodyHtml = '<ol><li>one</li></ol>' }
        )
        Recommendations = @(
            @{ Priority = 'P0'; Tone = 'bad';    Title = 'Do thing 1'; BodyHtml = 'now' }
            @{ Priority = 'PBI'; Tone = 'accent'; Title = 'Do thing 2'; BodyHtml = 'later' }
        )
        Joke = 'A funny line.'
    }

    $html = Build-InvestigationEmailHtml -Spec $spec

    It 'renders the custom eyebrow when provided' {
        Assert-Contains 'Post-mortem' $html
    }

    It 'renders all four chips' {
        Assert-Contains '2 BAD' $html
        Assert-Contains '55 OK' $html
        Assert-Contains 'WARN'  $html
    }

    It 'renders the stat values' {
        Assert-Contains '3055' $html
        Assert-Contains '3.5%' $html
    }

    It 'renders section titles and callout' {
        Assert-Contains 'Data' $html
        Assert-Contains 'Why'  $html
        Assert-Contains 'Punchline.' $html
    }

    It 'numbers recommendation cards starting at 1' {
        Assert-Contains '>1<' $html
        Assert-Contains '>2<' $html
        Assert-Contains 'Do thing 1' $html
        Assert-Contains 'Do thing 2' $html
    }

    It 'renders priority badges' {
        Assert-Contains 'P0' $html
        Assert-Contains 'PBI' $html
    }

    It 'renders the joke as italic muted text' {
        Assert-Contains 'A funny line.' $html
        Assert-Contains 'font-style:italic' $html
    }

    It 'does not include the Nirvana signature (caller appends it)' {
        Assert-NotContains "Sent on Nir" $html
    }

    It 'does not include a horizontal rule (signature owns the hr)' {
        Assert-NotContains '<hr>' $html
    }
}

Describe 'investigation-email renderer - omissions are clean' {

    It 'omits the TL;DR block when Tldr is absent' {
        $html = Build-InvestigationEmailHtml -Spec @{ Title = 'x'; Sections = @( @{ Title = 's'; BodyHtml = 'b' } ) }
        Assert-NotContains 'TL;DR' $html
    }

    It 'omits the stats row when Stats is absent or empty' {
        $html = Build-InvestigationEmailHtml -Spec @{ Title = 'x'; Tldr = 'y' }
        Assert-NotContains 'background:#ffffff;border:1px solid #e2e1ec;"><tr><td style="padding:16px;font-family' $html
    }

    It 'omits the chips row when Chips is absent' {
        $html = Build-InvestigationEmailHtml -Spec @{ Title = 'x'; Tldr = 'y' }
        Assert-NotContains 'margin-top:14px;"><span style="display:inline-block;background:#3a2864' $html
    }

    It 'omits the joke when Joke is absent' {
        $html = Build-InvestigationEmailHtml -Spec @{ Title = 'x'; Tldr = 'y' }
        Assert-NotContains 'font-style:italic' $html
    }

    It 'omits the recommendations card when Recommendations is absent' {
        $html = Build-InvestigationEmailHtml -Spec @{ Title = 'x'; Tldr = 'y' }
        Assert-NotContains 'Recommendations' $html
    }
}

Describe 'email-investigation skill - manifest + docs' {

    It 'is registered in config/skills.json' {
        Assert-True ($null -ne $skillEntry) -Because "expected an 'email-investigation' entry in skills.json"
    }

    It 'sits in the comms category' {
        Assert-Equal 'comms' $skillEntry.category
    }

    It 'is engine-tier and shipped' {
        Assert-Equal 'engine' $skillEntry.surface
        Assert-True $skillEntry.show_in_agents
        Assert-True $skillEntry.ship_in_snapshot
    }

    It 'has no separate runner (entrypoint_path is null)' {
        Assert-True ($null -eq $skillEntry.entrypoint_path) -Because 'SKILL.md-only skill, agent inline-executes'
    }

    It 'declares a useful set of trigger phrases' {
        $joined = ($skillEntry.triggers -join ' | ').ToLowerInvariant()
        Assert-Contains 'investigation' $joined
        Assert-Contains 'fancy ui'       $joined
        Assert-Contains 'rca'            $joined
    }

    It 'SKILL.md documents the worked example' {
        $md = Get-Content -Raw -Encoding UTF8 $skillMd
        Assert-Contains 'Build-InvestigationEmailHtml' $md
        Assert-Contains '_shared\investigation-email.ps1' $md
        Assert-Contains 'KvcIngestMonitorJob' $md
    }

    It 'SKILL.md tells the agent to honor NOJOKE / NOSIG' {
        $md = Get-Content -Raw -Encoding UTF8 $skillMd
        Assert-Contains 'NOSIG'  $md
        Assert-Contains 'NOJOKE' $md
    }
}

Exit-WithTestResults
