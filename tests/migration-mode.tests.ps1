# Tests for _shared/migration-mode.ps1.

. (Join-Path $PSScriptRoot '_test-runner.ps1')
. (Join-Path $PSScriptRoot '..\.copilot\skills\_shared\migration-mode.ps1')

Describe 'Test-MigrationMode' {

    # Use a per-suite temp dir as a fake config root so we never touch Nir's
    # real config\ directory.
    $script:fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nirvana-mig-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:fakeRoot -Force | Out-Null

    It 'returns $false when env var is unset and flag file does not exist' {
        Remove-Item Env:NIRVANA_MIGRATION_MODE -ErrorAction SilentlyContinue
        Assert-False (Test-MigrationMode -ConfigRoot $script:fakeRoot)
    }

    It 'returns $true when flag file exists' {
        $flag = Join-Path $script:fakeRoot 'migration-mode.txt'
        'frozen' | Set-Content -Path $flag -Encoding UTF8
        try {
            Assert-True (Test-MigrationMode -ConfigRoot $script:fakeRoot)
        } finally {
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $true when AGENT_MIGRATION_MODE env var is set to "1" (canonical)' {
        $env:AGENT_MIGRATION_MODE = '1'
        try {
            Assert-True (Test-MigrationMode -ConfigRoot $script:fakeRoot)
        } finally {
            Remove-Item Env:AGENT_MIGRATION_MODE -ErrorAction SilentlyContinue
        }
    }

    It 'returns $true when env var is set to "1"' {
        $env:NIRVANA_MIGRATION_MODE = '1'
        try {
            Assert-True (Test-MigrationMode -ConfigRoot $script:fakeRoot)
        } finally {
            Remove-Item Env:NIRVANA_MIGRATION_MODE -ErrorAction SilentlyContinue
        }
    }

    It 'returns $true when env var is any non-zero string' {
        $env:NIRVANA_MIGRATION_MODE = 'yes'
        try {
            Assert-True (Test-MigrationMode -ConfigRoot $script:fakeRoot)
        } finally {
            Remove-Item Env:NIRVANA_MIGRATION_MODE -ErrorAction SilentlyContinue
        }
    }

    It 'returns $false when env var is exactly "0"' {
        $env:NIRVANA_MIGRATION_MODE = '0'
        try {
            Assert-False (Test-MigrationMode -ConfigRoot $script:fakeRoot)
        } finally {
            Remove-Item Env:NIRVANA_MIGRATION_MODE -ErrorAction SilentlyContinue
        }
    }

    # Cleanup the temp dir at the very end.
    Remove-Item $script:fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Exit-WithTestResults
