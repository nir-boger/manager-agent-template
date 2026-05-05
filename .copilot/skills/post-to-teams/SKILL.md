# Skill: post-to-teams

## Purpose
Post a message to the **Your Team** Teams channel via the **email-triggered Power Automate flow**. The flow "Nirvana - Email to Teams" listens for Nir's own emails tagged `NirvanaTeams` in the subject and posts the HTML body into the configured channel.

## Why email and not a webhook
- Tenant DLP policy `CSEO-Medium Isolated` blocks the `HttpRequestReceived` trigger → direct Power Automate HTTP webhooks are permanently suspended.
- Incoming Webhook connectors are also disabled in this tenant.
- Outlook → Power Automate → Teams is the only path that works here. Don't try the webhook approaches again.

## Fixed context
- **Trigger mailbox**: `youralias@microsoft.com` (Nir — must be the From *and* To)
- **Subject tag**: the subject **must contain `NirvanaTeams`** somewhere. **NO square brackets** (e.g. `[NirvanaTeams]`) — brackets break Power Automate's V3 email-trigger subject filter and the flow never fires.
- **Latency**: ~1–3 minutes between send and channel post.
- **Log file**: `<repo>\reports\teams\YYYY-MM-DD.md` (append one line per post)

## Hard prerequisite
Outlook desktop must be running. If not, abort with a clear message — do not auto-launch.

```powershell
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    throw 'Outlook is not running. Please start Outlook and retry.'
}
```

## Trigger → action mapping
| User intent | Action |
|---|---|
| "post to teams", "post to the team channel", "teams message", "tell the team on teams" | **post** the supplied content |
| "post the daily report to teams" | **post** today's `<repo>\reports\daily\YYYY-MM-DD.md` rendered as HTML |

## Inputs
- `Message` — required. Plain text, Markdown, or a path to a Markdown file.
- No recipients, no subject customization, no attachments. This skill posts to **one** channel only (whichever channel the flow is wired to).

## Steps

1. **Preflight**: confirm Outlook is running (see above).
2. **Resolve the body** into an HTML fragment:
   - Markdown file → read, convert to simple HTML (preserve headings, lists, tables, code blocks), wrap in `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">…</div>`.
   - Inline markdown → same conversion.
   - Plain text → escape HTML entities, wrap paragraphs in `<p>`.
   - **Do NOT append the Nirvana signature.** Teams posts are unsigned by user preference. (Emails via the `email-team` skill still keep the signature.)
3. **Preview-before-send** (mandatory if the body was auto-generated from a file OR is longer than 20 lines). Show the first ~15 lines and wait for the user's explicit "post" / "yes". Skip preview if the user supplied the body inline and it's short, or explicitly said "post now".
4. **Derive a subject**. Must contain `NirvanaTeams`. Format:
   ```
   NirvanaTeams <one-line summary, max ~60 chars>
   ```
   Example: `NirvanaTeams Daily report 2026-04-23`.
5. **Send the trigger email via Outlook COM**:
   ```powershell
   $ol   = New-Object -ComObject Outlook.Application
   $mail = $ol.CreateItem(0)              # 0 = olMailItem
   $mail.To       = 'youralias@microsoft.com'
   $mail.Subject  = $Subject               # must contain 'NirvanaTeams', no brackets
   $mail.HTMLBody = $Html
   $mail.Send()
   [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
   [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
   ```
6. **Log** one line to `<repo>\reports\teams\YYYY-MM-DD.md`:
   ```
   - <HH:mm> subject="<subject>" bytes=<N> status=queued  <optional:sourceFile>
   ```
   Create folder/file if missing.
7. **Tell the user**, one line only:
   `Teams message queued: "<subject>" — should post in ~1–3 minutes.`

## What NOT to do
- Do **not** add brackets or any other wrapping around `NirvanaTeams` in the subject. `[NirvanaTeams]`, `(NirvanaTeams)`, `<NirvanaTeams>` all break the trigger.
- Do **not** try to post via `$env:TEAMS_WEBHOOK_URL` — that path is blocked by tenant DLP. If the user asks why not, explain and stick with Option B.
- Do **not** append the Nirvana email signature. Teams posts must be unsigned.
- Do **not** send from/to anything other than `youralias@microsoft.com` — the flow's From+To filters require it.
- Do **not** delete or move the trigger email before the flow has had ~3 minutes to pick it up.
- Do **not** attach files.
- Do **not** modify any ADO work items as part of this skill.

## Troubleshooting
- **Nothing appeared in the channel after 3 minutes** → check the flow's Run history at https://make.powerautomate.com. Also verify the trigger email is still in **Inbox** (if the user or a rule moved it, the trigger may have missed it).
- **Flow shows runs but no channel post** → click the failing run, inspect the "Post message in a chat or channel" action for the error (usually the `messageBody` expression needs to be `@{triggerBody()?['Body']}` or similar, not a literal string).
- **Flow shows no runs at all** → re-check subject for brackets (most common cause), then check Outlook connector under Power Automate → Connections.

