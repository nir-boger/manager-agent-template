# team-brief (Skill)

Two **fancy, Nir-only digest emails** about what the direct-report team did,
rendered with the investigation-email look (dark hero / TL;DR / stat grid /
per-person cards). One skill, two modes:

| Mode | What it answers | Shape | Cadence | Scheduled task |
|---|---|---|---|---|
| `daily`  | "What did my team do today?" | Per person: PRs **Opened**, PRs **Reviewed**, and a **Teams &amp; email** highlight. | 18:30 IST, same day (after the 18:00 capture lands) | `DM-TeamBriefDaily` |
| `weekly` | "What did each person accomplish this week?" | **PR-free** per-person prose &mdash; what each drove and shipped. | Thursday 17:00 IST | `DM-TeamWeeklyHighlights` |

The daily brief is a once-a-day read on where the 14 directs spent the day; the
weekly highlights roll up the Israeli work week (**Sun&ndash;Thu**).

### Two headline rules (why this skill was rebuilt)

1. **Attribute PRs by `role`.** Each `recent_prs[]` entry carries `role`
   (`author` | `reviewer`). The **author** *opened* the PR; **reviewers** only
   *reviewed* it. The same PR id appears under many people with different roles, so
   crediting a reviewer as the author is the exact bug Nir caught (a PR Roni authored
   was shown as Teammate12's). `Get-TeamBriefData` splits each person's PRs into
   `PrsAuthored` (role=author) and `PrsReviewed` (role=reviewer), deduped by id.
2. **No work-item counts.** The brief never reports "N work items opened/in flight".

## When to run

- On a trigger phrase: *"team brief"*, *"what did my team do"*, *"send the team
  brief now"*, *"weekly highlights"*, *"send the weekly highlights"*,
  *"team-brief"*.
- Automatically, via the two scheduled tasks above.

## Entry point

```
.copilot/skills/run-team-brief.ps1 -Mode daily|weekly [-Date yyyy-MM-dd] [-Force] [-DryRun] [-NoEmail] [-Enrich] [-Preview]
```

| Flag | Effect |
|---|---|
| `-Mode daily` (default) | The same-day team brief. |
| `-Mode weekly` | The Sun&ndash;Thu highlights roll-up. |
| `-Date yyyy-MM-dd` | Anchor day (daily = that day; weekly = the work week containing it). Defaults to today. |
| `-Force` | Ignore state; render + send a single day/week even if already sent. Also disables daily backfill (single day only). |
| `-DryRun` | Render the HTML preview only &mdash; no send, no state advance. |
| `-NoEmail` | Render + log, no send, no state advance. |
| `-Enrich` | Refresh `state/enrichment.json` via WorkIQ (`enrich.ps1`) before rendering. Slow (one WorkIQ call per direct). Off by default &mdash; the runner always *reads* the cache; `-Enrich` *rewrites* it. |
| `-Preview` | Also open the rendered HTML locally. |

Manual examples:

```powershell
# Today's brief, right now
pwsh -NoProfile -File .copilot/skills/run-team-brief.ps1 -Mode daily

# This week's highlights, preview only (no send)
pwsh -NoProfile -File .copilot/skills/run-team-brief.ps1 -Mode weekly -DryRun -Preview

# Re-send a specific past day
pwsh -NoProfile -File .copilot/skills/run-team-brief.ps1 -Mode daily -Date 2026-06-04 -Force
```

## Data sources

1. **`reports/directs-scope/directs-context.json`** (local) &mdash; per-direct `recent_prs`
   (id / title / url / status `active|completed` / **role `author|reviewer`** / repo /
   **`author`** display name / `created` ISO-UTC) and `recent_wins`. Refreshed out-of-band by
   `DM-RefreshDirectsContext` (which captures each PR's `createdBy.displayName` as `author`,
   so reviewed PRs can name who wrote them). The `generated_at` timestamp is surfaced as a
   chip so the reader knows how fresh the ADO snapshot is. **Work items are intentionally ignored.**
2. **`.copilot/skills/team-brief/state/enrichment.json`** (local cache) &mdash; per-person
   `{ daily, weekly }` prose **sourced from WorkIQ** (read-only). This is what powers the
   daily **Teams &amp; email** highlight and the entire **weekly** narrative, because the
   ADO snapshot has no Teams/email/meeting signal. Shape:
   `{ generated_at, source, people: { <alias>: { daily, weekly } } }`. The runner always
   *reads* it; `-Enrich` (via `enrich.ps1`) *rewrites* it from WorkIQ. Missing/empty
   entries fall back to local persona signal.
3. **`.copilot/skills/team-personas/people/<alias>.md`** (local) &mdash; the `## Daily
   observations` lines (dated email-thread topics + behavioral signals), ingested by
   `DM-PersonasImport`. Used as a **fallback** for the daily highlight when enrichment is
   absent, and for the italic behavioral quote.

### What each mode renders

- **Daily** &mdash; 3 stat cards (People active / PRs opened / PRs reviewed), then a card per
  active person with an **Opened** PR list, a **Reviewed** PR list (each reviewed PR shows
  the **PR author's name in parentheses**, sourced from `recent_prs[].author`), and a
  **Teams &amp; email** highlight (from enrichment `daily`, else recent inbox threads).
  Quiet people are rolled into a single "Quiet in this window" note ("absence of signal,
  not absence of work").
- **Weekly** &mdash; **no PRs, no stat grid.** One card per person with a 2&ndash;3 sentence
  prose summary of what they accomplished (from enrichment `weekly`) plus up to 3 wins.
  People with no tracked activity get an honest one-liner (e.g. "On leave", "No tracked
  activity this week") &mdash; never fabricated work.

### Honest PR filtering

`directs-context.json` carries only a **`created`** timestamp, not a completed/merged
one. So PRs are filtered into the window strictly by **created-in-window**
(`Test-PrInWindow`, half-open `[start, end)`), then split by `role`. We never claim a
PR "completed today" when only a `created` timestamp is known, and never credit a
reviewer with authoring.

## Time windows (DST-correct, IST)

- All windows are computed in **Israel time** via `[TimeZoneInfo]` (`Israel Standard
  Time` / `Asia/Jerusalem`), so June DST (UTC+3) is handled per-instant.
- **Daily** window for day *D* = `[D 00:00 IST, D+1 00:00 IST)` in UTC.
- **Weekly** window = `[Sunday 00:00 IST, Friday 00:00 IST)` &mdash; the Sun&ndash;Thu
  work week containing the anchor.

## Backfill on resume (weekend Cloud PC suspends)

The Cloud PC is suspended on weekends, so a Sunday/Monday daily run can owe several
missed days. Daily mode therefore covers **`[last-sent + 1 .. target]` in ONE
consolidated email**, capped at 7 days. State only advances **on a successful send**,
so a failed/migration-skipped run re-attempts next time instead of silently dropping a
day. `-Force` collapses this to the single target day.

## Idempotency / state

- `state/daily-sent.json` and `state/weekly-sent.json`, each `{ records: [ { key, mode,
  sent_at, covered_dates, ... } ] }`.
- Daily key = `day-yyyy-MM-dd` (the target day); weekly key = `week-yyyy-MM-dd` (the
  Sunday). A matching key in state suppresses a re-send unless `-Force`.

## Output, voice, conventions

- Rendered HTML preview is written to `reports/team-brief/<mode>-<yyyy-MM-dd>.html`
  every run (even dry runs).
- Email is sent **to Nir only** (`manager.email`) via Outlook COM, mirroring the
  `email-team` recipe: `Test-MigrationMode` guard (skips send, does NOT advance state),
  never throws, releases COM in `finally`, and appends an audit line to
  `reports/email/<yyyy-MM-dd>.md`.
- **Joke + signature are required.** A mode-appropriate joke goes in the spec; the
  signature (`Get-NirvanaSignature -Variant Default`) is inserted **before `</body>`**
  via `Add-SignatureBeforeBodyClose` (the renderer returns the doc without a signature).
- Subjects: `[Nirvana] Team brief - <range>` and `[Nirvana] Weekly team highlights -
  week of <range>`.

## Never

- Never call ADO/OneDrive to mutate anything &mdash; this skill is **read-only**.
- Never advance state when the send didn't actually happen (failure or migration mode).
- Never claim a PR "completed today" when only a `created` timestamp is known.

## Files

- `.copilot/skills/run-team-brief.ps1` &mdash; orchestration (config, sources, windows,
  enrichment read, render, COM send, state, logging).
- `.copilot/skills/team-brief/helpers.ps1` &mdash; pure, unit-tested helpers (timezone /
  window math, HTML encode, PR-in-window, role-based attribution, observation parser,
  spec builders, signature insertion).
- `.copilot/skills/team-brief/enrich.ps1` &mdash; best-effort WorkIQ enrichment generator
  (run only under `-Enrich`); writes/merges `state/enrichment.json`, graceful on failure.
- `.copilot/skills/team-brief/state/` &mdash; `daily-sent.json`, `weekly-sent.json`,
  `enrichment.json`.
- `tests/team-brief.tests.ps1` &mdash; Pester-style tests for the pure helpers + wiring.

