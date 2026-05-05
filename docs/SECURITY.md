# SECURITY.md

This template is designed to be cloned into a personal or organization GitHub
repo and configured per manager. The skills it ships handle real organizational
data (emails, ADO work items, Teams posts, contacts). Treat the running
instance accordingly.

## Data classifications

| Class | Examples | Where it lives |
|---|---|---|
| **Public** | The template repo itself, README, docs. | This repo. |
| **Org-internal** | Direct-report names, ADO PBIs, Teams channel URLs. | `config/agent.json`, `team-personas/people/`, `team-personas/contacts/`. |
| **Sensitive PII** | Personal contact info, photos. | `team-personas/people/`. |
| **HR-grade** | Performance check-ins, ratings, manager comments. | **OFF-tree** at `%USERPROFILE%/.copilot/connect-buddy/`. NEVER inside the repo. |

## The off-tree boundary (HR-grade)

Performance / promotion / level / compensation data is **strictly forbidden**
from this repo. The `connect-buddy` skill keeps every Connect (Microsoft
performance check-in) artifact under `%USERPROFILE%/.copilot/connect-buddy/`,
which is:

- outside the git working tree
- never committed
- referenced via `paths.connect_buddy_root` in `config/agent.json`

The Copilot CLI runner adds `--add-dir` for that path explicitly so the agent
can read manifest data without granting working-tree-wide path trust. Do not
move connect-buddy data inside the repo.

## What `team-personas` may NOT store

Even though personas live in the repo, the schema deliberately excludes:

- `level` / `current_level` / `band`
- `last_promotion_date` / `next_promo_eligibility`
- compensation, bonus, RSU information
- subjective performance assessments
- promotion decision frameworks or eligibility criteria

These constraints reflect Microsoft's "Copilot Usage for P&D" policy
(performance and development data is for HR systems, not engineering
agents). Mirror the same constraints regardless of your employer.

## Secrets

- `.gitignore` excludes ADO PATs, Wellbe `apiKey`, Playwright auth state,
  pilates booking state, and other local-only artifacts.
- The template repo ships with **no** real credentials; `init.ps1` does not
  prompt for any. Manage credentials via your platform's secret store
  (Windows Credential Manager, Azure Key Vault, etc.) and pass them at
  runtime via env vars.
- Before pushing your fork to a public repo, run:

  ```powershell
  git log --all -p -- '**/config.json' '**/allowlist.txt' '**/state.json' '**/.env*'
  git log --all -p | Select-String -Pattern 'apiKey|eyJhbGc|ado_pat_|Microsoft\.AspNetCore'
  ```

  If anything matches, run `git filter-repo` BEFORE pushing.

## Snapshot allowlist

The build-snapshot tool (`tools/build-snapshot.ps1`) excludes from any
public-template build:

- `team-personas/people/*` (your direct reports)
- `team-personas/contacts/*` (extended contacts)
- `team-personas/team-overview.md`, `ownership-snapshot.md`, `sources.txt`,
  `ado-repos.txt`, `daily-summary-state.txt`
- `codebase/codebase-map.md` (or any other indexed codebase map)
- `examples/personal/pilates/state.py` (booking history)
- `reports/**`
- `tmp/**`
- `config/migration-mode.txt`
- `tools/**` (snapshot tool itself)

Plus a substitution pass replaces hardcoded PII strings (manager full name,
alias, email, repo path) with template placeholders.

The `doctor.ps1 -Root <snapshot> -LeakDenylist <items>` flow validates that
no denied tokens leak through.

## Pre-flight checklist before going public

1. `git status` -- no uncommitted secrets.
2. `git log --all -p` greps -- no historical secrets.
3. `tools/build-snapshot.ps1 -OutDir C:\tmp\preview` -- builds the snapshot.
4. `doctor.ps1 -Root C:\tmp\preview -LeakDenylist <your full name>,<alias>,<work email>` -- passes.
5. Manual eyeball of `C:\tmp\preview\AGENTS.md`, `prompts/CUSTOM_INSTRUCTIONS.md`,
   `config/agent.json`, `README.md`.
6. Push to a fresh empty repo (do NOT push to a repo with existing history
   that might surface earlier).

