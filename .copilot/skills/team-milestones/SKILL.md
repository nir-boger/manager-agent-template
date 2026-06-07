# team-milestones

Daily morning reminder of team birthdays and work anniversaries. Reads dates from the curated `team-personas/people/<alias>.md` Employment blocks, fires only when there's something to announce.

## Fixed context

- **Data source**: `<repo>\.copilot\skills\team-personas\people\*.md` &mdash; the `## Employment` block, lines `**Birthday:** M/D` and `**Hired:** YYYY-MM-DD`. Date convention is **MM/DD** for `Birthday` (e.g., `4/15` = April 15; matches the rest of the personas) and **YYYY-MM-DD** for `Hired`. **Nirvana counts too** &mdash; her persona file (`people/nirvana.md`) carries `Birthday: 4/23` and `Hired: 2026-04-23`, so her annual milestones fire through the same parser as the humans.
- **Recipient**: `someone@example.com` (Nir himself &mdash; this is a personal heads-up, not a team broadcast).
- **Subject prefix**: `[Nirvana]` so `inbox-watch` ignores the email.
- **Signature**: `Default` variant via `_shared/signature.ps1`. This is user-facing content, **not** a runner heartbeat &mdash; do not use the `RunnerHeartbeat` variant.
- **Joke**: yes, one short joke per email-voice rules. Skip with `NOJOKE`.

## Trigger window

Two windows per run:

1. **Today** &mdash; events whose recurring date matches today's local date (Israel TZ).
2. **Tomorrow heads-up** &mdash; events whose recurring date matches tomorrow's local date.

Anniversary years are computed as `today.Year - hired.Year` (or `tomorrow.Year - hired.Year`); years &lt; 1 are skipped (no "0-year" celebrations).

## Run behavior

1. Resolve `today` and `tomorrow` (midnight, local time).
2. Walk every `team-personas/people/*.md`. Parse the Employment block. Skip files with malformed dates (warn-log, don't throw).
3. Bucket events into `Today[]` and `Tomorrow[]`.
4. **If both buckets are empty** &mdash; log "no milestones today or tomorrow", **do not send email**, exit 0.
5. **Idempotency** &mdash; record the run in `state/last-sent.txt` keyed by date. If today's date is already in the state file with the same fingerprint (sorted list of names+types), skip the send. This prevents duplicate emails on manual reruns.
6. **Send** via Outlook COM. Subject:
   - both buckets: `[Nirvana] Team milestones - today: <names>; tomorrow: <names>`
   - only today: `[Nirvana] Team milestones today: <names>`
   - only tomorrow: `[Nirvana] Team milestones tomorrow heads-up: <names>`
7. Log to `reports/logs/team-milestones-<YYYY-MM-DD>.log`.

## Email body shape

```
<p>Today (Sat, May 09) - 1 milestone:</p>
<ul>
  <li><strong>Teammate9</strong> - 14-year work anniversary (hired 2012-05-09)</li>
</ul>

<p>Tomorrow heads-up (Sun, May 10) - 1 milestone:</p>
<ul>
  <li><strong>Teammate4</strong> - 2-year work anniversary (hired 2024-05-15)</li>
</ul>

<p style="color:#555;font-style:italic">&lt;short joke&gt;</p>
&lt;Default signature&gt;
```

If a teammate has both a birthday AND a work anniversary on the same day, render two list items (one per type) for clarity.

## Failure modes

- **Outlook not running** &mdash; the COM call throws. Catch, log `email=skipped:no-outlook`, exit 0 (don't crash the scheduled task). Same convention as `sprint-create`.
- **Persona parse error** &mdash; warn-log the file, continue.
- **OneDrive / source unreadable** &mdash; N/A, this skill reads only repo-local files.

## Manual run

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-team-milestones-daily.ps1
```

Add `-DryRun` to compute and log without sending. Add `-Force` to bypass the per-day idempotency check.

## Scheduled task

`DM-TeamMilestonesDaily` &mdash; daily at **07:00 IST**, then **repeats every 10 min for 14 hours** so a closed laptop doesn't cause a missed day. Per-day idempotency state file (`state/last-sent.txt`) makes the repetition cheap (same fingerprint exits silently).

