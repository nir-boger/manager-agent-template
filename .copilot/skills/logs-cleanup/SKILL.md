# logs-cleanup

Generic housekeeping for the runtime-only `reports/logs/` folder so it doesn't
grow without bound. **Flow-agnostic** — it prunes the whole folder by age, so
every current and future skill is covered automatically with no per-skill wiring.

## Why
`reports/logs/` is fully gitignored (runtime audit trail, never source of truth).
The 5-minute pollers (pr-review-assistant, ooo-mode, inbox-watch, ...) drop a log
file per tick, so the folder reached 4,600+ files. This skill bounds it.

## What it does
- **`*.log` files** older than the retention window are deleted, **except** the
  newest N per flow prefix, which are always kept (a rarely-run flow never loses
  all its history). Flow prefix is parsed from the filename's date suffix
  (e.g. `pr-review-assistant-2026-05-01_1200.log` -> `pr-review-assistant`).
- **Non-`.log` scratch debris** (`temp-*.py`, stray `*.json`, `*.ps1`, ...) is
  deleted purely by age when `-IncludeScratch` (default on).
- **Grace period**: nothing modified within the last few hours is ever touched,
  so an actively-appending log from a running flow is never truncated.
- **Safety**: refuses to run unless `$LogDir` resolves exactly to
  `<agent-root>\reports\logs`; never recurses; locked-file failures are
  non-fatal warnings; its own log file is never deleted.

## Config (config/agent.json -> `logs`)
| Key | Default | Meaning |
|---|---|---|
| `retention_days` | 14 | `*.log` older than this are eligible for pruning |
| `keep_min_per_prefix` | 5 | newest logs kept per flow prefix (safety net) |
| `grace_hours` | 6 | files modified within this window are never touched |

## Run
```
# preview (deletes nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-logs-cleanup.ps1 -DryRun

# real sweep
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-logs-cleanup.ps1
```
Flags: `-RetentionDays N`, `-KeepMinPerPrefix N`, `-GraceHours N`,
`-IncludeScratch:$false` (prune `*.log` only), `-DryRun`.

## Schedule
`DM-LogsCleanup` runs daily at 05:30 IST via `run-hidden.vbs`.

## Logs
Each run writes `reports/logs/logs-cleanup-YYYY-MM-DD_HHmm.log` (and, yes, those
are themselves pruned by future runs — newest 5 kept like every other flow).

