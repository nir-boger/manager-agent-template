# sprint-digest

A **weekly schedule-slippage email** for the team's current sprint, sent **to Nir only**. It answers one question fast: *are we on pace, and if not, where is the drag?*

This skill is deliberately distinct from its two neighbours:

| Skill | Output | Audience | Focus |
|---|---|---|---|
| `sprint-report-daily` | a daily **markdown file** (no email) | self-serve | full daily snapshot |
| `semester-plan-report` | an external **HTML dashboard** email | VP / A Peer / Your Manager | Feature/PBI semester plan |
| **`sprint-digest`** | a lean **email** | **Nir** | **pace / slippage** of the active sprint |

**Runner:** `.copilot/skills/run-sprint-digest.ps1`
**Renderers + pure math:** `.copilot/skills/sprint-digest/render.ps1`
**Scheduled task:** `DM-SprintDigest` — weekly, **Sundays 09:00 IST** (start of the Sun-Thu work week).
**State:** `.copilot/skills/sprint-digest/state/` (gitignored) — idempotency, per-iteration baseline, last snapshot.

## Trigger phrases -> mode

| User says | Mode |
|---|---|
| "sprint digest", "send the sprint digest", "send the sprint digest now", "sprint-digest" | **Send now** (on-demand) |
| "how is the sprint pacing", "are we behind this sprint", "sprint pace", "sprint slippage" | **Send now** (on-demand) |

On-demand runs use `-Force` so they ignore the once-per-week idempotency gate. Prefer `-DryRun` first if Nir wants a preview without sending.

## What it measures

Source: the **current iteration** for `Your Team` (ADO, via `az` token). Scope for pace math is **Task + Bug only**; PBIs and any **Removed/Cut** items are excluded from the denominator.

The team's Task workflow is **To Do / In Progress / In Review / Done** (not the classic New/Active/Resolved/Closed), so state is classified into four buckets by `Get-WorkItemStateClass`:

- **done** — Done / Closed / Resolved / Completed
- **removed** — Removed / Cut (dropped from the denominator)
- **notstarted** — To Do / New / Proposed / Open / Approved
- **inprogress** — everything else still open (Active / In Progress / In Review / Committed / ...)

### Pace (the headline)
- **Time elapsed** = working days (Sun-Thu) from sprint start through *yesterday*, over total working days in the sprint. Today is not yet "worked", so it is excluded; the value is clamped to [0, 100%].
- **Work done (current scope)** = `done / (Task+Bug not removed)` at this moment.
- **Work done (baseline scope)** = `done / baseline` where **baseline** is the set of Task+Bug IDs snapshotted on the **first run for this iteration** (stored at `state/baseline-<iterationId>.json`). This shows progress against the originally-committed scope and surfaces **scope growth** ("N added since sprint start").
- **Verdict** (`Get-PaceVerdict`, gap = elapsed - done): gap <= 5% -> **On track** (or Ahead); <= 20% -> **Behind**; otherwise **Well behind**.

### Sections in the email
1. **Pace ribbon** — verdict badge, working days left, the three pace lines above.
2. **Not started** — open Task/Bug still in a not-started state, with assignee (the clearest slip signal). Capped at 20 rows.
3. **By person** — not-started / in-progress / done / total per assignee, sorted by not-started then total.
4. **Since last digest** — delta vs the previous digest's snapshot (same iteration only): **completed / added / removed / reopened**. First digest of a sprint says so instead.

## Idempotency & state

- **Idempotency key:** `"<iterationId>|<sunday-week-start>"`, appended to `state/last-sent.txt` only **after a successful send**. A new sprint or a new week produces a new key, so it fires again; re-runs in the same window are skipped (unless `-Force`).
- **Baseline:** `state/baseline-<iterationId>.json` — written once, on the first non-DryRun run for that iteration.
- **Snapshot:** `state/last-snapshot.json` — per-ID `{state,type,assignee,title,class}`, overwritten on each successful send; drives the next digest's delta.

## Flags

```
-DryRun     fetch + compute + log + write state/preview.html, but do NOT send and do NOT stamp state
-Force      bypass the per-iteration-per-week idempotency check
-AsOfDate   override "today" (YYYY-MM-DD) for testing pace/elapsed math
```

Manual run:
```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-sprint-digest.ps1 -DryRun -Force
```

## Graceful degradation (never stamps on a non-result)

- **No current iteration** -> log + exit 0, no stamp.
- **Iteration missing start/finish dates** -> can't compute pace; log + exit 0, no stamp.
- **Zero work items** -> log + exit 0, no stamp (never calls an empty sprint "behind").
- **`az` missing or token failure** -> log FATAL + exit 1.
- **Before sprint start** -> elapsed days = 0. **After finish** -> elapsed clamps to total (100%).

## Voice

Every send carries a real sprint/schedule-flavored joke and the shared `Get-NirvanaSignature` (Nirvana speaks on Nir's behalf). Honor `NOJOKE` / `NOSIG` tokens if present in the request.

## Cross-skill

When the digest shows an item or workstream genuinely at risk of slipping the sprint, open a tracked risk in **`risk-watch`** (`add a risk: <text>`) so it gets a RAG, an owner, and a checkpoint in the weekly pulse — the digest reports pace; risk-watch carries the named risks forward. (Not automated in v1; surface it in the summary to Nir.)

## Never

- Never modifies ADO work items (read-only).
- Never sends to anyone but Nir.
- Never stamps idempotency / writes the snapshot unless the send actually succeeded.

