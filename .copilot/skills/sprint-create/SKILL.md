# Skill: sprint-create

## Purpose
Maintain a rolling window of pre-created 2-week sprint iterations for the **Your Team**, so engineers always have at least **~2 months of future sprints** to park work into. On every run the skill: (a) computes the set of sprints whose start date falls within the lookahead horizon, (b) ensures each one exists and is assigned to the team, and (c) announces only the imminent rollover (current+1) on Teams. Pre-creation itself is silent.

> Origin: feature requested by Teammate10 on 2026-05-10 ("pre-create all sprints for the foreseeable future" — engineers couldn't park future tasks like *Start FF flight* / *Check post-rollout logs*). Replaces the previous "next sprint only, gated by 4-day proximity" behaviour.

## Fixed context (do NOT ask the user for these)
- Organization: `your-ado-org`
- Project: `One`
- Team: `Your Team`
- Iteration path pattern: `One\FY{YY}\Q{N}\2Wk\2Wk{NN}`
- Sprint length: 14 calendar days, **Sunday → Saturday** (team works Sun–Thu)
  - `startDate` = Sunday 00:00:00 UTC
  - `finishDate` = Saturday 13 days later, 00:00:00 UTC
  - `nextStart` = previous sprint's `finishDate + 1 day` (e.g. 2Wk23 finishes Sat 2026-05-16, 2Wk24 starts Sun 2026-05-17)
- Microsoft fiscal year: FY starts **July 1**. FY26 = Jul 1 2025 – Jun 30 2026.
- Quarters: Q1=Jul–Sep, Q2=Oct–Dec, Q3=Jan–Mar, Q4=Apr–Jun
- Sprint numbers (`2WkNN`) run sequentially **within a fiscal year**; they reset to `2Wk01` at each FY boundary. The sprint that **starts** in a given FY belongs to that FY (a sprint that crosses the boundary stays under the FY/Q where its start date falls).
- **Lookahead horizon:** `LookaheadDays = 60` (≈ 2 months, ≈ 4–5 sprints). This is the rolling window the skill maintains. Override via env var `NIRVANA_SPRINT_LOOKAHEAD_DAYS` if a future caller needs a different value.

## Steps

1. **Find the current sprint** using `ado-work_list_team_iterations` with `timeframe=current` for project `One`, team `Your Team`. Capture `currentNumber`, `currentFinishDate`.
2. **Build the upcoming-sprint plan.** Starting from `currentFinishDate + 1 day`, generate consecutive 14-day Sun→Sat sprints until the next computed `startDate` is **strictly greater than `today + LookaheadDays`**. For each:
   - `number` = previous + 1, with FY rollover (when `startDate.month >= 7` and the previous sprint's start was June, reset `number` to `01` because we crossed into a new FY).
   - `startDate` (Sun 00:00 UTC), `finishDate = startDate + 13 days` (Sat 00:00 UTC).
   - `FY{YY}\Q{N}` derived from `startDate`'s calendar month (per the quarters table above).
   - Full path: `One\FY{YY}\Q{N}\2Wk\2Wk{NN}`.
3. **Inventory existing nodes.** Call `ado-work_list_iterations` with `project=One, depth=4` once and search the tree. Mark each planned sprint as either `exists-at-correct-path`, `exists-at-wrong-path` (e.g. accidentally at project root), or `missing`.
4. **For each planned sprint, in chronological order:**
   - **`exists-at-correct-path`** → no creation needed.
   - **`missing`** → call `ado-work_create_iterations` with `project=One, iterations=[{iterationName:"2Wk{NN}", startDate, finishDate}]`. The ADO MCP tool accepts only leaf names and may place under project root; on success, attempt the move via the iteration tree REST API if supported. If creation returns a permission error (TF50309 *"…lacks permissions: Create child nodes"*) or "No iterations were created", **swallow the error**, mark the sprint `create=failed:perms`, and add `(2WkNN, startDate, finishDate, fullPath)` to a `needsAdmin` list.
   - **`exists-at-wrong-path`** → log `placement=wrong:<actualPath>` and add it to `needsAdmin` so an admin can move it.
   - After successful creation (or for already-existing nodes), call `ado-work_assign_iterations` with `project=One, team="Your Team", iterations=[{identifier, path: fullPath}]`. Treat "already assigned" as success. If the path doesn't resolve (because the node sits at the wrong place), record `assign=skipped:bad-path` and continue — do not throw.
5. **Imminent-rollover announcement on Teams.** Identify the "next" sprint (`currentNumber + 1`). Post to the team channel **only for that one sprint**, exactly once across runs (idempotent on the existing `teams=posted` log gate). Pre-created sprints further out (current+2, +3, …) are **never** announced on Teams — pre-creation is silent.

   ### Thursday-before-start gate (MANDATORY — computed before any other skip check)
   The announcement must land **only on the Thursday immediately before the next sprint's Sunday `startDate`** — i.e. exactly `nextSprint.startDate - 3 days`. Posting early (e.g. on the first day of the current sprint, ~2 weeks ahead) or late is **worse than not posting at all**.
   - Compute `announceDate = nextSprint.startDate - 3 days` (the Thursday before its Sunday start).
   - Compare against **today in Asia/Jerusalem (Israel Standard Time / IDT)** — use the `TODAY (Asia/Jerusalem)` value injected by the runner, **not** UTC and **not** your own clock.
   - If `today != announceDate`, **suppress the Teams post for this sprint** and log `teams=skipped:not-thursday-before`. Continue with creation/assignment/logging as normal.
   - This gate fires **before** the awaiting-admin and already-announced checks below.

   Then, only if today **is** the Thursday-before-start, also skip announcement if:
   - The next sprint is in the `needsAdmin` list (no point announcing a sprint that doesn't exist yet) — log `teams=skipped:awaiting-admin`, OR
   - The log already has `| 2Wk{NN} | … | teams=posted` for that number — log `teams=skipped:already-announced`.

   When the Thursday-before-start gate passes and neither skip condition fires, post the announcement (idempotent — single line in the log gates all future runs).
   - Build the new-sprint taskboard URL:
     `https://your-ado-org.visualstudio.com/One/_sprints/taskboard/Your%20Team/One/FY{YY}/Q{N}/2Wk/2Wk{NN}`
     (Note: `Your%20Team` is space-encoded; the path after the team uses forward slashes.)
   - Subject (must contain `NirvanaTeams`, no brackets — see `post-to-teams/SKILL.md`):
     `NirvanaTeams New sprint 2Wk{NN} created`
   - HTML body template (single fragment, no signature, no preview prompt — non-interactive):
     ```html
     <div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">
       <p>🆕 <b>New sprint created: 2Wk{NN}</b> (Sun {startHuman} → Sat {finishHuman})</p>
       <p>📋 <a href="{url}">Open 2Wk{NN} taskboard</a></p>
       <p><b>Reminders:</b></p>
       <ul>
         <li>Please update <b>2Wk{prevNN}</b> to reflect the actual effort/status before it closes Saturday.</li>
         <li>Fill in <b>2Wk{NN}</b> — add tasks, estimates, and assignments.</li>
       </ul>
       <p><i>{joke}</i> 😄</p>
       <p>Thanks! 🙏</p>
     </div>
     ```
     - `{startHuman}` / `{finishHuman}` formatted like `May 3` / `May 16` (no leading zero, no year).
     - `{prevNN}` = `NN - 1` zero-padded to 2 digits.
     - `{joke}` = pick one (deterministic by sprint number, e.g. `pool[NN % len]`) from the rotating pool below. Sprint/agile-themed only.
   - Send via Outlook COM exactly as in `post-to-teams/SKILL.md` step 5 (From=To=`someone@example.com`). **Do NOT call the post-to-teams skill interactively** — inline the COM send so there's no preview prompt.
   - Preflight: if Outlook isn't running, **skip** the post (don't throw) and record `teams=skipped:no-outlook` in the log.
   - On any other exception, swallow it and record `teams=failed:<short reason>` in the log.
   - On success, also append the standard `post-to-teams` line to `<repo>\reports\teams\YYYY-MM-DD.md`.

   ### Joke pool (rotating, sprint/agile-themed, Kool to keep light)
   - `Why did the sprint go to therapy? Too many unresolved items from last cycle.`
   - `A scrum master walks into a standup. He says, "I'll keep this short" — six minutes later he's still talking.`
   - `Estimating in story points is easy: just pick a Fibonacci number and pretend you meant it.`
   - `Velocity is just trailing average regret, plotted on a chart.`
   - `Burndown charts: where hope meets reality, slowly, then all at once on the last day.`
   - `Two engineers walk into a retro. They find three action items from the last retro still open.`
   - `Why don't bugs respect sprint boundaries? Because they never read the definition of done.`

6. **Append a summary** to `<repo>\reports\sprint-create.log` — **one line per planned sprint** in the lookahead window — with timestamp, sprint name, dates, action (`created` / `already-existed` / `create=failed:perms` / `placement=wrong:<actualPath>`), assignment (`assign=ok` / `assign=skipped:bad-path`), and Teams status (`teams=posted` / `teams=skipped:not-thursday-before` / `teams=skipped:already-announced` / `teams=skipped:awaiting-admin` / `teams=skipped:not-imminent` / `teams=skipped:no-outlook` / `teams=failed:<reason>` / `teams=n/a` for the non-imminent pre-created sprints).

7. **Admin-alert email when `needsAdmin` is non-empty.** Best-effort, gated to fire **at most once per (sprint, calendar-day)** by scanning `sprint-create.log` for a line matching `alert=sent:YYYY-MM-DD:2Wk{NN}` for today's date and the missing sprint number.

   - To: `Your Name <you@example.com>` (CC nobody — Nir decides whether to forward to the project admin).
   - Subject: `[Nirvana] Sprint pre-creation needs admin — {N} sprint(s) outside lookahead window`
   - HTML body:
     ```html
     <div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">
       <p>The 2-month rolling lookahead detected the following sprint(s) missing under <code>One\FY{YY}\Q{N}\2Wk\</code>. The agent's account doesn't have <i>Create child nodes</i> permission on the iteration tree, so creation has to be done by a project admin.</p>
       <table style="border-collapse:collapse;font-size:13px;">
         <tr><th style="text-align:left;padding:4px 12px 4px 0;">Sprint</th><th style="text-align:left;padding:4px 12px 4px 0;">Dates (Sun → Sat)</th><th style="text-align:left;padding:4px 12px 4px 0;">Target path</th></tr>
         <!-- one row per missing sprint -->
       </table>
       <p>Once an admin creates them under the right path, the agent will pick them up on its next run (daily) and assign them to <b>Your Team</b> automatically. No Teams announcement until each sprint becomes the imminent next one.</p>
       <p><i>{joke}</i> 😄</p>
     </div>
     ```
   - Use the standard email helper (`_runner-email.ps1`) so the migration-mode kill switch + signature are honoured. The signature line *"Sent on Nir's behalf by Nirvana — Nir's agent."* is appended automatically; do not omit it.
   - On send success, append `| alert=sent:YYYY-MM-DD:2Wk{NN}` to the log line for each sprint in the alert.

## Output
- Write a one-line summary to stdout (e.g. `2Wk24,2Wk25,2Wk26 ok; 2Wk27 needs-admin; teams=skipped:already-announced`).
- Append per-sprint detail to `<repo>\reports\sprint-create.log` (multiple lines per run).

## What NOT to do
- Do **not** move unfinished work items from the previous sprint (the user handles that manually).
- Do **not** create child work items or modify any work items.
- Do **not** prompt the user — this skill runs non-interactively from Task Scheduler.
- Do **not** post to Teams for any sprint other than the imminent rollover (`current + 1`). Pre-creation is silent by design.
- Do **not** post to Teams on any day other than the **Thursday immediately before the next sprint's Sunday `startDate`** (`startDate - 3 days`, Asia/Jerusalem). Posting early (e.g. on the first day of the current sprint) or late is worse than not posting at all.
- Do **not** post to Teams if the log shows we've already posted for this sprint (`teams=posted` for `2Wk{NN}`).
- Do **not** let a Teams post or admin-alert email failure abort the skill — sprint pre-creation/assignment is the primary deliverable.
- Do **not** spam Nir with the admin-alert email — gate on `alert=sent:YYYY-MM-DD:2Wk{NN}` so it fires at most once per sprint per calendar day.
- Do **not** apply the previous "4 days proximity" self-guard — the rolling lookahead replaces it.

