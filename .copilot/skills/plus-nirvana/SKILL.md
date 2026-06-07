---
name: "plus-nirvana"
description: "Hand-off pattern: when Nir tags a Sent reply with the literal token `+Nirvana` (in subject or body), Nirvana picks it up from Nir's Sent Items, sends a polite ack ReplyAll to the original recipient(s) on the same thread saying that Nir and Nirvana will work on it together, creates a tracking PT-NNN in personal-todos, references that PT-NNN inline in the reply, and ends with a joke. Polled every 5 min by the DM-PlusNirvana scheduled task; also triggerable via 'process +Nirvana sent items', 'plus-nirvana', or '+Nirvana scan'."
---

# Skill: plus-nirvana

## Purpose
A lightweight CC-style hand-off. Nir is already on a thread (often replying from his phone in two seconds), and he wants Nirvana to take it from there. Instead of forwarding or asking Nirvana to "remind me about <subject>", he just types **`+Nirvana`** anywhere in his reply (top of body is cleanest) before he sends it. Nirvana then:

1. Detects the tag in Nir's **Sent Items** (the only place that reply lands for us to see).
2. Sends a polite **ReplyAll** on the same thread to whoever Nir was replying to, on Nir's behalf, acknowledging the ask and saying *"Nir and I will work on it together and circle back"*.
3. Creates a **PT-NNN** in `reports/personal-todos/todos.md` (category=`work`) so the follow-up is tracked.
4. References that **PT-NNN** inline in the ack body so the recipient (and Nir's future self) has a stable handle.
5. Ends the body with a short, on-topic joke (per house style).
6. Stamps the Sent item with the user property `NirvanaPlusProcessed` so the same reply is never re-fired.

The token is unusual enough (`(?i)\+nirvana\b`) that false positives are not a concern. If Nir wants to mention the agent in prose without triggering, he just doesn't prepend a `+`.

## Fixed context
- Trigger token (regex, case-insensitive): `\+nirvana\b` &mdash; matches `+Nirvana`, `+nirvana`, `+NIRVANA`, etc.
- Trigger surface: subject OR body of items in Nir's **Sent Items** folder (`olFolderSentMail` / index 5).
- Look-back window: **last 7 days** of Sent Items (we don't want to retroactively act on ancient replies; if Nir really needs that he can pass `-EntryID`).
- Idempotency: `UserProperty` named `NirvanaPlusProcessed` (timestamp) stamped on the Sent item after a successful send. Re-runs skip stamped items.
- PT-NNN writer: `.copilot/skills/personal-todos/add-item.py` (the mandatory helper). Title is `Follow up with <FirstName> on: <cleaned-subject>`, category=`work`, priority=`M`, no due. Notes include the SentOn timestamp + the recipient's display name + smtp.
- Log: `reports/plus-nirvana/YYYY-MM-DD.md` (one line per fire).
- Reply HTML uses `Get-NirvanaSignature -Variant InboxAuto` (auto-reply disclosure included) and prepends to the quoted history Outlook generates from `ReplyAll()`. Subject keeps its native `Re:` chain &mdash; **no `[Nirvana] -` prefix** on replies.

## Audience guardrail
**Every recipient on the resulting ReplyAll must be `@microsoft.com`.** If any recipient is external or unresolvable, abort that item with `skipReason=non-microsoft-or-unresolved-recipient`. We mirror the conservative posture inbox-watch uses for the same reason: a stranger-on-the-thread accidentally getting auto-replies on Nir's behalf is the kind of mistake we never want to make.

## What it must NOT do
- **Never** modify ADO, Teams, the wiki, repos, pipelines, or anything outside Outlook + `reports/`. The same hard rule as inbox-watch: a `+Nirvana` tag is a hand-off acknowledgement, not an authorization to take real-world action.
- **Never** act on Sent items older than 7 days unless explicitly given an `-EntryID`.
- **Never** ReplyAll if the audience guardrail trips. **Never** strip recipients to "work around" the guardrail.
- **Never** send if Outlook is not running or PowerShell is elevated &mdash; abort with a clear message.
- **Never** auto-launch Outlook from this skill (runner-prelude handles that for the scheduled task path).
- **Never** call into write-mode sub-skills (sprint-create, pbi-assign-tasks, post-to-teams, etc.). Read-only summarizers (codebase Q&A, team-personas read) are fine if needed for the ack wording, but the v1 body is a fixed acknowledgement and doesn't need them.

## Trigger phrases (interactive)
- "process +Nirvana sent items"
- "scan +Nirvana"
- "plus-nirvana"
- "+Nirvana scan"

Plus the scheduled task DM-PlusNirvana fires it automatically every 5 min, 24/7.

## Inputs the runner accepts
- `-DryRun` &mdash; do everything except sending the ack and adding the PT (prints the planned body + the PT-NNN placeholder).
- `-WhatIf` &mdash; alias for `-DryRun` semantics around side effects (kept for parity with PS idiom; both skip writes).
- `-EntryID <id>` &mdash; process a specific Sent item by its Outlook EntryID instead of scanning the recent window. Useful for tests and for "process the one I just sent".
- `-Force` &mdash; ignore the idempotency stamp and re-fire (the original Sent item gets its `NirvanaPlusProcessed` value updated; the ack is sent again).

## Steps

1. **Preflight.** Outlook running? Not elevated? Otherwise exit 0 with a clear log line. The runner is invoked by the DM-PlusNirvana scheduled task &mdash; quiet exits are normal.
2. **Find candidates.** Either the single item by `-EntryID`, or iterate `Sort('[SentOn]', $true)` Sent items, stop when `SentOn < now - 7d`, cap at 200 inspected. For each `Class == 43` (olMail), apply the **trigger guard** (see below).
3. **Trigger guard** (critical &mdash; prevents the scheduled task from looping on its own outputs). The token must appear in **either** the subject **or** the **first 200 characters** of the body. Nir's intentional tag always lives at the top of his reply, before Outlook's quoted-history separator. Once Nirvana sends an ack on a thread, the resulting Sent item carries `+Nirvana` only deep in the quoted history of the message we acked &mdash; without this guard, the next scheduled tick would treat that as a fresh trigger and ack again, ad infinitum.
4. **Idempotency.** Skip items already stamped with `NirvanaPlusProcessed` (unless `-Force`).
5. **Audience.** Iterate `$item.Recipients`. Resolve each via `GetExchangeUser()` &mdash; fall back to `PropertyAccessor` for `PR_SMTP_ADDRESS` (`0x39FE001E`). All To/CC must be `@microsoft.com`; bail otherwise with `skipReason=non-microsoft-or-unresolved-recipient`.
6. **Primary recipient.** First `Type == 1` (olTo) recipient's `Name` &mdash; first token is the salutation first name. If the first name doesn't resolve, fall back to "team".
7. **Create the PT-NNN.** Invoke `add-item.py` with category=`work`, priority=`M`, no due. Title `Follow up with <FirstName> on: <cleaned subject>`. Notes include SentOn timestamp + recipient display name + smtp + the literal phrase `Tagged via +Nirvana`. Parse the PT-NNN out of the first TSV stdout line. **CRITICAL: the helper function that wraps `add-item.py` MUST use `Write-Host` (not `Write-Output`) for its progress echoes.** `Write-Output` inside a PS function joins the function's return value, so `$ptId = Add-PtItem ...` would return an array of `[progress-line, PT-NNN]` instead of a clean string &mdash; and interpolating that array into the email body produced the 2026-05-17 garbled-ack incident (the `py> PT-NNN ... work M due=- PT-NNN` debug noise that landed in three senior inboxes before the bug was caught). If add-item fails or doesn't return a PT-NNN, log a warning and use `PT-UNKNOWN` &mdash; the ack still goes out, because not sending it would leave the recipient hanging.
8. **Compose the ack.** Plain HTML, three short paragraphs: salutation, "Nir and I will pick this up together and circle back. Tracking on our side as `<PT-NNN>`." + joke + Nirvana sign-off. Append `Get-NirvanaSignature -Variant InboxAuto`.
9. **Send.** `$reply = $sentItem.ReplyAll(); $reply.HTMLBody = $newHtml + $reply.HTMLBody; $reply.Send()`. Do **not** add `[Nirvana] -` to the subject &mdash; Outlook keeps the `Re:` chain.
10. **Stamp + log.** `UserProperties.Add('NirvanaPlusProcessed', 1, $false)` with the ISO timestamp; `Save()`. Append one log line to `reports/plus-nirvana/YYYY-MM-DD.md`:
    ```
    - HH:mm sent="<sentOn>" to=<primary-smtp> cc=<comma-csv> pt=<PT-NNN> subject="<cleaned subject>"
    ```
11. **Migration mode.** If `Test-MigrationMode` returns true, build everything as normal but **skip `Send()`** and **skip the PT add** &mdash; print what would have happened. This matches the inbox-watch convention so a templatize-Nirvana dry run does not write live mail.

## Joke bank (v1)
Pick at random; reroll if it interpolates `PT-UNKNOWN`:
- "I asked a CDN for an inbox-zero strategy; it cached the question and ignored the prompt."
- "Why did the auto-reply join the gym? To work on its delivery times."
- "If a thread has a `+Nirvana` but no PT-NNN, did it really happen? (Yes &mdash; here it is: `<PT-NNN>`.)"
- "Outlook tried to flag this as 'low priority'; I flagged Outlook as 'low context'."

The joke playbook is at `.copilot/skills/_shared/joke-playbook.md` &mdash; future-Nirvana, prefer pulling a concrete noun from the actual thread over the bank above.

## What about Reply (not ReplyAll)?
Default is ReplyAll because Nir's Sent reply already encodes the audience he wants. If he wants only the primary recipient to see the ack, he can ask for a runner flag later. Don't second-guess audience in v1.

## Future work (not v1)
- Strip the literal `+Nirvana` token from the quoted history (currently the recipient sees it in Nir's quoted body). Brittle string-edit; skipped for v1.
- Pull a body-relevant joke from the actual thread (LLM call). v1 uses the static bank.
- Resolver mode that runs sub-skills (codebase, team-personas) to draft a substantive answer instead of just an ack. v1 is ack-only on purpose &mdash; the §10b rule from inbox-watch (defer to Nir, never act) still applies.
- Detect `+Nirvana(<subject>)` syntax so Nir can override the PT title without re-typing the subject.

## Testing
End-to-end smoke: send yourself a mail, reply with `+Nirvana` at the top of the body, wait 5 min, observe:
1. New ReplyAll arrives in your inbox (or the recipient's) referencing `PT-NNN`.
2. `reports/personal-todos/todos.md` has a new `PT-NNN` row, category=`work`, notes carry the SentOn timestamp.
3. `reports/plus-nirvana/YYYY-MM-DD.md` has one new line.
4. Re-running the runner finds the same Sent item but skips it (`already-processed`).
5. Re-running with `-Force` re-fires and re-stamps.

