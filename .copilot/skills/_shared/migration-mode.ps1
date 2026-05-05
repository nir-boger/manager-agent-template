# Single source of truth for the migration freeze flag.
#
# Purpose
#   During the "templatize Nirvana" refactor (Phase 5+), helpers that have
#   side effects (sending email, modifying ADO, registering scheduled tasks,
#   booking Pilates, posting to Teams) need a kill switch. This helper gives
#   them one without scattering env-var checks across every script.
#
# Activation - either method works
#   1. Create file: <repo-root>\config\migration-mode.txt (any content)
#   2. Set env var: $env:AGENT_MIGRATION_MODE = '1'  (or any non-zero value)
#      Backward-compat alias: $env:NIRVANA_MIGRATION_MODE.
#
# Deactivation
#   Delete the file and clear the env var. Both must be inactive for normal
#   operation to resume.
#
# Usage (from any helper or runner that has a side effect)
#   . (Join-Path $PSScriptRoot 'migration-mode.ps1')        # if in _shared/
#   if (Test-MigrationMode) {
#       Write-Host "Migration mode active - skipping side effects."
#       return $true   # or `exit 0` from a runner
#   }
#
# Test-only override
#   Tests can pass an explicit -ConfigRoot to point at a fixture directory,
#   so they don't have to mutate Nir's real <repo>\config.
#
# Note
#   `config/migration-mode.txt` is gitignored - this is a local-only flag,
#   never committed.

function Test-MigrationMode {
    [CmdletBinding()]
    param(
        # Optional override for tests. Defaults to <repo-root>\config relative
        # to this file (_shared\migration-mode.ps1 -> ..\..\..\config).
        [string] $ConfigRoot = (Join-Path $PSScriptRoot '..\..\..\config')
    )

    if ($env:AGENT_MIGRATION_MODE -and $env:AGENT_MIGRATION_MODE -ne '0') {
        return $true
    }
    if ($env:NIRVANA_MIGRATION_MODE -and $env:NIRVANA_MIGRATION_MODE -ne '0') {
        return $true
    }

    $flagPath = Join-Path $ConfigRoot 'migration-mode.txt'
    return (Test-Path $flagPath)
}

