# Skill: sprint-report-daily

## Purpose
Write a daily markdown report on the state of the current sprint for the **Your Team**. Each Task and Bug counts as **1 unit** (no story points, no hour estimates).

## Fixed context
- Organization: `your-ado-org`, Project: `One`, Team: `Your Team`
- Report folder: `<repo>\reports\daily\`
- File name: `YYYY-MM-DD.md` (today's date, UTC or local — prefer local time)

## Steps

1. **Get current iteration** via `ado-work_list_team_iterations` (timeframe=current).
2. **Get all work items in that iteration** via `ado-wit_get_work_items_for_iteration` with team `Your Team`.
3. **Fetch full work item details** via `ado-wit_get_work_items_batch_by_ids` including fields: `System.Id, System.Title, System.WorkItemType, System.State, System.AssignedTo, System.Tags`.
4. **Aggregate:**
   - Total items (Tasks + Bugs only)
   - Counts by State: `New`, `Active`, `Resolved`, `Closed`, `Removed`
   - Counts by Assignee × State (matrix)
   - Completion % = `(Resolved + Closed) / Total`
   - Days remaining in sprint (count working days Sun–Thu only, excluding today)
5. **Write markdown** to `<repo>\reports\daily\YYYY-MM-DD.md`:

```md
# Sprint <name> — Daily Report <YYYY-MM-DD>

Sprint window: <startDate> → <finishDate>  · Working days left: <N>

## Summary
- Total items: <N>   (Tasks: <t>, Bugs: <b>)
- Completed: <c> (<pct>%)   · In progress: <a>   · Not started: <n>
- Closed/Resolved since yesterday: <delta> (compare against previous day's file if present)

## By state
| State | Count |
|---|---|
| New | .. |
| Active | .. |
| Resolved | .. |
| Closed | .. |

## By person
| Assignee | Not started | In progress | Completed | Total |
|---|---:|---:|---:|---:|
| Alice | .. | .. | .. | .. |

## At-risk items
List items still in `New` or `Active` if working-days-left <= 3.

## Items table
| ID | Type | State | Assignee | Title |
|---|---|---|---|---|

## Nirvana's contributions
Always include this block — Nirvana is also one of Nir's directs (`team-personas/people/nirvana.md`), but she carries no ADO work items so she's not in the "By person" table. Source from `<repo>\reports\logs\*-<YYYY-MM-DD>.log`:
- **Emails sent today:** `<count>` (from `agent-todos`, `inbox-watch`, `team-milestones`, `personas-import`, `daily-summary-import`, `connect-buddy`, `send-email-from-todo`, runner heartbeats).
- **TODOs processed:** `<count>` (from `agent-todos-<YYYY-MM-DD>.log`).
- **Skills exercised:** `<comma-separated list>`.
- **Milestones / one-shot actions:** `<e.g., birthday reminder sent for X; PR reminder posted on #12345>`.
- One short joke or self-deprecating line about the day's work — same voice as the email joke.

Omit any sub-bullet whose count is zero. If the whole block would be empty, write `Nirvana was idle today.` instead of dropping the section.
```

6. Echo one-line summary to stdout: `Daily report written: <path>  (done <c>/<total>, <pct>%)`.

## Deltas
If yesterday's file exists, compute and include "Closed/Resolved since yesterday". If not, omit that line.

## What NOT to do
- Do **not** modify any work items.
- Do **not** include Story Points or Original Estimate — we count 1 unit per item.
- Do **not** prompt the user.


