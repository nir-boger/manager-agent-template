# CUSTOMIZE.md

How to make this template your own.

## Quick start

The fastest path is the onboarding triad:

```powershell
.\init.ps1            # interactive wizard - writes config + renders templates
.\doctor.ps1          # validates environment + config consistency
.\smoke-test.ps1      # safe end-to-end check (no real emails sent)
```

You can also run `init.ps1 -ConfigFile answers.json -Force` for non-interactive
runs (CI / fork onboarding scripts).

## What lives where

| Path | What |
|---|---|
| `config/agent.json` | Single source of truth for identity, ADO/team scope, signature, voice, feature flags. |
| `config/banner.txt` | ASCII banner printed at session start. Empty file = no banner. |
| `config/voice.md` | Voice profile (tone, vocabulary, joke bank). Pointer to an `examples/voice-profiles/` profile or your own. |
| `config/signature-notice.txt` | One-line announcement appended to every signature. Empty file = no notice. |
| `config/skills.json` | Manifest of installed skills. Drives `AGENTS.md` rendering. |
| `prompts/CUSTOM_INSTRUCTIONS.md` | The agent's persona prompt (rendered from `.tmpl`). |
| `.copilot/skills/team-personas/people/` | One Markdown file per direct report. Schema in `team-personas/SKILL.md`. |
| `examples/personal/` | Personal-life skills (Partner, Pilates) shipped as copy-paste reference. |

## Identity and signature

Edit `config/agent.json`:

```json
{
  "agent":   { "name": "Aria", "trigger_aliases": ["aria","@aria"],
               "mail_subject_prefix": "[Aria]", "idempotency_tag": "AriaProcessed" },
  "manager": { "first_name": "Sam", "full_name": "Sam Doe",
               "email": "sam@example.com", "alias": "sdoe" },
  "ado":     { "org": "contoso", "project": "engineering" },
  "team":    { "name": "Platform Team", "alias": "platform", "channel_url": "" },
  "tasks":   { "prefix": "PLT" }
}
```

After editing, re-render generated artifacts:

```powershell
.\.copilot\skills\_shared\render-agents.ps1   # regenerates AGENTS.md
.\doctor.ps1                                  # validates config + asset paths
```

## Voice and humor

`_shared/joke-playbook.md` documents the technique catalog (how the agent
crafts jokes). The active flavor profile lives at `config/voice.md` and may
point at one of the worked examples under `examples/voice-profiles/`:

- `nirvana-band.md` -- band-lyric flavor (the original Nirvana set)
- `kusto-kql.md`    -- KQL/data vocabulary

Drop your own profile in `examples/voice-profiles/` and update
`config.voice.profile_path` in `agent.json`.

## Adding or removing a skill

1. Drop a folder under `.copilot/skills/<name>/` with a `SKILL.md`.
2. Add a manifest entry to `config/skills.json`:
   ```json
   {
     "name": "<name>",
     "surface": "engine",
     "path": ".copilot/skills/<name>",
     "entrypoint_path": ".copilot/skills/run-<name>.ps1",
     "triggers": ["my trigger phrase"],
     "show_in_agents": true,
     "ship_in_snapshot": true,
     "summary": ""
   }
   ```
3. Add a runner script (if scheduled) at `.copilot/skills/run-<name>.ps1`. Use
   `_shared/runner-prelude.ps1` for the standard bootstrap (sets `$AgentRoot`,
   `$AgentConfig`, `$LogDir`, console UTF-8).
4. Re-render: `.\.copilot\skills\_shared\render-agents.ps1`.
5. Validate: `.\doctor.ps1`.

To remove a skill: delete the folder, remove the manifest entry, regenerate.

## Migration mode (kill switch)

Drop a `config/migration-mode.txt` file (or set `$env:AGENT_MIGRATION_MODE=1`)
to prevent ALL `.Send()` calls in runners and the inbox-watch impl. Use during
refactors to avoid double-firing emails. The file is gitignored by default.

## Scheduled tasks

Each runner that wants to fire on a schedule registers a Windows scheduled
task with the `<tasks.prefix>-<RunnerName>` naming convention. See
`examples/personal/pilates/register-tasks.ps1` for the template.

## Locale

`config/agent.json` holds `locale.language`, `locale.timezone`,
`locale.timezone_abbreviation`, and `locale.work_week_start`. Skills that have
language-specific behavior (`inbox-watch` Hebrew salutations, etc.) check
`locale.language`.

## Where the runtime reads from

The `_shared/config.ps1` helpers expose:

- `Resolve-AgentRoot`     -- finds the repo root via env var or walk-up
- `Get-AgentConfig`       -- loads `config/agent.json` (cached)
- `Get-AgentField -Path 'a.b.c' [-Default x]` -- dot-path lookups
- `Resolve-AgentPath`     -- expands env vars + relative-to-root

Helpers self-bootstrap; don't depend on `runner-prelude.ps1` from inside a
shared helper.

