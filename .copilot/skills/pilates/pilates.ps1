# Forwarder stub for the pilates skill.
#
# In Phase 4 of the templatize-Nirvana refactor (2026-05-05), the pilates skill
# moved from `.copilot/skills/pilates/` to `examples/personal/pilates/` so it
# ships in the public manager-agent-template only as a personal-life example,
# not as an active engine skill.
#
# This forwarder lets the existing Windows scheduled tasks
# (DM-PilatesAuto-mon-10, DM-PilatesAuto-wed-10) keep working WITHOUT requiring
# re-registration. Both tasks invoke this exact path; the forwarder transparently
# delegates to the new location with all original arguments preserved.
#
# When this template is forked by another manager: this folder won't exist
# (only examples/personal/pilates/ ships). They'll register their own scheduled
# tasks pointing at examples/personal/pilates/pilates.ps1 directly.

[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]] $ForwardedArgs
)

$ErrorActionPreference = 'Stop'

$target = Join-Path $PSScriptRoot '..\..\..\examples\personal\pilates\pilates.ps1'
$target = [System.IO.Path]::GetFullPath($target)

if (-not (Test-Path $target)) {
    throw "Pilates forwarder: target '$target' not found. The skill may have moved again; check examples/personal/pilates/."
}

& $target @ForwardedArgs
exit $LASTEXITCODE
