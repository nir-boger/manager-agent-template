# Skill: team-vacation-watch

## Purpose
Daily watcher over the team's **calendar availability**:

1. Read each Your Team member's **free/busy** status (today + the next ~2 weeks) straight from **Outlook** and detect **Out-of-Office (vacation/OOO)** runs.
2. Update each person's persona file with a **managed vacation-status block**.
3. When someone **returns**, post a warm **"welcome back"** to the **Your Team** Teams channel via `post-to-teams` &mdash; **automatically, once per person per return**.

This is a **fully deterministic** skill &mdash; there is **no copilot agent / LLM in the scan path at all**. The runner `run-team-vacation-watch.ps1` reads free/busy, runs the state engine, and posts welcome-backs itself via Outlook COM. Every step is testable and DryRun-safe.

> ### Why not WorkIQ?
> WorkIQ (`workiq-ask_work_iq`) **structurally cannot** read vacation here. It only returns metadata for **timed meetings**; it cannot read **free/busy** status or **all-day OOO banners**. In testing it missed a teammate's full 2-week vacation across four query phrasings and explicitly recommended the Graph `getSchedule` API. **WorkIQ is retired for this skill** &mdash; treat it as a "doesn't-cover-this-surface" exception (like WhatsApp). The Outlook COM free/busy read below is the sanctioned source.

## Division of labor (READ THIS FIRST)
| Job | Who | How |
|---|---|---|
| Read each member's free/busy | **`read-freebusy.ps1`** | Outlook COM `Recipient.FreeBusy(start,1440,$true)`, decoded by `Get-FreeBusyVacationStatus` |
| **Every file/state write** (persona blocks, snapshot, ledger) | **`apply-vacation-state.ps1`** | deterministic, DryRun-safe, unit-tested |
| Send the welcome-back Teams post | **the runner** | Outlook COM mail with a `NirvanaTeams` subject |

> ### HARD RULE &mdash; nothing writes persona or state files except `apply-vacation-state.ps1`.
> Never use `edit`, `create`, `Set-Content`, `Out-File`, `>`/`>>`, here-strings, or any hand-rolled script to modify a persona file, `vacation-status.json`, or `welcomed.json`. The **only** sanctioned writer is `apply-vacation-state.ps1`. It surgically replaces just the `<!-- nirvana:vacation-status -->` region and preserves every other byte of the persona. Hand-writing these files has previously **catastrophically destroyed all 14 personas** &mdash; that is why this rule (and the whole deterministic redesign) exists.

## Fixed context
- **Roster source**: `<repo>\.copilot\skills\team-personas\people\*.md` &mdash; one persona per teammate. The display name is the H1 (`# <Display Name> (<alias>)`); `<alias>` is the filename stem. `nirvana.md` is excluded.
- **Free/busy reader**: `<repo>\.copilot\skills\team-vacation-watch\read-freebusy.ps1` &mdash; resolves each member via Outlook COM and emits a snapshot JSON (same shape the state engine consumes). Read-only; never writes persona/state files.
- **State engine**: `<repo>\.copilot\skills\team-vacation-watch\apply-vacation-state.ps1` (modes `scan` and `commit`). Owns **all** disk mutation. Honors `-DryRun` (writes nothing). Validates the input JSON before touching anything.
- **Teams post**: Outlook COM trigger email **to `someone@example.com`**, subject **must contain the literal `NirvanaTeams`** (NO brackets &mdash; brackets break the Power Automate V3 subject filter). Unsigned, no forced joke (Teams convention). Latency ~1&ndash;3 min.
- **State dir**: `<repo>\.copilot\skills\team-vacation-watch\state\` &mdash; `vacation-status.json` (last snapshot) and `welcomed.json` (idempotency ledger). **Managed only by `apply-vacation-state.ps1`.**
- **Daily log**: `<repo>\reports\team-vacation-watch\YYYY-MM-DD.md`.
- **Timezone**: all date math is **Israel local time**. Vacation **`end` is inclusive** &rarr; **return date = `end` + 1 day** (the helper enforces this).
- **Config**: `max_late_welcome_days = 2` (the helper won't surface a returnee whose return is more than 2 days stale). `min_working_days_for_welcome = 2` (a vacation must cost **at least 2 Israel working days** &mdash; Sun&ndash;Thu &mdash; or no welcome-back is posted; see the gate below). **Recurring weekly OOF weekdays are subtracted first** &mdash; see "Recurring day-off subtraction" below.

## How free/busy decoding works
`Recipient.FreeBusy($start, $minPerChar, $true)` returns one character per sampled slot, starting at `$start`:

| Char | Meaning |
|---|---|
| `0` | Free |
| `1` | Tentative |
| `2` | Busy |
| `3` | **Out of Office** (vacation/OOO) |
| `4` | Working elsewhere |

We sample **hourly** (60 min/char) and collapse each day to a single OOF flag (`ConvertTo-DailyOofString`): a day is a vacation day **only if it is a (near) full day of OOF** (&ge; 90% of slots). A contiguous run of such full-OOF days is a vacation; `Get-FreeBusyVacationStatus` walks the run to `start`/`end` (inclusive, `yyyy-MM-dd`) and sets `returned_today=true` when yesterday was full-OOF and today is not.

> **Why hourly, not daily (CRITICAL):** sampling at 1440 min/char collapses a day to `3` if *any* part is OOF &mdash; so a single meeting someone marked "Show as Out of Office" looks identical to a vacation. Verified 2026-06-04: Teammate14 had ~2 OOF hours/day (meetings) and was falsely flagged; Oz/Maya/Teammate1 were 24/24 OOF hours (genuine all-day vacation appointments). Requiring a full day of OOF cleanly rejects the per-meeting noise.

> **~29-day fixed-window gotcha:** `Recipient.FreeBusy` returns a fixed-length window (~29 days) that **always starts at the requested date** &mdash; it ignores an arbitrary span. So the requested start must be recent enough that *today* lands inside the returned window. `read-freebusy.ps1` uses `LookbackDays=14` and defensively re-reads from `today-2` if today still isn't in range.

> **Reliability guards (in the engine):**
> - **Low-confidence carry-forward** &mdash; a flaky/unresolved read (`confidence:low`, not-on-vac) does NOT erase a known vacation; the prior snapshot is preserved (`confidence:carried`). This stops a single read flake from flapping a persona or swallowing a later genuine welcome-back. Returnee detection only fires on `high|medium` confidence, so a flake can never *fake* a return.
> - **Not-yet-returned guard** &mdash; a returnee whose computed return date is in the **future** (or otherwise not reached) is never welcomed; you only welcome someone back on/after they're actually back.
>
> ### Working-day deferral
> Israel working days are Sunday-Thursday. If a return date lands on Friday or Saturday, the engine carries the prior `on_vacation=true` snapshot forward (`confidence:carried`) so the one-shot transition is held and re-fires on the next working day, normally Sunday. Lateness is measured from that effective working day, not the raw return date, so `max_late_welcome_days=2` still bridges a weekend. Each surfaced returnee now includes `vac_start`, `vac_end`, inclusive `vac_days`, and `vac_work_days` (Israel working days) from the just-ended vacation.
>
> ### Minimum-working-days gate (no welcome for short/weekend-only absences)
> A returnee is only surfaced (and only then posted) when the just-ended vacation cost **at least `min_working_days_for_welcome` (=2) Israel working days** (Sun&ndash;Thu). `Get-WorkingDayCount` counts working days inclusively over `[vac_start, vac_end]`; Friday/Saturday never count. This silently drops:
> - **Weekend-only** absences (Fri+Sat &rarr; 0 working days).
> - A **single** working day flanked by the weekend (e.g. Thu+Fri+Sat &rarr; 1 working day).
>
> The gate is **silent** &mdash; no returnee, no ledger `pending` claim, no Teams post; the snapshot still flips to not-on-vacation. If the vacation span is unknown (no prior `start`/`end`, e.g. a first-run explicit return) the length can't be measured, so the gate does **not** suppress &mdash; a genuine return is never swallowed just because its length is unknown.
>
> ### Recurring day-off subtraction (why Lea stopped getting welcomed every Thursday)
> The gate above counts **only unexpected absence**. A teammate can have a **standing weekly day-off** &mdash; e.g. a part-timer who is OOF **every Wednesday** (Teammate2). Most weeks that is 1 working day and the `>=2` gate drops it, but a week where she is *also* off one adjacent weekday (Tue+Wed) used to reach 2 working days and wrongly fire a "welcome back" &mdash; **every Thursday**. The band-aid only ever caught the short weeks.
>
> The fix subtracts each person's recurring-off weekdays from the working-day count before applying the gate:
> - `read-freebusy.ps1` computes `recurring_off_days` (int[] of `DayOfWeek`, 0=Sun..6=Sat) from the multi-week free/busy window via `Get-RecurringOffDays`. A working weekday is "recurring off" when it is OOF on a strong majority (&ge;60%) of its &ge;3 observed occurrences **and** appears OOF *in isolation* (not part of a contiguous multi-day block) in &ge;2 weeks. Isolation is measured against the nearest **working-day** neighbours, so the Fri/Sat gap is ignored and it also catches an off-every-Sunday / off-every-Thursday pattern. A genuine contiguous vacation (interior weekdays never isolated) is never mistaken for a recurring pattern.
> - `apply-vacation-state.ps1` builds the gate's working-day set as **Sun&ndash;Thu minus `recurring_off_days`** (`Get-EffectiveWorkingDays`, never empty). So Lea's Tue+Wed week counts only Tue = **1 unexpected working day &rarr; suppressed**, while a real Sun&ndash;Thu vacation still counts &ge;2 and is welcomed. Each surfaced returnee carries `vac_recurring_off` for observability.

## Hard prerequisites
- Outlook desktop running (the runner ensures this). If Outlook is unavailable, the runner logs `outlook=down` and exits cleanly &mdash; no scan, no posts. (Free/busy needs Outlook; there's no offline fallback.)

## Run flags
- `-DryRun` &mdash; read free/busy + compute + report, but **write nothing** and **post nothing**.
- `-Force` &mdash; bypass the per-(alias, return_date) welcome idempotency gate (still respects `max_late_welcome_days`). For testing.
- `-AsOfDate YYYY-MM-DD` &mdash; override "today" for testing.

---

## Procedure (what the runner does)

### 1. Ensure Outlook, then read free/busy
```
powershell -File read-freebusy.ps1 -PeopleDir <people> -AsOfDate <today> -OutJsonPath <temp.json>
```
Emits `{ "as_of":"YYYY-MM-DD", "people":[ { "name","on_vacation","start","end","returned_today","confidence","recurring_off_days" } ] }`. Unresolved/error members are conservatively `on_vacation:false, confidence:"low"`. `recurring_off_days` is an int[] of standing weekly OOF weekdays (0=Sun..6=Sat) the gate subtracts.

### 2. Run the scan (the engine does every write)
```
powershell -File apply-vacation-state.ps1 -Mode scan -WorkIqJsonPath <temp.json> -AsOfDate <today> [-DryRun] [-Force]
```
(The `-WorkIqJsonPath` parameter name is historical; it now takes the free/busy snapshot.) The engine validates the JSON, upserts **every** roster member's managed block, computes returnees, writes the snapshot, and prints:
```
VACWATCH_RESULT: { "mode":"scan","as_of":"...","dry_run":false,"first_run":false,
  "on_vacation":["oz-Teammate8", ...],"persona_updated":14,
  "returnees":[ {"alias":"lea-Teammate2","first_name":"Lea","return_date":"...","reason":"transition","vac_recurring_off":[]} ],
  "unmatched_workiq_names":[] }
```
Each `returnees[]` entry already has a **`pending`** claim written to the ledger by the scan. If the engine exits non-zero, it touched nothing &rarr; log `scan=failed` and stop.

### 3. Post welcome-back, then commit (per returnee)
**Only in a non-DryRun run, and only if Outlook is available.** For each `returnees[]` entry, in order:
1. **Post**: Outlook COM mail, subject `NirvanaTeams Welcome back <first_name>`, a warm body (composed by `Build-WelcomeBackMessage`). Unsigned, no joke.
2. **Commit** the ledger `pending` &rarr; `sent`:
   ```
   powershell -File apply-vacation-state.ps1 -Mode commit -CommitAlias <alias> -CommitReturnDate <return_date>
   ```
If the post fails, do **not** commit &mdash; the `pending` claim makes a later run retry. In `-DryRun`, skip both.

**Welcome message shape** (`Build-WelcomeBackMessage` &mdash; warm, brief, Teams-styled):
> &#128075; Welcome back, **<First Name>**! Hope that **<length phrase>** was just what you needed &mdash; we missed you. A quick brief on what moved in the team's PRs while you were out: *(bulleted PR list)*. Ease back in, and ping the team if you want more context.

- **No raw dates / day counts.** The length is rendered as a qualitative phrase via `Get-VacationLengthPhrase` (working-days based): `short break`, `few days off`, `week off`, `long break`, `long stretch off`.
- **"What you missed" brief = team PRs only.** `Get-AbsenceHighlights` (post-time only, best-effort, ~120s budget) asks the agent for the notable Azure DevOps **pull requests** in repo `Azure-Kusto-Service` completed during `[vac_start, return_date)` authored by the team (roster passed in). It is hard-constrained to **pull requests only** &mdash; **never** email, Teams/chat, or calendar. On any failure/empty it falls back to a generic catch-up line so the post still goes out.

### 4. Log + summarize
Append one line to `reports/team-vacation-watch/YYYY-MM-DD.md`:
```
- <HH:mm> scan: onvac=[oz-Teammate8,maya-Teammate4] returned=[lea-Teammate2] posted=[lea-Teammate2] persona_updated=14 dry_run=false
```

---

## Idempotency & ordering invariants (enforced by the engine; do not work around them)
- **Input JSON is validated before any mutation.** Bad read &rarr; nothing is touched.
- **Persona edits only ever replace the `<!-- nirvana:vacation-status -->` region.** The rest of the file is byte-for-byte preserved (incl. CRLF).
- **`-DryRun` writes nothing** &mdash; no persona, no ledger, no snapshot &mdash; and no Teams post.
- **Claim (`pending`) is written by the scan before the post; flipped to `sent` via commit after a successful post.** A crash between scan and commit leaves a recoverable `pending`, never a duplicate post.
- **The snapshot is written last** (by the scan).
- **Return = `end` + 1 (inclusive end); dates are Israel-local.**
- **First run posts only on explicit `returned_today`** (transition-based returns are blocked on the first run).

## What NOT to do
- **NEVER write or edit a persona file, `vacation-status.json`, or `welcomed.json` by any means other than `apply-vacation-state.ps1`.** (See the HARD RULE.)
- Don't use WorkIQ for vacation detection &mdash; it can't read free/busy (see "Why not WorkIQ?").
- Don't raise `read-freebusy.ps1 -LookbackDays` past ~20 (the ~29-day window quirk).
- Don't post welcome-backs as separate emails to people &mdash; the only channel is the Teams post.
- **Don't welcome someone back for a weekend-only or single-working-day absence** &mdash; the engine's `min_working_days_for_welcome` gate (&ge;2 Israel working days) handles this; never work around it.
- **Don't put raw vacation dates or day counts in the post**, and **don't source the "what you missed" brief from email or Teams** &mdash; it is **pull-requests-only**.
- Don't add brackets around `NirvanaTeams`, don't add the Nirvana signature, don't attach files.
- Don't commit a ledger entry for a post you didn't actually send.
- Don't modify any ADO work items.

## Manual run
```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-team-vacation-watch.ps1
```
Flags: `-DryRun`, `-Force`, `-AsOfDate YYYY-MM-DD`.

## Direct helper invocation (no runner)
Drive the engine directly with a hand-made (or `read-freebusy.ps1`-produced) snapshot JSON:
```
powershell -File apply-vacation-state.ps1 -Mode scan -WorkIqJsonPath sample.json -AsOfDate 2026-06-04 -DryRun
```
Pure helpers live in `vacation-helpers.ps1` (incl. `Get-FreeBusyVacationStatus`) and are unit-tested in `tests/team-vacation-watch.tests.ps1`.

## Scheduled task
`DM-TeamVacationWatch` &mdash; daily **08:00 IST**, repeats every **10 min for 12 hours** so a closed laptop doesn't miss a day. The snapshot overwrite is idempotent; the `welcomed.json` ledger keeps welcome-backs to exactly once per person per return.

