# Tests for the onboarding triad: init.ps1 / doctor.ps1 / smoke-test.ps1.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$initScript = Join-Path $repoRoot 'init.ps1'
$doctorScript  = Join-Path $repoRoot 'doctor.ps1'
$smokeScript   = Join-Path $repoRoot 'smoke-test.ps1'

Describe 'onboarding scripts exist' {
    It 'init.ps1 exists and parses' {
        Assert-True (Test-Path $initScript)
        $errors = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -Encoding UTF8 $initScript), [ref]$errors)
        Assert-True ($null -eq $errors -or $errors.Count -eq 0) -Because 'init.ps1 must parse'
    }

    It 'doctor.ps1 exists and parses' {
        Assert-True (Test-Path $doctorScript)
        $errors = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -Encoding UTF8 $doctorScript), [ref]$errors)
        Assert-True ($null -eq $errors -or $errors.Count -eq 0)
    }

    It 'smoke-test.ps1 exists and parses' {
        Assert-True (Test-Path $smokeScript)
        $errors = $null
        [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -Encoding UTF8 $smokeScript), [ref]$errors)
        Assert-True ($null -eq $errors -or $errors.Count -eq 0)
    }
}

Describe 'doctor.ps1 - source structure' {
    $content = Get-Content -Raw -Encoding UTF8 $doctorScript

    It 'supports -Root (snapshot mode) parameter' {
        Assert-Match '\[string\]\s+\$Root' $content
    }

    It 'supports -LeakDenylist parameter' {
        Assert-Match '\[string\[\]\]\s+\$LeakDenylist' $content
    }

    It 'gates literal-leak grep on snapshot mode' {
        Assert-Match '(?ms)if\s*\(\s*\$snapshotMode\s*\)' $content
    }

    It 'has a parse-check section' {
        Assert-Match 'PSParser.*Tokenize' $content
    }

    It 'invokes render-agents.ps1 -Check' {
        Assert-Match 'render-agents\.ps1' $content
        Assert-Match '-Check' $content
    }
}

Describe 'smoke-test.ps1 - source structure' {
    $content = Get-Content -Raw -Encoding UTF8 $smokeScript

    It 'invokes doctor.ps1' {
        Assert-Match 'doctor\.ps1' $content
    }

    It 'invokes the portable test runner (not run-all)' {
        Assert-Match 'run-portable\.ps1' $content
        Assert-NotMatch 'run-all\.ps1' $content
    }

    It 'composes Build-RunnerSummaryEmail (no .Send)' {
        Assert-Match 'Build-RunnerSummaryEmail' $content
        Assert-NotMatch '\$\w+\.Send\(\)' $content
    }
}

Describe 'init.ps1 - engine mode in a temp dir' {
    # Skip if Windows powershell.exe isn't on PATH (defensive)
    if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        It 'powershell.exe available' { Assert-True $false -Because 'powershell.exe not on PATH' }
        return
    }

    # Create a minimal sandbox: copy the bare files init.ps1 needs to render artifacts.
    $sandbox = Join-Path $env:TEMP ("init-test-" + [Guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    try {
        # Copy the engine surface
        $copies = @(
            'init.ps1',
            'doctor.ps1',
            '.copilot\skills\_shared\config.ps1',
            '.copilot\skills\_shared\render-template.ps1',
            '.copilot\skills\_shared\render-agents.ps1',
            'config\skills.json',
            'config\banner.txt',
            'templates\AGENTS.md.tmpl',
            'prompts\CUSTOM_INSTRUCTIONS.md.tmpl'
        )
        foreach ($c in $copies) {
            $src = Join-Path $repoRoot $c
            $dst = Join-Path $sandbox $c
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            Copy-Item $src $dst -Force
        }
        # Stub SKILL.md files for every entry in the manifest
        $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $sandbox 'config\skills.json') | ConvertFrom-Json
        foreach ($s in $manifest.skills) {
            if ($s.surface -eq 'local-only') { continue }
            $skillDir = Join-Path $sandbox $s.path
            New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
            Set-Content -Path (Join-Path $skillDir 'SKILL.md') -Value "# Stub for $($s.name)`n" -Encoding UTF8
            if ($s.entrypoint_path) {
                $epDir = Split-Path (Join-Path $sandbox $s.entrypoint_path) -Parent
                New-Item -ItemType Directory -Path $epDir -Force | Out-Null
                Set-Content -Path (Join-Path $sandbox $s.entrypoint_path) -Value "# stub`n" -Encoding UTF8
            }
        }
        # forwarder stub
        $fw = $manifest.skills | Where-Object { $_.surface -eq 'local-only' } | Select-Object -First 1
        if ($fw -and $fw.entrypoint_path) {
            $fwPath = Join-Path $sandbox $fw.entrypoint_path
            New-Item -ItemType Directory -Path (Split-Path $fwPath -Parent) -Force | Out-Null
            Set-Content -Path $fwPath -Value "# stub forwarder`n" -Encoding UTF8
        }

        # Write an answers JSON for engine mode
        $answers = [pscustomobject]@{
            agent_name      = 'TestBot'
            manager_first   = 'Alex'
            manager_full    = 'Alex Smith'
            manager_email   = 'alex@example.com'
            manager_alias   = 'asmith'
            ado_org         = 'contoso'
            ado_project     = 'engineering'
            team_name       = 'Platform Team'
            team_alias      = 'platform'
            reports_root    = 'reports'
            tasks_prefix    = 'PLT'
            banner_source   = 'skip'
            banner_file     = ''
            voice_profile   = 'none'
            voice_custom    = ''
            locale_language = 'en'
            locale_timezone = 'America/New_York'
            locale_tz_abbr  = 'ET'
            week_start      = 'Mon'
        }
        $answersPath = Join-Path $sandbox 'answers.json'
        $answers | ConvertTo-Json -Depth 4 | Set-Content -Path $answersPath -Encoding UTF8

        # Run init -ConfigFile -Force
        $sandboxInit = Join-Path $sandbox 'init.ps1'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sandboxInit -ConfigFile $answersPath -Force 2>&1
        $exit = $LASTEXITCODE

        It 'init.ps1 exits 0 on a clean sandbox' {
            Assert-Equal 0 $exit -Because "Output: $output"
        }

        It 'init.ps1 wrote config/agent.json with substituted values' {
            $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $sandbox 'config\agent.json') | ConvertFrom-Json
            Assert-Equal 'TestBot' $cfg.agent.name
            Assert-Equal 'Alex' $cfg.manager.first_name
            Assert-Equal 'Platform Team' $cfg.team.name
            Assert-Equal 'PLT' $cfg.tasks.prefix
        }

        It 'init.ps1 derives trigger_aliases and prefix from agent name' {
            $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $sandbox 'config\agent.json') | ConvertFrom-Json
            Assert-Equal '[TestBot]' $cfg.agent.mail_subject_prefix
            Assert-Equal 'TestBotProcessed' $cfg.agent.idempotency_tag
            Assert-True ($cfg.agent.trigger_aliases -contains 'testbot')
        }

        It 'init.ps1 rendered AGENTS.md with substituted values' {
            $agents = Get-Content -Raw -Encoding UTF8 (Join-Path $sandbox 'AGENTS.md')
            Assert-Match 'TestBot' $agents
            Assert-Match 'Alex' $agents
            Assert-Match 'Platform Team' $agents
            Assert-Match 'contoso' $agents
            # Identity-text leakage (manager identity), NOT skill-id names like 'codebase'.
            # Use case-sensitive (?-i) prefix because the snapshot substitutes these strings to
            # 'Your Team' / 'Your Name', which would case-insensitive-match the literal phrase
            # "Your name is **{{ agent.name }}**" in the template.
            Assert-NotMatch '(?-i)Your Team' $agents
            Assert-NotMatch '(?-i)Your Name' $agents
            Assert-NotMatch '(?-i)your-ado-org' $agents
        }

        It 'init.ps1 rendered prompts/CUSTOM_INSTRUCTIONS.md' {
            $ci = Get-Content -Raw -Encoding UTF8 (Join-Path $sandbox 'prompts\CUSTOM_INSTRUCTIONS.md')
            Assert-Match 'TestBot' $ci
            Assert-Match 'Alex' $ci
            Assert-NotMatch '(?-i)Your Team' $ci
            Assert-NotMatch '(?-i)Your Name' $ci
        }

        It 'doctor.ps1 passes against the rendered sandbox' {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox 'doctor.ps1') 2>&1
            Assert-Equal 0 $LASTEXITCODE -Because "Output: $out"
        }
    }
    finally {
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Exit-WithTestResults


