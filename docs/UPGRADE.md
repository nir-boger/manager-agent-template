# UPGRADE.md

How to pull updates from the template into your fork.

## Strategy

Files in your fork fall into two buckets:

- **Source** -- you edit these freely (`config/agent.json`,
  `config/banner.txt`, `config/voice.md`, `config/signature-notice.txt`,
  `team-personas/people/*`, etc.).
- **Generated** -- created by `init.ps1` from a template (`AGENTS.md` from
  `templates/AGENTS.md.tmpl`, `prompts/CUSTOM_INSTRUCTIONS.md` from
  `prompts/CUSTOM_INSTRUCTIONS.md.tmpl`).

Upgrades preserve source files; generated files are re-rendered from upstream
templates against your existing config.

## Manual upgrade flow (v1.0)

The v1.0 release does not ship a generic `upgrade.ps1`. Use git:

```powershell
# 1. Add upstream remote (one time only)
git remote add upstream <template-repo-url>

# 2. Fetch upstream changes
git fetch upstream

# 3. Merge upstream/main into your branch
git merge upstream/main

# 4. Resolve conflicts:
#    - For source files, keep your version (e.g. agent.json, voice.md)
#    - For generated files, accept upstream then re-render

# 5. Re-render generated artifacts
.\.copilot\skills\_shared\render-agents.ps1   # AGENTS.md
.\init.ps1 -ConfigFile (your saved answers)   # CUSTOM_INSTRUCTIONS.md, etc.

# 6. Validate
.\doctor.ps1
.\smoke-test.ps1
```

## Versioning

The template uses semver:

- **Major** -- config-schema breaks (e.g. renaming a config field).
  Migration notes in `docs/CHANGELOG.md`.
- **Minor** -- additive changes (new skills, new config fields with defaults).
- **Patch** -- bug fixes, doc updates.

Breaking changes get a `<version>-MIGRATION.md` note in `docs/`.

## Known migration moments

- **v1.0 -> next**: skill renames take their alias-stub release. The
  `agent-todos` and `codebase` aliases will be removed in a
  future major release. Update direct path references in your runners and
  saved TODO files before then.

