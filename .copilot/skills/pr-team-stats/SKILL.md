---
name: "pr-team-stats"
description: "Generate a PR analytics report for Nir's team (all directs + Nir) over a configurable look-back window (default 6 months). Produces markdown + JSON + a self-contained HTML report with charts: PRs per week, PR completion time per week, first-human-review delay (hours) per week, and how many distinct team members reviewed PRs per week. Optionally scopes to PRs whose reviewer list includes 'Your Team'. On-demand via 'team PR stats', 'PR team report', 'create PR report'."
---

# Skill: pr-team-stats

## Purpose
On-demand PR analytics for Nir's org. For Nir plus every direct, it pulls completed/active PRs
from ADO over a look-back window and renders a single-file HTML report (plus markdown + JSON
sidecars) with per-week charts.

## Entry point
`.copilot/skills/run-pr-team-stats.ps1` &mdash; self-contained generator. Writes to
`reports/pr-team-stats/pr-team-stats-<timestamp>.{html,md,json}`.

## What it measures (all charted per week)
- **PRs per week** across the team.
- **PR completion time per week** (creation -> completion).
- **First human review delay (hours) per week** &mdash; time from PR creation to the first review
  vote/comment by a *human* (excludes the author, groups/containers, and bot/service accounts).
- **Distinct team reviewers per week** &mdash; how many members of Nir's team reviewed PRs.

## Roster & data source
- Roster: Nir (via ADO `_apis/connectionData`) + directs from
  `reports/directs-scope/directs-context.json`, resolved to ADO identity ids.
- PRs: `dev.azure.com/your-ado-org/One/_apis/git/pullrequests` per member.
- ADO auth: `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798`.

## Options
- Look-back window (default ~6 months).
- Optional filter to PRs whose reviewer list includes the **"Your Team"** group.

## Notes
- Read-only against ADO; never modifies work items or PRs.
- The report is for Nir (a manager) &mdash; charts and summaries, not raw JSON dumps.

