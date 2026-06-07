# team-agenda

Tracks the **Team Open Discussions agenda** — items the Your Team wants to discuss at WSR / syncs but hasn't worked through yet. Also runs a **weekly reminder** to Nir.

**Agenda file:** `reports/team-agenda/open-discussions.md` (markdown, hand-readable, source of truth).
**Scheduled tasks:**

- `DM-TeamAgendaReminder` — weekly, **Mondays 08:00 IST**, emails **Nir** the open list.
- `DM-TeamMeetingReminder` — weekly, **Tuesdays 14:00 IST** (30 min before the recurring "Team Meeting" at 14:30), emails **the team** (`team@example.com`) the open list. Runtime-confirms the meeting actually exists in Outlook before sending — skips silently if cancelled or moved.

**Runners:** `.copilot/skills/run-team-agenda-reminder.ps1`, `.copilot/skills/run-team-meeting-reminder.ps1`.

## Trigger phrases → mode

| User says | Mode |
|---|---|
| "add to (our|the) team (open discussions?\|agenda)", "add this to our agenda", "open an agenda item", "track this for WSR", "track this for next team meeting" | **Add item** |
| "what's on (our|the) (team )?agenda", "list open agenda (items)", "show team open discussions" | **List open** |
| "close agenda item TA-NNN", "mark TA-NNN closed", "we covered TA-NNN" | **Close item** |
| "remind me about (our|the) (open )?agendas?", "send me the agenda reminder now" | **Send personal (Mon) reminder now** |
| "send the team agenda reminder now", "preview the team meeting reminder", "test team meeting reminder" | **Send team (pre-meeting) reminder now** |
| "weekly agenda reminder", "every week remind me of (our|the) agenda" | **Set up / confirm schedule** |

## Modes

### Add item

1. Read `reports/team-agenda/open-discussions.md`.
2. Compute next free `TA-NNN` (max existing + 1, zero-padded to 3 digits).
3. Pick a **Kind**: `Discussion` (new topic to debate / decide / brainstorm) or `Follow-up` (revisit a previously-raised item — status check, next-step nudge, decision tracking). Default to `Discussion` if unsure; infer from Nir's phrasing ("track this follow-up", "next-meeting check-in" → Follow-up; "want to discuss", "let's brainstorm", "propose convention" → Discussion).
4. Append a new section under `## Open` with this template:

   ```markdown
   ### TA-NNN — <short title>

   - **Status:** Open
   - **Kind:** Discussion | Follow-up
   - **Opened by:** <name, default: Nir>
   - **Opened on:** YYYY-MM-DD (<context, e.g. WSR / 1:1 with X>)
   - **Owner:** TBD (or named owner if Nir says)
   - **Summary:** <one-paragraph problem statement, in Nir's voice>
   - **Why it matters:** <one-line stake>
   - **Next step:** <concrete next action — discuss, prototype, ask X>
   ```

5. Confirm to Nir: "Added TA-NNN — <title> (<Kind>). Now NN open items on the agenda (X discussion / Y follow-up)."

### List open

Parse the agenda. Show a one-line summary per open item: `TA-NNN — <title> (opened by X, YYYY-MM-DD)`. Don't dump full sections unless Nir asks.

### Close item

1. Locate `### TA-NNN` section.
2. Flip `Status:` to `Closed`. Add a `Closed on: YYYY-MM-DD` line.
3. Move the whole section to the `## Closed` section at the bottom.
4. Confirm: "Closed TA-NNN. NN open items remain."

### Send reminder now

There are two reminders. Pick the right one based on what Nir asked for.

**Personal Monday reminder (to Nir):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-team-agenda-reminder.ps1 -Force
```

`-Force` bypasses the per-week idempotency check.

**Team pre-meeting reminder (to `team@`):**

```powershell
# Preview (sends to Nir only, with [PREVIEW] subject):
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-team-meeting-reminder.ps1 -PreviewOnly -Force

# Real send (to the team):
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-team-meeting-reminder.ps1 -Force
```

`-Force` bypasses the meeting-presence check (so you can send without a Team Meeting in the next 60 min) and the per-instance idempotency. `-DryRun` builds the email and writes a preview HTML to `state/team-meeting-preview.html` without sending.

### Set up / confirm schedule

Two tasks:

- `DM-TeamAgendaReminder` — Mondays 08:00 IST (Israel time).
- `DM-TeamMeetingReminder` — Tuesdays 14:00 IST (30 min before the recurring "Team Meeting" at 14:30). The runner re-confirms the meeting exists in Outlook each fire, so single-instance cancellations are handled gracefully.

If Nir asks to move either schedule, edit via Task Scheduler:

```powershell
Set-ScheduledTask -TaskName 'DM-TeamAgendaReminder'  -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek <Day> -At '<HH:mm>')
Set-ScheduledTask -TaskName 'DM-TeamMeetingReminder' -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek <Day> -At '<HH:mm>')
```

If the team meeting itself shifts day/time, update the trigger and pass the new subject via `-MeetingSubject` if the title changes. The runner argument is set via the task's Action.Arguments.

## Parsing rules (for the runner)

- Item heading regex: `^###\s+(TA-\d{3})\s+—\s+(.+?)\s*$` (em-dash, not hyphen).
- Field regex: `^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$`.
- Known fields: `Status`, `Kind`, `Opened by`, `Opened on`, `Owner`, `Summary`, `Why it matters`, `Next step`, `Closed on`.
- An item is **Open** iff its `Status` field, case-insensitively, equals `Open`.
- `Kind` values: `Discussion` or `Follow-up` (case-insensitive; anything starting with `follow` counts as Follow-up; missing/blank → Discussion).
- Items under the `## Closed` section are always treated as Closed regardless of their `Status` field (defense-in-depth).

## Email format (weekly reminder)

- **Subject:** `[Nirvana] Team open discussions — <X follow-ups, Y to discuss>` (drops parts when one is zero; falls back to `nothing open` if no items).
- **Body:**
  - Short opener with total open count.
  - **Two HTML tables**, one per Kind: **Things to discuss** first, then **Follow-ups** (both tables show ID, Opened by/on, Item title + summary + next step). An empty Kind renders an italic empty-state line, not an empty table.
  - One-line joke (pulled from the runner's small pool; rotated). Honors `NOJOKE`.
  - Standard Nirvana signature (`Get-NirvanaSignature`). Honors `NOSIG`.

Shared renderer: `.copilot/skills/team-agenda/render.ps1` (functions `Render-TwoTableAgenda`, `Get-AgendaCounts`, `Format-AgendaSubjectTail`). Both runners dot-source it.

## Idempotency

Two state files, one per reminder:

- `.copilot/skills/team-agenda/state/last-sent.txt` — `DM-TeamAgendaReminder` (personal Monday). Holds the most recent ISO week tag (`yyyy-Www`) the reminder was sent for. Runner skips when the current week tag already appears, unless `-Force` is passed.
- `.copilot/skills/team-agenda/state/team-meeting-sent.txt` — `DM-TeamMeetingReminder` (team pre-meeting). Holds the ISO timestamp (`yyyy-MM-ddTHH:mm:ss…`) of every Team Meeting instance we have already emailed about. The runner skips a meeting whose start ISO is already in the file, unless `-Force` is passed.

## Empty state

When zero open items exist:
- **Personal Monday reminder (`DM-TeamAgendaReminder`):** still emails Nir a one-liner ("agenda is empty — no open items this week") so silence isn't ambiguous.
- **Team pre-meeting reminder (`DM-TeamMeetingReminder`):** skips the send entirely — we don't want to spam the team with empty-state mail. Use `-Force` if you ever want to push an empty-state notice to the team.

