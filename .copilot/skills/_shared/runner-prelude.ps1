# Shared bootstrap dot-sourced by every run-*.ps1 runner.
#
# Purpose:
#   - Set $ErrorActionPreference and console encoding consistently.
#   - Discover the agent root (independent of where the runner was invoked from).
#   - Load config/agent.json once and stash it in the caller's scope.
#   - Set the working directory to the agent root so relative paths
#     (reports/logs, .copilot/skills/...) resolve identically across machines.
#
# Usage (from a runner):
#   . (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
#   # $AgentRoot, $AgentConfig, $LogDir are now available.
#
# Lazy-load policy:
#   $AgentConfig is loaded eagerly because runners need it to compose subjects,
#   recipients, and paths up-front. SHARED HELPERS (signature.ps1,
#   _runner-email.ps1, send-preview-email.ps1, etc.) MUST NOT depend on this
#   prelude or on $AgentConfig being set globally -- they self-bootstrap config
#   inside their function bodies. This invariant was set by Phase 5a's
#   rubber-duck critique and must be preserved.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'config.ps1')

$AgentRoot   = Resolve-AgentRoot
$AgentConfig = Get-AgentConfig
Set-Location $AgentRoot

# Convenience: every runner uses reports/logs/. Resolve once.
$LogDir = Resolve-AgentPath (Join-Path (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $AgentConfig) 'logs') -Config $AgentConfig
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null