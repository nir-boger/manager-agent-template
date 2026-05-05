# Tests for config/skills.json — the single source of truth for AGENTS.md.
# Phase 6 added this manifest.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot     = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $repoRoot 'config\skills.json'

Describe 'config/skills.json - manifest schema' {

    It 'exists and parses as JSON' {
        Assert-True (Test-Path $manifestPath)
        $raw = Get-Content -Raw -Encoding UTF8 $manifestPath
        $parsed = $raw | ConvertFrom-Json
        Assert-True ($null -ne $parsed.skills)
        Assert-True ($parsed.skills.Count -gt 0)
    }

    $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json

    foreach ($s in $manifest.skills) {
        $name = $s.name

        It "$name has a non-empty name" {
            Assert-True (-not [string]::IsNullOrEmpty($s.name))
        }

        It "$name has a valid surface tier" {
            $valid = @('engine','example','local-only')
            Assert-True ($valid -contains $s.surface) -Because "surface='$($s.surface)' must be one of: $($valid -join ', ')"
        }

        It "$name has a path that exists in the repo" {
            $path = Join-Path $repoRoot $s.path
            Assert-True (Test-Path $path) -Because "skill path '$($s.path)' must exist"
        }

        if ($s.surface -ne 'local-only') {
            It "$name has a SKILL.md at its declared path" {
                $skillMd = Join-Path (Join-Path $repoRoot $s.path) 'SKILL.md'
                Assert-True (Test-Path $skillMd) -Because "SKILL.md at '$($s.path)' must exist"
            }
        }

        It "$name has show_in_agents and ship_in_snapshot booleans" {
            Assert-True ($s.show_in_agents -is [bool]) -Because 'show_in_agents must be bool'
            Assert-True ($s.ship_in_snapshot -is [bool]) -Because 'ship_in_snapshot must be bool'
        }

        if ($s.entrypoint_path) {
            It "$name entrypoint_path exists" {
                $ep = Join-Path $repoRoot $s.entrypoint_path
                Assert-True (Test-Path $ep) -Because "entrypoint '$($s.entrypoint_path)' must exist"
            }
        }
    }

    It 'has at least one engine-tier skill' {
        $engines = $manifest.skills | Where-Object { $_.surface -eq 'engine' }
        Assert-True ($engines.Count -gt 0)
    }

    It 'enforces unique skill names' {
        $names = $manifest.skills | ForEach-Object { $_.name }
        $unique = $names | Select-Object -Unique
        Assert-Equal $names.Count $unique.Count
    }
}

Exit-WithTestResults
