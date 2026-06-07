# pr-review-request — Thread Updates (design & flow contract)

> **Status:** runner side is built and shipped **inert** (feature-flagged off). One small
> Power Automate change is required before flipping the flag on. Until then the runner only
> does what it always did: post the initial "please review" message.
>
> Flip it on by setting `enabled: true` in
> `.copilot/skills/pr-review-request/thread-updates.config.json`.

## What this adds

Today the skill posts ONE Teams message when a direct (or Nir) opens a PR. This extends it
so the **same Teams thread** gets a short update when that PR reaches two later milestones:

1. **First human review** — a teammate has voted on, or commented on, the PR. The update
   **names the reviewer and their outcome** (e.g. "&#9989; Approved by Teammate65",
   "&#9940; Changes requested by &hellip;", "&#128172; Reviewed by &hellip;").
2. **Completed** — the PR is merged (`completed`) or closed without merge (`abandoned`).

Each milestone is announced **once**.

Both updates also carry **stats & gamification** lines (see *Stats & gamification* below): a
time-to-first-review / time-to-merge figure compared to our **p50 (median) baseline**, plus the occasional
creative callout when a reviewer is on a roll.

> **Signed:** by Nir's request (2026-06-03) every status update carries a compact Nirvana
> sign-off line (canonical wording from `_shared/signature.ps1`), overriding the usual
> "Teams posts are unsigned" convention for this skill only.

## How it works (simplified)

The runner does **not** track the Teams message id and needs **no** OneDrive ledger. When a
tracked PR transitions, the runner sends a plain **PR Status Update** trigger email:

```
Subject: [Nirvana][PR Status Update][12345
Body:    <short Teams update HTML, taken verbatim into the thread>
```

Note the subject has **no trailing `]`** — that is deliberate so the flow can extract the PR
id with a single expression:

```
prId = last(split(triggerOutputs()?['Subject'], '['))   // -> "12345"
```

Nir's own Power Automate flow owns the correlation: it remembers the parent Teams message for
each PR id (captured at post time) and reposts the email body as a reply to that thread. The
runner side is intentionally dumb — detect a transition, emit `[Nirvana][PR Status Update][<prId>`
with the body, done.

> Why no ledger / message id on the runner side? Teams posting is **email → Power Automate →
> Teams connector**, one-way; the trigger email never gets the Message Id back. Rather than
> round-trip the id through a synced OneDrive file, Nir's flow stores the id keyed by PR id and
> looks it up itself. That removes the ledger, the base64 id encoding, and the `PRCorr`/`MsgId`
> subject tokens entirely.

---

## Power Automate — add the update flow

- **Trigger:** *When a new email arrives*, **Subject Filter** = `[PR Status Update]`.
  - The new-PR post emails use the subject token `NirvanaTeams` and never contain
    `[PR Status Update]`, so the two flows never cross-fire.
- **Steps:**
  1. `prId = last(split(triggerOutputs()?['Subject'], '['))`.
  2. Look up the parent Teams **Message Id** you stored for `prId` (your own store — e.g. a
     Dataverse/SharePoint/Excel table written by the post flow).
  3. **Microsoft Teams → Reply with a message in a channel**, Message Id = the parent, Message
     = the email **Body**.

The existing post flow is unchanged.

---

## Runner state machine (already built)

`state/posted.json` is schema v2. Each entry:

```json
{
  "id": 12345,
  "repo": "Engineering",
  "repoId": "8f1c...d2",
  "author": "Jane Doe",
  "title": "Fix flush race",
  "prUrl": "https://dev.azure.com/your-ado-org/One/_git/Engineering/pullrequest/12345",
  "createdAt": "2026-06-03T08:00:00Z",
  "postedAt": "2026-06-03T08:05:00Z",
  "threadState": "posted",
  "firstReviewedAt": null,
  "terminalState": null,
  "terminalAt": null
}
```

`threadState` walks `posted -> first-reviewed -> (completed | abandoned)`. A fast PR can jump
straight from `posted` to a terminal state (it just gets the completion update, no review
update).

Each tick, **after** the normal post pass and **only when the feature flag is on**, the
runner runs a track pass over every `posted.json` entry that is not yet terminal:

1. **Fetch the PR by id** (`GET .../pullrequests/{id}`) — this works even after the PR leaves
   the active-creator query, so completions are still detected.
2. **Terminal first:** if `status` is `completed` or `abandoned` -> send the completion update,
   set `threadState`/`terminalState`/`terminalAt`.
3. **Else first review:** if `threadState == posted` and a **non-author, non-container**
   reviewer has `vote != 0`, **or** (when `detectFirstReviewVia` includes `comments`) a PR
   thread has a non-author, non-system comment -> send the first-review update, set
   `threadState = first-reviewed`. The update body **names the first reviewer and maps their
   vote to an outcome** (10 approved / 5 approved-with-suggestions / -5 waiting / -10 changes
   requested; a comment-only review reads "Reviewed by &lt;name&gt;").

State for a transition is written **after** the update email is sent (mirrors the existing
post pass: favors never-miss over never-duplicate). The 5-min task uses
`MultipleInstances = IgnoreNew`, so ticks never overlap.

### First-review proxy — known limits
- **Votes** catch approve / approve-with-suggestions / waiting / reject.
- **Comments** (enabled by default via `votes+comments`) catch comment-only reviews.
- Auto-added **group** reviewers (`isContainer = true`) and the **author's own** vote/comments
  are excluded.

---

## Stats & gamification

Both update messages get up to two extra lines, sourced from the pure module
`.copilot/skills/pr-review-request/stats.ps1` and persisted in `state/review-stats.json`.

### Lines you'll see

- **First-review update** — a *speed* line:
  - `&#9889; Fast review! 23m to first look.` (fast = within **30 min**, or within **60%** of our
    baseline), otherwise `&#128202; 1h 5m to first review`.
  - When we have history it adds the comparison: `&mdash; 46% faster than our typical 7h.` /
    `&mdash; right around our typical 7h.` (within 10%) / `&mdash; 25% slower than ...`.
  - Plus an optional **gamification** badge (at most one, highest-priority):
    - weekly &ge; 10 &rarr; "absolute machine!"; weekly &ge; 5 &rarr; "Reviewer of the Week pace!"
    - daily &ge; 5 &rarr; "on fire"; daily == 3 &rarr; "Hat-trick!"
    - week leader with 3&ndash;4 &rarr; "this week's top reviewer"
    - career total hitting 25 / 50 / 100 / 250 &rarr; "legend!"
- **Completed update** — a *merge* line:
  `&#9201; Merged 3h after opening &mdash; 20% faster than our typical 1d 2h.`

"Reviews" for gamification means **first-review credits** (first responder), keyed by stable ADO
identity id when available (else normalized display name). Reviewer names are HTML-encoded.

### `state/review-stats.json`

```json
{
  "ttfr": { "samples": [42, 61, 18] },
  "ttm":  { "samples": [180, 240] },
  "baseline": {
    "ttfr": 419.05, "ttm": 1580.98,
    "ttfrSamples": 259, "ttfrEligiblePrs": 594,
    "ttmSamples": 493,  "ttmEligiblePrs": 493,
    "windowDays": 180, "source": "ado-6mo-p50",
    "computedAt": "2026-06-04T12:25:27Z"
  },
  "reviewers": {
    "<actorId-or-lowername>": {
      "displayName": "Teammate65",
      "total": 12,
      "daily":  { "2026-06-04": 3 },
      "weekly": { "2026-06-01": 7 }
    }
  },
  "processed": { "fr:12345": "2026-06-04T09:00:00Z", "ttm:12345": "2026-06-04T15:00:00Z" },
  "updatedAt": "2026-06-04T15:00:00Z"
}
```

- **Idempotency:** every folded event is recorded under `processed` (`fr:<prId>` first-review,
  `ttm:<prId>` time-to-merge). A re-tick that finds the key makes **no** stat mutation, so a crash
  between the stats write and the `posted.json` advance can't double-count.
- **Write order (deliberately different from `posted.json`):** stats are written **before** the
  Teams send; `posted.json` is written **after**. Combined with the `processed` keys this favors
  *never double-count* for stats while still *never missing* a transition.
- **Baseline = p50 (median), NOT the mean.** Comparisons read against `Get-PrBaseline`, which
  prefers the seeded `baseline.<metric>` block (median of the team's PRs over the last
  **180 days**, computed by `seed-baseline.ps1`) and falls back to the **median** of the rolling
  samples (`Get-PrStatMedian`) when no seed exists. The arithmetic mean (`Get-PrStatAverage`) is
  retained for reference but is never used as the baseline — it was too noisy on small samples
  (2 samples once read as a misleading "~24 min").
- **Seeding the baseline:** run `.copilot/skills/seed-baseline.ps1` on demand (`-DryRun` to preview,
  `-WindowDays` to change the lookback). It resolves the roster (self + directs), pulls every PR
  each member created in the window from ADO, derives TTFR (first non-author thread comment minus
  creation) and TTM (closed minus creation, completed PRs only), computes the p50 of each, and
  writes the `baseline` block via `Set-PrBaseline` — preserving the live `samples`, `reviewers`,
  and `processed` state. Because ADO exposes no vote timestamp, historical TTFR is the *first human
  comment* approximation; `ttfrEligiblePrs` vs `ttfrSamples` makes the coverage gap visible.
- **Auto-refresh (keeps the baseline current):** the seed is **re-run weekly** by the
  **DM-PrBaselineReseed** scheduled task (Sun 07:15 IST). Each run recomputes the p50 over the
  *trailing* 180 days, so the window slides forward and the quoted "typical" tracks the team's
  evolving pace instead of staying frozen at the first seed. `baseline.computedAt` shows when it was
  last refreshed. The robust 180-day seed (hundreds of samples) is deliberately preferred over the
  tiny live rolling window for the quoted number — the rolling window only becomes the baseline if
  no seed has ever been written.
- **Baseline is read before the new sample is added**, so a PR never compares against itself.
- **Rolling window:** last **100** samples per metric. Day/week buckets are local-time; durations
  are computed in UTC. Week key = that week's **Monday** (`yyyy-MM-dd`).
- **Pruning** (`Optimize-PrReviewStats`): `processed` keys &gt; 30 days and daily/weekly buckets
  &gt; ~8 weeks are dropped on each write.
- **Corrupt file = skip, don't wipe:** an unreadable `review-stats.json` returns `$null`
  (`Get-ReviewStatsSafe`) so the tick still sends the update *without* stats rather than
  overwriting history.
- **Fast-PR caveat:** a PR that jumps `posted` &rarr; terminal between ticks gets reviewer
  **credit** (gamification fairness) but **no TTFR sample** — there's no reliable first-review
  timestamp, so it would pollute the baseline.

---

## Config

`.copilot/skills/pr-review-request/thread-updates.config.json`

| field | meaning |
|---|---|
| `enabled` | master switch. `false` (default) = runner never sends update emails. |
| `updateSubjectPrefix` | subject prefix for update emails. Default `[Nirvana][PR Status Update]`. Final subject is `<prefix>[<prId>` with **no trailing `]`**. |
| `detectFirstReviewVia` | `votes`, `comments`, or `votes+comments` (default). |

## Go-live checklist
1. Build the update flow (trigger on subject contains `[PR Status Update]`); have the post
   flow store each PR's Teams Message Id keyed by PR id.
2. Open a throwaway PR, have someone vote -> expect an "in review" reply in the same thread,
   then complete it -> expect a "completed" reply.
3. Set `enabled: true`.

