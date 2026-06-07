# reminders

Nirvana-as-personal-assistant reminder service. **Take a note now → get pinged before something happens.** Two trigger kinds in v1:

| Kind | Fires when | Use for |
|---|---|---|
| `meeting` | N minutes before/after a meeting whose subject matches a substring | "remind me 30 min before the DM SLO sync", "ping me when the WSR starts" |
| `absolute` | At a fixed ISO timestamp | "remind me 2026-05-22 09:00 to call dad", "remind me tomorrow at 17:00 about the PR" |

**Notes file:** `reports/reminders/reminders.md` (`RM-NNN`, hand-readable, same shape as personal-todos / team-agenda).

**Scheduled task:** `DM-Reminders` — single polling task, **every 5 minutes 24/7** via `run-hidden.vbs`. Re-resolves meeting times each tick, so if a meeting is moved in Outlook the reminder follows automatically.

**Runner:** `.copilot/skills/run-reminders.ps1`.

## Trigger phrases

| User says | Mode |
|---|---|
| "remind me before <meeting subject> on <date>", "remind me N min before the <subject> meeting", "ping me when <meeting> starts" | **add meeting reminder** |
| "remind me at <time/date> to <X>", "remind me on <date> about <X>", "remind me tomorrow morning to <X>" | **add absolute reminder** |
| "list reminders", "what reminders do I have", "show pending reminders" | **list** |
| "cancel RM-NNN", "drop RM-NNN", "kill RM-NNN" | **cancel** |
| "fire reminders now", "tick reminders" | **manual tick** (runs the poller once) |

## Add mode (chat → file)

When Nir asks for a new reminder, Nirvana resolves the natural language to one of the two trigger kinds and calls `add-item.py`:

```powershell
python .copilot\skills\reminders\add-item.py `
  --reminders-file reports\reminders\reminders.md `
  --title "<short title>" `
  --kind meeting `
  --meeting-subject "SLO" `
  --meeting-date 2026-05-26 `
  --offset-min -30 `
  --channel email `
  --notes "Full context, incident IDs, suggested play..."
```

Or for absolute:

```powershell
python .copilot\skills\reminders\add-item.py `
  --reminders-file reports\reminders\reminders.md `
  --title "Call dad" `
  --kind absolute `
  --fire-at 2026-05-22T09:00:00+03:00 `
  --notes "..."
```

The helper:
- Computes the next `RM-NNN` (max existing + 1, zero-padded).
- Validates kind-specific fields (meeting → subject + date + offset_min; absolute → fire_at ISO).
- Appends a section under `## Pending` atomically (.tmp → rename).
- Emits one TSV line on stdout: `RM-NNN<TAB>title<TAB>kind<TAB>when`.

## Entry shape (in `reminders.md`)

```markdown
### RM-001 - DM SLO sync (30 min before): raise Oz's investigation on Incident 796120279

- **Status:** pending
- **Kind:** meeting
- **Created:** 2026-05-14
- **Channel:** email
- **Meeting subject match:** SLO
- **Meeting date:** 2026-05-26
- **Offset min:** -30
- **Notes:** Re: Incident 796120279 - [Internal] [ADX] [Data Issues] [Central US] [MDCPRD] [Latency Issues]. Oz is on the invite; the investigation can fit naturally as an SLO topic.
```

```markdown
### RM-002 - Call dad

- **Status:** pending
- **Kind:** absolute
- **Created:** 2026-05-14
- **Channel:** email
- **Fire at:** 2026-05-22T09:00:00+03:00
- **Notes:** ...
```

After firing, the runner appends `Fired at` + `Resolved fire_at` and moves the section to `## Fired`.

## Runner logic (every 5 min)

1. Acquire single-instance lock at `reports/logs/reminders.lock`.
2. Parse `reminders.md`, collect every `Status: pending` entry.
3. For each entry, compute `fire_at`:
   - `kind=absolute`: parse `Fire at` ISO directly.
   - `kind=meeting`: open Outlook MAPI calendar, restrict to `Meeting date` (start-of-day to end-of-day local), find first item whose `Subject` contains `Meeting subject match` (case-insensitive). `fire_at = item.Start + offset_min minutes`. If no match → log `meeting not found` and skip.
4. Compute window: fire if `now - 10min <= fire_at <= now`. (The 10-min back-window absorbs catch-up after sleep / reboot.)
5. For each due reminder:
   - Send email via Outlook COM (subject + body include the reminder title + notes + resolved fire_at + meeting context).
   - Atomically rewrite the markdown: flip `Status` to `fired`, append `Fired at` + `Resolved fire_at`, move the section to `## Fired`.
6. Release lock. Log to `reports/logs/reminders-YYYY-MM-DD.log`.

The runner is idempotent: once `Status: fired`, it never re-fires.

## Auth / dependencies

- Outlook desktop must be running for the meeting lookup AND for the email send. If not running, the runner exits cleanly (no fire) with a warning in the log — it's a hidden background task, never auto-launches Outlook.
- No ADO, Graph, or external APIs.

## Voice rules

Reminder emails are short, focused, and follow the standard email voice rules: joke + signature mandatory unless `NOJOKE` / `NOSIG` appears in the note. Uses `Get-NirvanaSignature` from `_shared/signature.ps1`.

Subject pattern: `[Nirvana] Reminder: <title>` (truncated to ~80 chars).

## Files

- `SKILL.md` — this file
- `add-item.py` — atomic add helper
- `../run-reminders.ps1` — poller (runs every 5 min)
- `../../../reports/reminders/reminders.md` — source of truth

## History

- 2026-05-14: Skill created. Migrated PT-001 (DM SLO sync 30-min-before reminder) → RM-001. Decommissioned one-shot task `DM-Reminder-DMSLOSync-2026-05-26` (replaced by the central poller).
