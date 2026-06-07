# one-on-one-prep

**One sentence:** One business day before each 1:1 with a direct report, send the direct a Nirvana-voiced prep email (recent work, semester scope, suggested topics), let them reply, and persist the topics they raise back into the Board.

## Why this exists

Nir's 1:1s are higher-quality when:
1. **The direct knows what's coming.** A prep email lands ~24h before the meeting, surfacing what they worked on, where the team's heading, and 3-5 candidate topics. They walk in with thoughts, not surprises.
2. **The direct can contribute the agenda.** They reply with their own topics; those become real ON-NNN items in `reports/one-on-ones/<slug>.md` so Nir sees them on the Board the next time he opens it.
3. **Nirvana does the legwork.** Recent PRs / commits / threads / standing scope all come pre-stitched, so neither side wastes the first 15 minutes catching up.

## Fixed context

| Resource | Path |
|---|---|
| Skill folder | `.copilot/skills/one-on-one-prep/` |
| Runner | `.copilot/skills/run-one-on-one-prep.ps1` |
| Helpers (PS) | `.copilot/skills/one-on-one-prep/helpers.ps1` |
| Impl (PS) | `.copilot/skills/one-on-one-prep/one-on-one-prep-impl.ps1` |
| State (sent index) | `reports/one-on-one-prep/state/sent.txt` |
| Daily log | `reports/one-on-one-prep/<YYYY-MM-DD>.md` |
| Direct list (truth) | `reports/directs-scope/scope-board.md` (col 0 of `## Open`) |
| Persona SMTPs | `.copilot/skills/team-personas/people/<slug>.md` |
| 1:1 markdown files | `reports/one-on-ones/<slug>.md` |
| HTML renderer | `.copilot/skills/_shared/investigation-email.ps1` |
| Signature | `.copilot/skills/_shared/signature.ps1` (`Get-NirvanaSignature -Variant InboxAuto`) |

## Scheduled cadence

Single Windows Scheduled Task **`DM-OneOnOnePrep`**:
- Runs **once daily at 08:00 IST**.
- Scans the **next 14-42 hours** of the Outlook calendar, so an 08:00 Monday tick picks up every 1:1 scheduled for Tuesday (00:00-23:59 IST). Per-tick cap raised to **20** so a full day's worth of 1:1s never gets truncated.
- One process does both jobs:
  - **Send** prep email for each upcoming 1:1 in that window (with a recognized direct, &le; 3 attendees) that hasn't been prepped this cycle.
  - **Watch** for replies on prep emails sent in the last 7 days, extract topics, append them as ON-NNN items.

Ad-hoc invocations (`pwsh run-one-on-one-prep.ps1`) preserve the historical 22-26h, cap=5 defaults so manual runs still behave like a ~24h heads-up. The scheduled task explicitly passes `-SendHoursMin 14 -SendHoursMax 42 -PerTickCap 20`.

## When it fires (send path)

For each Outlook calendar item in the configured window:
1. Subject matches `(?i)1[:\s-]?1|one[\s-]?on[\s-]?one|catchup|catch-?up|sync` AND
2. Attendee count is **&le; 3** (real 1:1, not a team sync that just contains the word "sync") AND
3. Required attendees include exactly one of Nir's directs (SMTP match against `team-personas/people/<slug>.md`) AND
4. `state/sent.txt` does NOT already have an entry keyed by `(<slug>, <meeting-iso-start>)`.

On match: send the prep email to that direct (ToRecipients = direct's smtp; Nir on Cc).

## What's in the prep email

Rendered via `_shared/investigation-email.ps1` with `Eyebrow="1:1 prep"`. Sections:

1. **Hero**: "Heads-up for tomorrow's 1:1" + the direct's display name.
2. **TL;DR card**: 1-2 sentences synthesizing the standing scope (Now / Next from scope-board) and any salient signal (open ON items, recent PRs).
3. **Stat tiles** (1-4): "PRs opened (30d)", "Open agenda items", "Items closed last 1:1", "Days since last prep".
4. **Section: What's on your plate** - the scope-board "Now" + "Next" rendered as a clean card.
5. **Section: Recent threads (last 14 days)** - top inbound subjects (from `team-personas/people/<slug>.md` ledger if available, else `(none recorded by Nirvana)`).
6. **Section: Open follow-ups** - the open ON-NNN items in `reports/one-on-ones/<slug>.md`, rendered as a compact list.
7. **Recommendations (3-5)** - **"think deep here"**: Nirvana-suggested topics, each with a `Priority` chip and a 1-2 sentence justification synthesized from the inputs. The agent prompt is in `helpers.ps1::Build-OneOnOnePrepAgentPrompt`.
8. **Joke** + Nirvana signature (`-Variant InboxAuto`).

The body ends with a "reply with anything you want to add" CTA. The reply lands in Nir's Inbox; this same skill watches for it.

### Honoring `NOJOKE` / `NOSIG`

Per house style, the meeting subject or any user override carrying `NOJOKE` / `NOSIG` is respected. Default sends a joke + signature.

## Reply watcher (idempotent)

Every tick, scan Inbox for unread mail where:
- `ConversationID` matches a row in `state/sent.txt` written in the last 7 days, OR
- Subject begins with `Re: [Nirvana 1:1 prep]` and SenderEmailAddress is one of Nir's directs.

For each match:
1. Stamp Inbox item with UserProperty `NirvanaOneOnOnePrepReplyProcessed = <iso>` (idempotency).
2. Extract topics via `copilot --no-ask-user --model claude-opus-4.7-high` (stdin temp-file pattern - never `-p`):
    - Prompt: "Extract 1-5 discrete discussion topics from this reply. Each topic is one line, <=12 words, plain text, no bullets. Output JSON: `{topics: [...]}`."
3. For each topic, run `one-on-one-agenda/add-item.py` with `--opened-by <DirectDisplayName>` and `--summary <topic>` so it lands in `reports/one-on-ones/<slug>.md` as an `ON-NNN` item with `Status: Open`.
4. Send Nir a one-line confirmation email "I added <N> topic(s) raised by <DirectName> ahead of your 1:1" (signature + joke unless `NOJOKE`).
5. Append to the daily log: `<iso>  reply  slug=<slug>  topics_added=<N>`.

## Idempotency

| Concern | Key |
|---|---|
| Don't send twice per meeting | `state/sent.txt` line `<iso-sent>\t<slug>\t<meeting-iso-start>\t<conversation-id>` |
| Don't process the same reply twice | Outlook UserProperty `NirvanaOneOnOnePrepReplyProcessed` |
| Don't reply if the meeting was cancelled | Re-check the calendar item is still on the calendar at send time |

## Audience + safety guardrails

- **@microsoft.com only.** A direct without a resolvable smtp is logged and skipped (never sent externally).
- **No CC blast.** ToRecipients = the one direct. Nir on Cc.
- **Skip if the meeting was created <6h ago** (avoid ambushing same-day-scheduled 1:1s).
- **Never edit the direct's mail folder.** Reply path reads only; new ON-NNN items go to `reports/one-on-ones/<slug>.md` via `add-item.py`.
- **`-DryRun` / `-WhatIf`** rendering is always supported - the renderer prints the HTML body and the planned recipients but does NOT touch Outlook.

## Cross-skill composition

- Reads scope-board via `nirvana-board/directs.py::resolve_directs`.
- Reads recent thread subjects from `.copilot/skills/team-personas/people/<slug>.md` (the ledger appended by `team-personas` import jobs).
- Uses `_shared/investigation-email.ps1` for the HTML.
- Uses `_shared/signature.ps1` for the signature.
- Uses `_shared/run-hidden.vbs` to fire from Windows Scheduled Task without a flashing console window.
- Adds items via `one-on-one-agenda/add-item.py` (the canonical writer).

## Steps the impl performs

1. Resolve directs (`directs.resolve_directs`).
2. **Send loop:** enumerate calendar items in (Now+22h, Now+26h); for each match, build the prep spec; render HTML; send via Outlook COM; append to `state/sent.txt`; stamp the Sent item `NirvanaOneOnOnePrep=<slug>|<iso>`.
3. **Reply loop:** scan Inbox unread filtered by ConversationID OR `Re: [Nirvana 1:1 prep]`; for each match, extract topics, add ON-NNN items, send Nir the confirmation, stamp `NirvanaOneOnOnePrepReplyProcessed`.

## What NOT to do

- Do not send to a direct without a resolvable smtp.
- Do not send the prep email twice for the same `(slug, meeting-iso-start)` tuple.
- Do not modify `reports/one-on-ones/<slug>.md` for anything except adding new `ON-NNN` items via `add-item.py`.
- Do not delete state/sent.txt entries automatically (let them age out via the 7d reply window).
