# Changelog

All notable changes to the manager-agent-template.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0 -- Initial release

### Added

- **Onboarding triad**: `init.ps1` (interactive setup) + `doctor.ps1`
  (environment validator) + `smoke-test.ps1` (safe end-to-end check).
- **Config-driven runtime**: `config/agent.json` is the single source of
  truth for identity, manager identity, ADO/team scope, paths, locale,
  signature, voice, and feature flags. `_shared/config.ps1` exposes the
  helpers (`Resolve-AgentRoot`, `Get-AgentConfig`, `Get-AgentField`,
  `Resolve-AgentPath`).
- **Skills**:
  - `sprint-create`, `sprint-report-daily`, `pbi-assign-tasks`
  - `email-team`, `post-to-teams`
  - `agent-todos` (formerly `agent-todos`)
  - `codebase` (formerly `codebase`)
  - `team-personas`, `inbox-watch`, `team-milestones`, `whatsapp`
- **Personal examples**: `spouse-or-partner-template`, `pilates` -- copy-paste
  references under `examples/personal/`.
- **Voice profiles**: `examples/voice-profiles/nirvana-band.md` (band lyric
  bank) and `kusto-kql.md` (KQL vocabulary).
- **Mustache-lite renderer**: `_shared/render-template.ps1` for `{{ x.y.z }}`
  scalars and `{{# if x }}...{{/ if }}` blocks.
- **AGENTS.md from manifest**: rendered from `config/skills.json` via
  `_shared/render-agents.ps1`. Doctor verifies sync.
- **Migration-mode kill switch**: `config/migration-mode.txt` or
  `$env:AGENT_MIGRATION_MODE=1` blocks every `.Send()` site in runners.
- **Test harness**: 11 test files, ~240 tests under a custom Pester-style
  framework (`tests/_test-runner.ps1`, no Pester dependency). Includes
  characterization tests for the signature pipeline, runner-email composer,
  config helpers, runner-prelude, runners-bootstrap, render-template,
  AGENTS.md rendering, skills manifest, onboarding scripts, and snapshot
  build.
- **Snapshot tool**: `tools/build-snapshot.ps1` builds a clean public
  snapshot of the repo with PII substitution, sensitive content removal,
  skill renames, alias stubs, and a doctor verification pass.

### Skill rename aliases

- `agent-todos` -> `agent-todos` (alias stub kept for one release)
- `codebase` -> `codebase` (alias stub kept for one release)

Trigger phrases continue to work; please update direct path references in
runners and TODO files before the next major release drops the stubs.

### Security boundaries documented

- HR-grade data (performance check-ins, levels, comp) is forbidden from the
  repo and lives off-tree at `%USERPROFILE%/.copilot/connect-buddy/`.
- `team-personas` schema explicitly excludes level / promotion / comp fields.
- Snapshot tool excludes personas, reports, codebase maps, state files, and
  the `tools/` directory itself.


