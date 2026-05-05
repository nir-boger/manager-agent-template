# config/

Runtime configuration for the Nirvana agent. Files here are read by the
engine's shared helpers (`.copilot/skills/_shared/*`) and by individual
skills at execution time.

## Files

| File | Purpose | Status |
|---|---|---|
| `agent.json` | **Source of truth for agent identity, manager identity, ADO scope, paths, locale, signature wording, voice profile, and feature flags.** Read by `_shared/config.ps1` (`Get-AgentField -Path 'manager.email'`, etc.). | Live as of Phase 5a. |
| `signature-notice.txt` | Optional one-line announcement appended to every signature (e.g. OOO heads-up, event invite). Path is configurable via `signature.notice_path` in `agent.json`. | Live (moved here from `_shared/` in Phase 5a). |
| `whatsapp-profiles.md` | Per-recipient WhatsApp profile rules (voice, joke policy, signature policy, auto-send carve-outs). Forward-looking; Phase 6 will move the operational rules from `whatsapp/SKILL.md` into here. | Documents Nir's current rules; SKILL.md is still operational truth. |
| `migration-mode.txt` | **Local-only kill switch.** When this file exists (any content), `_shared/migration-mode.ps1`'s `Test-MigrationMode` returns `$true` and side-effect helpers (e.g. `Send-RunnerSummaryEmail`) skip COM calls. Used during the templatize-Nirvana refactor. The env var `AGENT_MIGRATION_MODE=1` (or legacy `NIRVANA_MIGRATION_MODE=1`) does the same job process-locally. | Gitignored. Not present by default. |

## Path semantics (Phase 5a)

`agent.json` paths follow these rules; `Resolve-AgentPath` (in
`_shared/config.ps1`) handles all three:

- **Repo-local** paths use forward-slash relative form (`reports`,
  `.copilot/skills/team-personas/people`). Resolved against the agent root
  (the directory containing `config/agent.json`).
- **External** paths use `%ENVVAR%/...` form
  (`%USERPROFILE%/.copilot/connect-buddy`). `%ENVVAR%` is expanded via
  `[Environment]::ExpandEnvironmentVariables`.
- **Absolute** paths are returned as-is (after env-var expansion).

The agent root is **not** stored in `agent.json` — it is derived from the
config file's location at load time. This keeps `agent.json` portable when
the repo is moved or cloned.

## Future additions (Phase 5b / 6+)

- `voice.md` — manager-chosen humor profile (Phase 7).
- `whatsapp-profiles.md` becomes the operational source for WhatsApp
  per-recipient rules (Phase 6).

## Conventions

- Anything containing live secrets, OAuth tokens, or HR-grade data is
  **gitignored** even if it lives under `config/`.
- Files here are part of every manager's install. The template repo ships
  with `.tmpl` versions; `init.ps1` renders them based on interactive prompts.
