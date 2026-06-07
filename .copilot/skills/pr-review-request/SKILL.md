---
name: "pr-review-request"
description: "Whenever a direct report (or Nir himself) opens a NEW pull request, post a 'please review' message to the team's Teams channel via the post-to-teams Outlook -> Power Automate flow. Only fires for PRs created at/after the baseline timestamp captured on first run ('from now onward', no backfill). Polled every 5 min by the DM-PrReviewRequest scheduled task; also triggerable via 'ask team to review new PRs', 'pr-review-request', or 'review request'."
---

# Skill: pr-review-request

## Purpose
Surface every new PR opened by Nir's team so it gets a reviewer fast. Each tick, Nirvana
finds the **active** PRs created by Nir or one of his directs **since a baseline** and, for
any it hasn't already announced, posts a single Teams channel message asking the team to pick
it up and review it. The baseline is set to "now" on the very first run, so the skill only
acts on PRs going forward &mdash; it never backfills six months of history.

## Fixed context
- **Roster** (whose PRs we watch): Nir himself (resolved via ADO `_apis/connectionData`,
  `authenticatedUser.id`) plus every direct in `reports/directs-scope/directs-context.json`
  (`.directs.<slug>.smtp/name`), each resolved to an ADO identity id via
  `vssps.dev.azure.com/.../_apis/identities?searchFilter=MailAddress`. directs-context.json is
  auto-refreshed by **DM-RefreshDirectsContext**, so a newly-added direct starts being watched
  automatically &mdash; no edit to this skill required.
- **PR query**: `dev.azure.com/your-ado-org/One/_apis/git/pullrequests?searchCriteria.creatorId=<id>&searchCriteria.status=active&$top=100&api-version=7.1`, per roster member.
- **Baseline**: `state/baseline.txt` (UTC ISO). Written **once** on first run (= now). Only PRs
  with `creationDate >= baseline` are eligible. Re-arm to "now" with `-ResetBaseline`.
- **Idempotency**: `state/posted.json` (append-only array of `{id, postedAt, ...}`). A PR id is
  recorded after a successful post and never announced again. Atomic writes (temp + `Move-Item -Force`).
  Entries are **schema v2** (adds `repoId, title, prUrl, threadState, firstReviewedAt,
  terminalState, terminalAt`) to support thread updates &mdash; see below.
- **Teams send**: reuses the **post-to-teams** mechanism &mdash; an Outlook COM email with the
  literal token `NirvanaTeams` (no brackets) at the start of the subject, From+To =
  `someone@example.com`, which the Power Automate V3 flow turns into a channel post (~1-3 min latency).
- **Safety cap**: at most `maxPerTick = 10` posts per tick (oldest first); the rest roll to the next tick.
- **Log**: `reports/pr-review-request/YYYY-MM-DD.md` (one line per posted PR).

## Message format
- Subject: `NirvanaTeams Review request: PR <id> by <author> | PRCorr:<repoId>_<id>` (the
  `NirvanaTeams` prefix is the flow trigger; the trailing `PRCorr:` token is legacy and
  ignored &mdash; harmless to the existing flow).
- Body (HTML, fields HTML-escaped, repo URL-escaped):
  - "&#128269; New PR needs a review"
  - Linked PR title -> `https://dev.azure.com/your-ado-org/One/_git/<repo>/pullrequest/<id>`
  - `Author: <name> . Repo: <repo> . PR #<id>`
  - "Please grab it and leave a review when you get a chance."
- Per Nirvana convention, **Teams posts carry no joke and no signature**.

## Eligibility rules
A PR is announced iff **all** hold:
1. Creator is on the roster (Nir or a current direct).
2. `creationDate >= baseline`.
3. `status == active` and **not a draft** (`isDraft == false`).
4. Its id is not already in `posted.json` (unless `-Force`).

## Known edges (by design)
- **Drafts are skipped** while in draft. When a draft is later published it is still active,
  unseen, and post-baseline, so it gets announced at that point &mdash; which is what we want.
- **Active-only query**: a PR that is created *and* completed/abandoned inside a single 5-min
  window is never seen, so it is never announced. Acceptable &mdash; such a PR needed no nudge.
- **No pruning**: `posted.json` grows append-only. Correctness over compaction; it stays tiny.

## Thread updates (feature-flagged, default OFF)
Beyond the initial "please review" post, the runner can post an update to **the same Teams
thread** when a tracked PR is **first reviewed** (a non-author, non-group reviewer votes or
comments) and when it is **completed** (merged) or **abandoned**. Each milestone is announced once.

- Updates are emitted as a plain trigger email with subject `[Nirvana][PR Status Update][<prId>`
  (**no trailing `]`**, so the flow extracts the id via `last(split(Subject,'['))`) and the
  Teams update text as the body. Nir's own Power Automate flow correlates to the original thread
  by PR id &mdash; the runner needs **no** message id and **no** OneDrive ledger. Full design +
  the exact Power Automate steps are in **[`THREAD-UPDATES.md`](./THREAD-UPDATES.md)**.
- Controlled by **`thread-updates.config.json`** (`enabled` default `false`). While off, the
  track pass is skipped entirely &mdash; no update emails. Flip `enabled: true` only after the
  update flow is live.
- Track state is recorded only after a successful send (favors never-miss over never-duplicate).
- **Stats & gamification**: each update also carries a time-to-first-review / time-to-merge line
  compared to our **p50 (median) baseline** &mdash; seeded from the team's PRs over the last 180
  days by `seed-baseline.ps1` (falls back to the rolling median, never the noisy mean) &mdash; plus
  the occasional creative reviewer callout (daily/weekly streaks, "Reviewer of the Week", career
  milestones). The `baseline` block is **re-seeded weekly** by **DM-PrBaselineReseed**, so the
  180-day window slides forward and the "typical" yardstick keeps tracking the team's current pace
  rather than freezing at first-seed (and without drifting on the tiny live window). Persisted in
  `state/review-stats.json` (rolling 100-sample window + auto-refreshed `baseline` block, idempotent
  per event, prunes itself). Pure logic lives in
  **`stats.ps1`**; full schema + thresholds are in **[`THREAD-UPDATES.md`](./THREAD-UPDATES.md)**.

## Triggers (on-demand)
- "ask team to review new PRs", "post review requests", "review request", "pr-review-request".
- On-demand the same idempotent logic runs immediately (use `-DryRun` to preview).

## Parameters
- `-DryRun` / `-WhatIf`: resolve and report what would post; **no** sends, **no** state mutation.
- `-Force`: ignore `posted.json` and re-post eligible PRs (still respects the baseline).
- `-ResetBaseline`: rewrite `baseline.txt` to now before scanning ("start from now" again).

## Schedule
- **DM-PrReviewRequest** &mdash; every 5 min, mirroring DM-PlusNirvana
  (`wscript.exe run-hidden.vbs run-pr-review-request.ps1`, PT5M / P3650D, PT10M limit,
  Interactive/Limited, IgnoreNew). The first tick establishes the "from now" baseline.
- **DM-PrBaselineReseed** &mdash; weekly (Sun 07:15 IST), `wscript.exe run-hidden.vbs
  seed-baseline.ps1` (PT30M limit, Interactive/Limited, IgnoreNew). Recomputes the trailing-180-day
  p50 TTFR/TTM baseline so the comparison yardstick keeps evolving with the team. On-demand:
  `seed-baseline.ps1 [-WindowDays N] [-DryRun]`.

## Never (hard prohibitions)
- Never announce a PR created before the baseline (no backfill).
- Never announce the same PR id twice (idempotency via `posted.json`).
- Never mutate `posted.json` or `baseline.txt` in `-DryRun`/`-WhatIf` or migration mode.
- Never add a joke or signature to the Teams message (post or thread-update).
- Never emit a `[PR Status Update]` email while `thread-updates.config.json`
  `enabled == false`, or in `-DryRun`/`-WhatIf`/migration mode.
- Never announce the same thread-update transition twice (idempotency via `threadState`).

