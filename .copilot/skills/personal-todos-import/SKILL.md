---
name: "personal-todos-import"
description: "Auto-imports Outlook tasks from the '🔎 Nirvana TODO' list into personal-todos (PT-NNN), then marks the Outlook task complete. Polled by scheduled task DM-PersonalTodosImport every 5 min, 24/7. Set-and-forget bridge — no chat triggers."
---

# Skill: personal-todos-import

## Purpose
Lightweight one-way bridge: anything Nir drops into the Outlook task list `🔎 Nirvana TODO` becomes a `PT-NNN` row in `reports/personal-todos/todos.md`, then the Outlook task is marked complete with the assigned PT-ID prefixed in its subject.

Distinct from `agent-todos` (which routes general-purpose instructions across many handlers) and `personal-todos` (chat surface + daily-email surface). This skill is **single-purpose, deterministic, silent**: subject → title, body → notes, defaults for everything else.

## Storage / runner / schedule
- **Outlook source:** `Tasks > 🔎 Nirvana TODO` (matched by regex `Nirvana\s*TODO`).
- **Write path:** invokes `.copilot/skills/personal-todos/add-item.py` — the single source of truth for PT-NNN assignment.
- **Runner:** `.copilot/skills/run-personal-todos-import.ps1` (pure pipeline, no copilot CLI invocation).
- **Scheduled task:** `DM-PersonalTodosImport`, every 5 min, 24/7, via `_shared/run-hidden.vbs`.
- **Lock:** `reports/logs/personal-todos-import.lock` (30-min stale window).
- **Log:** `reports/logs/personal-todos-import-YYYY-MM-DD_HHmm.log` (one file per tick that finds work; ticks with nothing to do exit silently without creating a log).

## How it works (per tick)

1. Acquire single-instance lock (skip if a previous tick is still running and lock is fresh).
2. Ensure Outlook is running (via `_shared/ensure-outlook.ps1`). Skip silently if not.
3. Locate `Tasks > 🔎 Nirvana TODO` by regex. Skip silently if missing.
4. For each `TaskItem` in that folder:
   - Skip if `Complete=true`.
   - Skip if `(now - CreationTime) < 60 s` (settle window — Nir might still be typing on mobile).
   - Skip with a warning if `Subject` is empty (after trim).
   - Capture `title = Subject.Trim()` and `notes = Body.Trim()` (or `-` if body is empty).
   - Invoke `python .copilot/skills/personal-todos/add-item.py --todos-file reports/personal-todos/todos.md --title "<title>" --notes "<notes>"`.
   - Parse the assigned PT-NNN from stdout (TSV: `PT-NNN<TAB>title<TAB>category<TAB>priority<TAB>due=…`).
   - On the Outlook task: prepend `[PT-NNN] ` to `Subject`, set `Complete=true`, `Save()`.
5. Release lock. Log per-task outcome (`ok` / `skip` / `fail` / `warn`).

## Defaults (intentional)

| Field | Default |
|---|---|
| `category` | `personal` |
| `priority` | `M` |
| `due` | `-` (no due date) |
| `recur` | `none` |
| `notes` | task `Body` (or `-` if empty) |

Nir can fix any of these post-hoc via chat (`PT-007 priority H`, `PT-007 due Friday`, …) per the `personal-todos` skill's Edit mode. The importer never tries to be clever.

## Failure modes (never throws — always exits 0)

| Condition | Behavior |
|---|---|
| Outlook not running | Exit 0 silently (Ensure-OutlookRunning returns false; no log). |
| 🔎 Nirvana TODO folder missing | Exit 0 silently. |
| Empty subject | Log `[warn] task has empty subject; leaving untouched`, leave task as-is so Nir can fix it. |
| `add-item.py` non-zero exit | Log `[fail]` with stderr, leave Outlook task untouched → next tick retries. |
| Stdout doesn't contain `PT-NNN` | Log `[fail]`, leave Outlook task untouched → next tick retries. |
| Outlook update after add succeeded | Log `[fail]` — Nir ends up with the PT-NNN row in todos.md but the Outlook task is not marked complete. Manual cleanup. (Rare; usually Outlook COM is stable.) |

## No per-item confirmation email

By design — silent operation. Visibility surfaces are the existing 07:00 daily reminder email and chat `list my todos`. If Nir wants per-item confirmation, that's an explicit opt-in for later.

## Trigger phrases

No chat triggers. This skill is runner-only. To invoke on-demand: run
`powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-personal-todos-import.ps1`
or just wait up to 5 min for the scheduled task to fire.

`-DryRun` switch: logs what would be imported but doesn't call add-item.py and doesn't touch Outlook.

## Cross-skill composition

- **`personal-todos`** — write path (via `add-item.py`). PT-NNN rows from this importer are indistinguishable from chat-added rows downstream.
- **`agent-todos`** — sibling skill on a different Outlook folder (`🖥 Nirvana Agent`). Independent runner, independent lock. Both can run in parallel.

## Privacy
Outlook task content stays in `reports/personal-todos/todos.md` (private repo) and `reports/logs/personal-todos-import-*.log` (gitignored). No outbound email.

