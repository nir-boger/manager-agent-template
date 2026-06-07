# Tests for the one-on-one-agenda skill (parser + matcher + manifest wiring).
#
# Covers:
#   - parser.ps1 is ASCII-only (PS 5.1 source-file constraint)
#   - Test-Is1on1MeetingForPerson positive + negative cases
#   - Get-PersonLabel reads the `# 1:1 agenda - <Person>` header
#   - Get-OneOnOneItems parses Your Manager.md (the seed file) cleanly
#   - The runner dot-sources parser.ps1 (no inline drift)
#   - The runner is ASCII-only
#   - add-item.py exists at the documented path
#   - Manifest entry has the expected wiring (entrypoint_path, category, etc.)

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\one-on-one-agenda'
$parserPs1  = Join-Path $skillDir 'parser.ps1'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$addItemPy  = Join-Path $skillDir 'add-item.py'
$runnerPs1  = Join-Path $repoRoot '.copilot\skills\run-one-on-one-agenda.ps1'
$tomerMd    = Join-Path $repoRoot 'reports\one-on-ones\Your Manager.md'
$manifest   = Join-Path $repoRoot 'config\skills.json'

if (-not (Test-Path $parserPs1)) { throw "parser.ps1 missing: $parserPs1" }
if (-not (Test-Path $skillMd))   { throw "SKILL.md missing: $skillMd" }
if (-not (Test-Path $addItemPy)) { throw "add-item.py missing: $addItemPy" }
if (-not (Test-Path $runnerPs1)) { throw "runner missing: $runnerPs1" }

. $parserPs1

$runnerText  = Get-Content $runnerPs1 -Raw -Encoding UTF8
$skillMdText = Get-Content $skillMd -Raw -Encoding UTF8

$manifestEntry = (Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).skills |
                 Where-Object { $_.name -eq 'one-on-one-agenda' }

Describe 'one-on-one-agenda parser.ps1' {

    It 'is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($parserPs1)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'exports Get-OneOnOneItems, Get-PersonLabel, Test-Is1on1MeetingForPerson' {
        Assert-True ($null -ne (Get-Command Get-OneOnOneItems         -ErrorAction SilentlyContinue))
        Assert-True ($null -ne (Get-Command Get-PersonLabel           -ErrorAction SilentlyContinue))
        Assert-True ($null -ne (Get-Command Test-Is1on1MeetingForPerson -ErrorAction SilentlyContinue))
    }
}

Describe 'Test-Is1on1MeetingForPerson - positive cases' {

    It 'matches Nir / Your Manager - 1x1' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'Nir / Your Manager - 1x1' -PersonToken 'Your Manager')
    }

    It 'matches Your Manager 1:1 (colon form)' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'Your Manager 1:1' -PersonToken 'Your Manager')
    }

    It 'matches VP <-> Nir 1on1 (1on1 form)' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'VP <-> Nir 1on1' -PersonToken 'VP')
    }

    It 'matches case-insensitively on the person token' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'NIR / Your Manager - 1X1' -PersonToken 'Your Manager')
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'nir / Your Manager - 1x1' -PersonToken 'Your Manager')
    }

    It 'matches 1-on-1 (hyphenated form)' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'Your Manager 1-on-1' -PersonToken 'Your Manager')
    }

    It 'matches one-on-one and one on one (long forms)' {
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'Your Manager one-on-one' -PersonToken 'Your Manager')
        Assert-True (Test-Is1on1MeetingForPerson -Subject 'Your Manager one on one' -PersonToken 'Your Manager')
    }
}

Describe 'Test-Is1on1MeetingForPerson - negative cases' {

    It 'rejects when person token missing' {
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Some other 1:1' -PersonToken 'Your Manager'))
    }

    It 'rejects when 1:1 indicator missing' {
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Your Manager farewell party' -PersonToken 'Your Manager'))
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Plan with Your Manager about Q3'  -PersonToken 'Your Manager'))
    }

    It 'rejects empty subject or empty person' {
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject ''                  -PersonToken 'Your Manager'))
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Nir / Your Manager - 1x1' -PersonToken ''))
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject ''                  -PersonToken ''))
    }

    It 'does not false-positive on 1x10, 11on11, etc.' {
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Your Manager 1x10 retro'    -PersonToken 'Your Manager'))
        Assert-True (-not (Test-Is1on1MeetingForPerson -Subject 'Your Manager 11on11 review' -PersonToken 'Your Manager'))
    }
}

Describe 'Get-PersonLabel + Get-OneOnOneItems on the seed file' {

    if (Test-Path $tomerMd) {

        It 'Get-PersonLabel reads "Your Manager" from the file header' {
            Assert-Equal 'Your Manager' (Get-PersonLabel -Path $tomerMd)
        }

        It 'Get-OneOnOneItems returns at least 2 open items with the expected IDs' {
            $items = Get-OneOnOneItems -Path $tomerMd
            $open  = @($items | Where-Object { $_.Section -eq 'open' })
            Assert-True ($open.Count -ge 2)
            $ids = ($open | ForEach-Object { $_.Id }) -join ','
            Assert-Match 'ON-001' $ids
            Assert-Match 'ON-002' $ids
        }

        It 'parses Kind/Status/OpenedBy fields on each open item' {
            $items = Get-OneOnOneItems -Path $tomerMd
            $open  = @($items | Where-Object { $_.Section -eq 'open' })
            foreach ($it in $open) {
                Assert-True (-not [string]::IsNullOrWhiteSpace($it.Kind))     "$($it.Id) missing Kind"
                Assert-True (-not [string]::IsNullOrWhiteSpace($it.Status))   "$($it.Id) missing Status"
                Assert-True (-not [string]::IsNullOrWhiteSpace($it.OpenedBy)) "$($it.Id) missing OpenedBy"
            }
        }
    }
    else {
        It 'Your Manager.md seed file exists' {
            Assert-True (Test-Path $tomerMd)
        }
    }
}

Describe 'runner wiring' {

    It 'runner is ASCII-only' {
        $bytes = [System.IO.File]::ReadAllBytes($runnerPs1)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'runner dot-sources parser.ps1 (no inline drift)' {
        Assert-Match 'parser\.ps1' $runnerText
    }

    It 'runner does NOT redefine Test-Is1on1MeetingForPerson inline' {
        $defs = ([regex]::Matches($runnerText, 'function\s+Test-Is1on1MeetingForPerson')).Count
        Assert-Equal 0 $defs "runner should not redefine Test-Is1on1MeetingForPerson; it lives in parser.ps1"
    }

    It 'runner acquires + releases a single-instance lock' {
        Assert-Match 'Acquire-Lock'  $runnerText
        Assert-Match 'Release-Lock'  $runnerText
    }

    It 'runner dot-sources team-agenda render.ps1 for the email body' {
        Assert-Match 'team-agenda' $runnerText
        Assert-Match "Join-Path\s+\`$teamAgendaDir\s+'render\.ps1'" $runnerText
        Assert-Match 'Render-TwoTableAgenda'    $runnerText
        Assert-Match 'Format-AgendaSubjectTail' $runnerText
    }
}

Describe 'manifest wiring' {

    It 'has a one-on-one-agenda entry' {
        Assert-True ($null -ne $manifestEntry)
    }

    It 'entrypoint_path points at the runner' {
        Assert-Equal '.copilot/skills/run-one-on-one-agenda.ps1' $manifestEntry.entrypoint_path
    }

    It 'category is cadence-memory' {
        Assert-Equal 'cadence-memory' $manifestEntry.category
    }

    It 'is shipped in the snapshot template' {
        Assert-True $manifestEntry.ship_in_snapshot
    }

    It 'is visible in AGENTS.md' {
        Assert-True $manifestEntry.show_in_agents
    }
}

Describe 'SKILL.md documents the runner' {

    It 'mentions DM-OneOnOneAgenda' {
        Assert-Match 'DM-OneOnOneAgenda' $skillMdText
    }

    It 'mentions the mandatory add-item.py helper' {
        Assert-Match 'add-item\.py' $skillMdText
    }
}

Exit-WithTestResults

