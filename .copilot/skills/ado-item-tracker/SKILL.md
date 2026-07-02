# ado-item-tracker

Track a **curated set of ADO work items** and stay on top of them three ways:

1. **Daily digest** &mdash; a Nir-only HTML email (Sun&ndash;Thu, 09:00 IST) with a clean table: **ADO link &middot; title &middot; who works on it &middot; status**.
2. **Hourly watcher** &mdash; whenever a tracked item changes (state / assignee / title / any edit), Nir gets a short **update** email. Change-only, idempotent.
3. **Board tab** &mdash; the tracked items appear on the **Nirvana Board** under **ADO Tracker**, each row with a **Ping owner** button that emails the assignee (on Nir's behalf) for a status update.

This is a *manager's watchlist* &mdash; a small, hand-picked set of items Nir cares about right now &mdash; not the whole sprint (that's `sprint-digest` / `sprint-report-daily`).

**Runner:** `.copilot/skills/run-ado-item-tracker.ps1`
**Render helpers:** `.copilot/skills/ado-item-tracker/render.ps1`
**Source of truth:** `reports/ado-tracker/tracked.json` (committed) &mdash; `[{id, note, addedAt}]`.
**Runtime (gitignored):** `reports/ado-tracker/cache.json` (board cache) + `.copilot/skills/ado-item-tracker/state/` (diff baseline, per-day idempotency, preview HTML).

## Trigger phrases &rarr; mode

| Nir says | Action |
|---|---|
| "track ADO 12345", "track ADO <url>", "start tracking 12345" | `-Mode add -Id 12345` |
| "track ADO 12345 (note: ...)", "track 12345 and note ..." | `-Mode add -Id 12345 -Note "..."` |
| "untrack ADO 12345", "stop tracking 12345", "remove 12345" | `-Mode remove -Id 12345` |
| "what ADO am I tracking", "list tracked ADO", "show my tracker" | `-Mode list` |
| "send the ADO digest now", "ADO tracker digest" | `-Mode digest -Force` |
| "check the ADO tracker for updates now" | `-Mode watch` |
| (Board "Ping owner" button) | `-Mode ping -Id 12345` |

When Nir gives an id or a work-item URL, parse the trailing integer and run **add**. Confirm with the item's title + owner + state (the runner prints this). The set is intentionally small &mdash; if it grows past ~25, suggest pruning.

## How it works

- **ADO access:** `az account get-access-token` + the **org-level** `workitemsbatch` REST endpoint (so tracked items may live in **any** project, not just `One`). Fields pulled: Id, Title, WorkItemType, State, AssignedTo, ChangedDate, ChangedBy, TeamProject. The human URL is `https://your-ado-org.visualstudio.com/<project>/_workitems/edit/<id>`.
- **Owner email** comes from `System.AssignedTo.uniqueName`.
- **Cache:** every `add` / `digest` / `watch` / `list` refreshes `reports/ado-tracker/cache.json` so the Board renders instantly without an ADO token of its own.

### Daily digest (`-Mode digest`)
- One email per day, keyed on the date in `state/digest-last-sent.txt` (idempotent; `-Force` resends). The schedule only fires Sun&ndash;Thu, so weekends are silent.
- Empty tracked set &rarr; **no email** (a daily "you track nothing" nag is worse than silence).
- Flags missing ids (removed / access lost) in a footer instead of failing.

### Hourly watcher (`-Mode watch`)
- Diffs each item against `state/last-snapshot.json`. An **update** is: a State change, an Owner change, a Title change, or (failing those) `ChangedDate` advancing &mdash; reported as "Edited by X". Brand-new ids (just added) are pre-baselined by `add`, so they never misfire.
- Sends **only when something changed**; otherwise exits quietly.
- The baseline is advanced **only after a successful send** (favor never-miss over never-duplicate).

### Ping owner (`-Mode ping -Id N`)
- Emails the current assignee a short, friendly status-check **on Nir's behalf** (Nir's Outlook &rarr; lands in his Sent for a record). 
- **Guardrails:** unassigned &rarr; no-op; non-`@microsoft.com` owner &rarr; refuses to send.

## Board integration
- `GET /api/ado-tracker` &mdash; merges `tracked.json` (order + notes) with `cache.json` (live fields); also embedded in `/api/board` under `ado_tracker` with a `counts.ado_tracker`.
- `POST /api/ado-tracker/ping` `{id}` &mdash; fire-and-forget spawns `run-ado-item-tracker.ps1 -Mode ping -Id <id>`.
- Frontend: an **ADO Tracker** tab (read-only table modeled on the scope-board tab) with a per-row **Ping owner** button (disabled when unassigned). Adds happen by chat, not the Board.

## Flags
```
-Mode add|remove|list|digest|watch|ping   (default: list)
-Id N        work item id (required for add / remove / ping)
-Note "..."  optional note stored with an added item (shown under its title)
-DryRun      render a preview to state/*.html; never send, never stamp/advance baseline
-Force       digest: resend even if already sent today
```
Manual:
```
pwsh -NoProfile -File .copilot/skills/run-ado-item-tracker.ps1 -Mode add -Id 12345 -Note "SDK fix"
pwsh -NoProfile -File .copilot/skills/run-ado-item-tracker.ps1 -Mode digest -DryRun -Force
```

## Schedules
- **DM-AdoTrackerDigest** &mdash; weekly, **Sun&ndash;Thu 09:00 IST**, `-Mode digest`.
- **DM-AdoTrackerWatch** &mdash; interval **every 1h, 24/7**, `-Mode watch`.

## Voice
Digest, update, and ping emails all carry a short tracker-flavored joke and the shared `Get-NirvanaSignature` (Nirvana speaks on Nir's behalf), appended automatically by `Send-NirvanaMessage`. Honor `NOJOKE` / `NOSIG` if Nir adds them to a request.

## Graceful degradation
- No `az` token: digest/watch log + **exit 0** (no send, no stamp); add/ping exit 1; list falls back to the cache.
- Item missing from ADO (removed / no access): omitted from the table; surfaced in the digest footer.

## Never
- Never modifies ADO work items (read-only).
- Never emails anyone but Nir, except a **ping** to the item's `@microsoft.com` owner.
- Never advances the watch baseline or stamps the digest unless the send actually succeeded.
- Never pings an unassigned or external owner.

