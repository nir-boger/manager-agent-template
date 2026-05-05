# Skill: sprint-create

## Purpose
Create the next 2-week sprint iteration for the **Your Team** and assign it to the team so it shows up on the task board. This runs on the Thursday before a new sprint begins.

## Fixed context (do NOT ask the user for these)
- Organization: `your-ado-org`
- Project: `One`
- Team: `Your Team`
- Iteration path pattern: `One\FY{YY}\Q{N}\2Wk\2Wk{NN}`
- Sprint length: 14 calendar days, **Sunday → Saturday** (team works Sun–Thu)
  - `startDate` = Sunday 00:00:00 UTC
  - `finishDate` = Saturday 14 days later, 00:00:00 UTC (mirrors how 2Wk22 is stored: Apr 19 → May 2)
- Microsoft fiscal year: FY starts **July 1**. FY26 = Jul 1 2025 – Jun 30 2026.
- Quarters: Q1=Jul–Sep, Q2=Oct–Dec, Q3=Jan–Mar, Q4=Apr–Jun
- Sprint numbers (`2WkNN`) run sequentially across the whole fiscal year; they do **not** reset each quarter.

## Steps

1. **Find the current sprint** using `ado-work_list_team_iterations` with `timeframe=current` for project `One`, team `Your Team`.
2. **Compute the next sprint:**
   - `nextNumber = currentNumber + 1`
   - `nextStart = currentFinishDate` (previous sprint's finishDate is the next sprint's startDate)
   - `nextFinish = nextStart + 14 days`
   - Determine the `FY{YY}\Q{N}` based on `nextStart`'s calendar month.
3. **Self-guard:** Only proceed if `nextStart` is within **4 days** of today. Otherwise, log "next sprint starts in N days — nothing to do" and exit.
4. **Check if iteration already exists:** Call `ado-work_list_iterations` with `project=One, depth=4`. If a node named `2Wk{NN}` already exists under the computed FY/Q path, **skip creation** and go to step 6.
5. **Create the iteration** with `ado-work_create_iterations`:
   - `project: One`
   - `iterations: [{ iterationName: "2Wk{NN}", startDate: "<ISO>", finishDate: "<ISO>" }]`
   - Note: the ADO API creates the node under the project root by default. If the tree requires placement under `FY{YY}\Q{N}\2Wk`, use the correct path via the underlying REST API if the MCP tool supports a parent path. If not, note this in the report and ask the user to move it.
6. **Assign to team** with `ado-work_assign_iterations`:
   - `project: One`, `team: Your Team`
   - `iterations: [{ identifier: "<newIterationId>", path: "One\\FY{YY}\\Q{N}\\2Wk\\2Wk{NN}" }]`
7. **Post to the team's Teams channel — always announce a new sprint** (best-effort; failures must NOT fail the skill).

   **Rule:** every successful run announces the next sprint exactly once. The only thing that suppresses a post is evidence we already posted for this sprint number. ADO state (whether the iteration node pre-existed or was just created) is **irrelevant** to the announcement decision.

   **Announcement gate (the only skip condition):** check `<repo>\reports\sprint-create.log` for any prior line matching `| 2Wk{NN} | ... | teams=posted`. If found → skip with `teams=skipped:already-announced`. If not found → post.
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
   - Send via Outlook COM exactly as in `post-to-teams/SKILL.md` step 5 (From=To=`youralias@microsoft.com`). **Do NOT call the post-to-teams skill interactively** — inline the COM send so there's no preview prompt.
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

8. **Append a summary** to `<repo>\reports\sprint-create.log` with timestamp, sprint name, dates, whether it was newly created or already existed, and the Teams post status (`teams=posted` / `teams=skipped:already-existed` / `teams=skipped:no-outlook` / `teams=failed:<reason>`).

## Output
- Write a one-line summary to stdout (useful for scheduled-task logs).
- Append full detail to `<repo>\reports\sprint-create.log`.

## What NOT to do
- Do **not** move unfinished work items from the previous sprint (the user handles that manually).
- Do **not** create child work items or modify any work items.
- Do **not** prompt the user — this skill runs non-interactively from Task Scheduler.
- Do **not** post to Teams if the log shows we've already posted for this sprint (`teams=posted` for `2Wk{NN}`).
- Do **not** let a Teams post failure abort the skill — the sprint creation is the primary deliverable.

