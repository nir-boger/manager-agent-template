---
name: "personal-todos"
description: "Nir's private todo list. Conversational add via chat ('add to my todo: …'), persistent markdown storage, fancy 07:00 IST daily HTML reminder email with aggressive auto-suggest. Complete by chat / reply / manual edit. Two categories (work, personal). Light gamification: weekly count only."
---

# Skill: personal-todos

## Purpose
Nir's **private** todo list, separate from the team-visible `team-agenda`. Free-form items he wants to remember. Nirvana keeps the file, sends a daily reminder, and proposes 3-5 new items each morning sourced from inbox-watch, PR queue, and milestones.

**Storage:** `reports/personal-todos/todos.md` (markdown, git-tracked, hand-readable).
**State:** `.copilot/skills/personal-todos/state/snapshot.json` (gitignored — snooze times, weekly counters, last-suggest payload).
**Config:** `config/personal-todos.yaml` (categories, reminder time, skip days, sections, joke pool override).
**Scheduled task:** `DM-PersonalTodosDaily`, daily 07:00 IST via `_shared/run-hidden.vbs` (sends Sun–Thu; Fri/Sat skipped via `skip_days`).
**Runner:** `.copilot/skills/run-personal-todos-daily.ps1`.

## Trigger phrases → mode

| User says | Mode |
|---|---|
| "add to my todo", "add a todo", "remind me to …", "PT add …" | **Add item** |
| "what's on my list", "what's on my todo list", "show my todos", "PT list", "list my todos" | **List open** |
| "PT-NNN done", "I did PT-NNN", "complete PT-NNN", "done with PT-NNN", "I did the dentist call" (fuzzy match) | **Complete item** |
| "snooze PT-NNN", "push PT-NNN to <date>", "PT-NNN waiting on X" | **Snooze item** |
| "drop PT-NNN", "kill PT-NNN", "abandon PT-NNN" | **Drop item** |
| "PT-NNN due <date>", "PT-NNN priority <H/M/L>", "PT-NNN category <work/personal>", "edit PT-NNN" | **Edit item** |
| "suggest todos", "what am I forgetting", "what should I add" | **Suggest** |
| "send my daily todo email now", "remind me of my todos now" | **Send reminder now** |

## Storage shape (markdown rows under `## Open`)

Each open item is a markdown section under the `## Open` heading:

```markdown
### PT-007 — Buy birthday card for Partner

- **Status:** Open
- **Category:** personal
- **Priority:** H
- **Created:** 2026-05-12
- **Due:** 2026-05-26
- **Recur:** none
- **Snoozed until:** -
- **Notes:** (free-form context — URLs, related ADO IDs, who triggered it)
```

Done items move to `## Done` and gain a `Done on: YYYY-MM-DD` field. Dropped items move to `## Done` too but their `Status` is `Dropped`.

### Field reference

| Field | Values | Notes |
|---|---|---|
| `Status` | `Open` / `Snoozed` / `Done` / `Dropped` | An item is treated as Open iff it's in the `## Open` section AND status is `Open` or `Snoozed`. Defense-in-depth: anything under `## Done` is treated as closed regardless. |
| `Category` | `work` / `personal` | Defined in `config/personal-todos.yaml`. Reject anything else. |
| `Priority` | `H` / `M` / `L` | Default from config (`M`). |
| `Created` | `YYYY-MM-DD` | Date item was added. Never changes. |
| `Due` | `YYYY-MM-DD` or `-` | Optional. Past-due Open items render in the Overdue section. |
| `Recur` | `none` / `daily` / `weekly` / `monthly` / `every-<Day>` / `<Nth>-<Day>-of-month` | When item is completed, if Recur ≠ none, runner spawns a fresh row with new Due based on the rule. See §"Recurring DSL". |
| `Snoozed until` | `YYYY-MM-DD` or `-` | Optional `"reason"` in quotes after the date. While set + status=Snoozed, item hides from the Today/Overdue sections until that date. |
| `Notes` | free text (single line preferred; multi-line via `<br>`) | Optional. |

## Parsing rules (for any Nirvana run that touches this file)

- Section heading regex: `^###\s+(PT-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$` (em-dash OR hyphen; flexible).
- Field regex: `^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$`.
- The two top-level sections are `## Open` (rows are live) and `## Done` (rows are archived).
- ID counter = max existing `PT-NNN` (across both sections) + 1. Zero-pad to 3 digits.

> **2026-05-12 incident — never hand-roll Markdown when adding items.** The first mobile-Outlook add session computed `PT-NNN` via inline PowerShell, hit a silent format-string failure (`"PT-{0:D3}" -f $next` swallowed an exception, `$nextId` interpolated empty), and wrote `###  — Test from my mobile` with no ID — then "fixed" itself by overwriting the existing PT-001 row instead of appending PT-002, losing the original seed entry. The daily builder regex requires PT-NNN, so the broken row would have silently disappeared from the next email. Fix: always invoke `add-item.py` (see §"Add item"). Helper enforces atomic write, max+1 across both sections, exact field order, and em-dash heading.

## Modes

### Add item

**MANDATORY: always invoke `add-item.py`.** Never hand-roll Markdown. The helper is the single source of truth for ID assignment, field order, and heading shape. This rule exists because the inline-PowerShell add path failed on 2026-05-12 — silently dropped the PT-NNN ID into an empty interpolation and clobbered an existing row (see the incident note in §"Parsing rules").

When Nir says any of the add-mode triggers:

1. Parse his message. Extract:
   - **Title** — the actual todo (everything after "add to my todo:" / "remind me to" etc.).
   - **Category** — explicit `category=<work|personal>`, else infer from text (e.g. "call dentist" → `personal`, "review PR" → `work`). When ambiguous default to `personal`.
   - **Priority** — explicit `pri=<H|M|L>` or `priority high/med/low`. Default from config (`M`).
   - **Due** — explicit `due=<YYYY-MM-DD>` or natural language (`by Friday`, `next Monday`, `tomorrow`, `in 3 days`, `end of week`, `eow`, `end of month`, `eom`). The helper does this parsing — pass the raw phrase verbatim via `--due`.
   - **Recur** — explicit `every Monday`, `daily`, `weekly`, `monthly`, `2nd Friday of month`. Default `none`.
   - **Notes** — anything after `notes:` or `--`.
2. Invoke the helper:
   ```powershell
   python .copilot/skills/personal-todos/add-item.py `
     --todos-file reports/personal-todos/todos.md `
     --title "<title>" `
     [--category work|personal] `
     [--priority H|M|L] `
     [--due "<raw phrase>"] `
     [--recur "<recur>"] `
     [--notes "<notes>"]
   ```
   The helper computes `max(PT-NNN) + 1` across both `## Open` and `## Done`, resolves the due-date phrase, writes atomically (`.tmp` → rename, UTF-8 LF), and emits one TSV line on stdout: `PT-NNN\ttitle\tcategory\tpriority\tdue=YYYY-MM-DD`.
3. Capture stdout. Echo `Added <PT-NNN> — <title> (<category>, due <date>). N open items.`

### List open

Parse the file. Show one line per open item, oldest-due-first then by priority:

```
PT-007 [H] Buy birthday card for Partner — due 2026-05-26 (in 14d) — personal
PT-003 [M] Pay credit card — due 2026-05-22 (in 10d) — personal
PT-001 [H] Write Q3 promo nominations — due 2026-05-19 (in 7d) — work
```

If status is `Snoozed`, append ` 💤 until <date>`.

When Nir asks for a category subset, filter. When he asks "what's overdue", show only items where `Due < today`.

### Complete item

Two paths:

**Exact ID path:** `PT-007 done` / `complete PT-007` / `I did PT-007`.
1. Find `### PT-007 — …` in `## Open`.
2. Flip `Status` to `Done`. Add `Done on: YYYY-MM-DD`.
3. Move the entire section to the bottom of `## Done` (oldest at top).
4. If `Recur` ≠ `none`: compute next due date via §"Recurring DSL", insert a fresh row in `## Open` with the same Title / Category / Priority / Notes, new PT-ID, new Created/Due. The original keeps its Done timestamp.
5. Increment `state/snapshot.json` `weekly_done` counter (current ISO week).
6. Confirm: `Done — PT-007 (Buy birthday card for Partner). N open remain.` (If recurring, also report the new PT-ID.)

**Fuzzy path:** "I did the dentist call". Search Open items for closest title match (case-insensitive substring + token overlap). If exactly one match, proceed as above. If multiple, ask Nir to disambiguate by ID. If none, say so — don't guess.

### Snooze item

`snooze PT-007 to Friday "waiting on Saeed"`.
1. Parse target date (see §"Smart due-date parser").
2. Find `### PT-007 — …` in `## Open`.
3. Flip `Status` to `Snoozed`. Set `Snoozed until: 2026-05-15 "waiting on Saeed"` (reason quoted, optional).
4. Confirm: `Snoozed PT-007 until 2026-05-15 (waiting on Saeed).`

On the snooze-until date the daily runner automatically flips Status back to Open (idempotent — only flips if currently Snoozed and Snoozed-until ≤ today).

### Drop item

`drop PT-007 / kill PT-007`.
1. Find item in `## Open`.
2. Flip `Status` to `Dropped`. Add `Done on:` (yes, we reuse the field — "closed on" semantically).
3. Move to `## Done`.
4. Confirm: `Dropped PT-007.`

### Edit item

`PT-007 due Monday` / `PT-007 priority H` / `PT-007 category work`.
1. Parse the change. One field at a time per phrase; chain multiple edits in one message if Nir lists them.
2. Find item, update the field.
3. Confirm with the new value.

### Suggest

Scan the four configured sources (skip any that don't exist):

- `reports/inbox-watch/YYYY-MM-DD.md` (latest) — deferred-to-Nir bullets that haven't been auto-suggested before.
- `reports/one-on-ones/` (latest per-direct file) — explicit "Nir to follow up …" lines.
- `team-milestones` upcoming list — birthdays / work anniversaries in the next 7 days.

For each candidate, format:

```
1. Call dentist (personal, M) — source: inbox-watch 2026-05-10 (Partner asked you to)
2. Buy card for Omer (personal, M, due 2026-05-15) — source: team-milestones (work anniversary)
3. Confirm Teammate12's onboarding doc handoff (work, M) — source: one-on-ones 2026-05-12
```

When triggered in chat, show the list and ask which to add. When triggered by the daily runner, embed the list in the daily email (see §"Daily email" §Suggests).

### Send reminder now

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-personal-todos-daily.ps1 -Force`. The `-Force` flag bypasses the per-day idempotency check.

## Smart due-date parser

Convert Nir's natural language into an ISO date. Anchor = "today" in IST.

| Phrase | Resolution |
|---|---|
| `today` | today |
| `tomorrow` / `tom` | today + 1 |
| `next <Day>` (Mon..Sun) | next occurrence of that weekday strictly after today |
| `by <Day>` / `on <Day>` | nearest occurrence (today counts if matches) |
| `in N days` | today + N |
| `in a week` / `next week` | today + 7 |
| `eow` / `end of week` | nearest upcoming Sunday (Nir's locale uses Sun-Thu work week) |
| `eom` / `end of month` | last day of current month |
| `<YYYY-MM-DD>` / `<MM/DD>` / `<DD.MM>` | parse directly |

When ambiguous or unparseable, default to no due date (`-`) and confirm verbally: `Added PT-NNN without a due date — say 'PT-NNN due <date>' to set one.`

## Recurring DSL

When an item with `Recur` ≠ `none` is completed, compute next Due:

| Recur | Next Due (relative to old Due, or today if Due was `-`) |
|---|---|
| `daily` | +1 day |
| `weekly` | +7 days |
| `monthly` | same day next month (clamp to last-day if month is shorter) |
| `every-<Day>` (e.g. `every-Mon`) | next occurrence of that weekday after today |
| `<Nth>-<Day>-of-month` (e.g. `2nd-Fri-of-month`) | next month's Nth weekday |

"Skip next" handling: in chat, `skip PT-007` on a recurring item bumps Due by one cycle without marking Done.

## Daily email — sections (in config order)

Subject template (built by the runner):
`[Nirvana] Your day · YYYY-MM-DD · <N due today> · <🔥 M overdue>` (omit zero-count clauses).

Body sections:

### 🎯 Today's focus
Top 3 items by priority + due-today / overdue. Card style, big enough to read on phone:

```
PT-007  Buy birthday card for Partner          [H · personal · due today]
PT-001  Write Q3 promo nominations          [H · work · due in 2d]
PT-003  Pay credit card                     [M · personal · due in 3d]
```

### 🔥 Overdue
Red strip. Each row shows age in days (`N d late`). Sorted oldest-late first. Skip if 0 overdue.

### 📅 This week
Compact list grouped by day-of-week (Mon..Sun). Skip if empty.

### 🗓 Later
Items with Due > today+7d, plus any no-due items not already promoted into Today's focus. Guarantees nothing on the list vanishes from the email.

### 💡 Nirvana suggests
3-5 candidates from the Suggest scan. Each has a number (1..N), title, inferred category/priority, source label. Footer: `Reply 'PT accept 1,3' (or add to the 🖥 Nirvana Agent task list as: PT accept 1,3) to add them.`

### 💤 Snoozed / waiting
Collapsed `<details>` block. One line per snoozed item with the reason.

### 📊 This week
Light gamification: `N done · M open · K added this week`. No streak counter. No "oldest open" shame callout. No Friday celebration.

### Footer
Joke line (rotated, sharp & specific per the joke-playbook — Nirvana-band lyric headliner where it fits) + Nirvana signature (via `Get-NirvanaSignature`). Honors `NOJOKE` / `NOSIG`.

## Daily-email idempotency

State file: `.copilot/skills/personal-todos/state/last-sent.txt`. Holds the most recent `YYYY-MM-DD` date the email was sent. Runner skips when today's stamp already appears, unless `-Force` is passed.

Single-instance lock: `reports/logs/personal-todos.lock` (30-min stale window).

## Weekday skip (Fri/Sat by default)

Nir's work week is **Sun–Thu**, so the daily reminder is suppressed on the weekend. The runner reads `skip_days` from `config/personal-todos.yaml` (default `Friday` + `Saturday`) and exits early — **before** invoking the Python builder — on any listed day. Gating before the builder means a skipped day also leaves the prior day's `state/last-suggest.json` snapshot untouched, so a weekend `PT accept N` reply still maps to the email Nir actually received.

- `skip_days` is re-read every run; edit the YAML to change which days are skipped (or empty the list to send every day).
- `-Force` (the "send my daily todo email now" path) always bypasses the skip, so an on-demand send works any day of the week.

## Cross-skill composition

- **`agent-todos`** — when a `🖥 Nirvana Agent` task body says `add to my personal todo: …`, the agent routes to **Add item** mode here (no separate skill jump). It also recognises `PT accept N[,N,…]` to materialize daily-email suggestions into real PT rows (looking up the latest `state/last-suggest.json` for the numbered list).
- **`inbox-watch`** — every §10b deferred-to-Nir auto-reply appends a follow-up `PT-NNN` here automatically (category=`work`, no due date, notes carry sender + auto-reply timestamp + a preamble snippet) so the mail isn't lost after being moved to `Kusto\Co-Workers`. The audit-trail summary email back to Nir cites the new `PT-NNN` and the daily inbox-watch log row carries `;pt=PT-NNN`. Substantive auto-answers (e.g. `connect-focus`) skip the todo add — only deferred replies create one. The Suggest scan still reads `reports/inbox-watch/YYYY-MM-DD.md` for any other follow-up candidates.
- **`team-agenda`** — sibling skill, team-visible. Personal-todos is private; team-agenda is for items the whole team discusses.

## Voice
- Joke line in daily email per `.copilot/skills/_shared/joke-playbook.md`. Nirvana-band lyric is the headliner — pull when it lands clean.
- Confirmation responses to add/complete/snooze in chat should be one sentence, no fluff. No joke needed (chat ≠ email).
- The email body is composed by Nirvana fresh — never paste a prior internal report. Honors the "compose, don't paste" rule.

## Privacy
All content stays in this repo (`nir-boger/nirvana`, private). The `state/snapshot.json` and `state/last-*.txt` are gitignored. Daily email goes to Nir only; never to a DL.


