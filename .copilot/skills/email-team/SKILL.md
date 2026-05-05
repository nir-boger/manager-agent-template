# Skill: email-team

## Purpose
Send an email **from the signed-in user's Outlook profile** to the **Your Team** alias (or other recipients) via **Outlook COM automation**. No tokens, no env vars, no app registration — the email sends through the running Outlook client exactly as if you clicked *Send* yourself.

## Fixed context
- Default recipient (To): `kdms@microsoft.com`
- Sender: whichever account is configured in the running Outlook profile (= you)
- Log folder: `<repo>\reports\email\`
- Log file: `YYYY-MM-DD.md` (append one line per send)

## Hard prerequisite
**Microsoft Outlook desktop must be running** on this machine when the skill fires. If it's not, the COM call will either fail or silently launch Outlook — detect that and abort with a clear message.

## Elevation preflight
Outlook always runs **non-elevated** (Medium integrity). If this PowerShell session is **elevated** (High integrity), `New-Object -ComObject Outlook.Application` will fail with `0x80080005 CO_E_SERVER_EXEC_FAILURE` because COM refuses to cross integrity levels.

Check up front and abort with a clear message — do not try to work around it:
```powershell
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isElevated) {
    throw "This PowerShell session is elevated. Outlook runs non-elevated, so COM will fail with 0x80080005. Please relaunch the agent / terminal as a standard (non-admin) user and retry."
}
```

## Optional env vars
| Variable | Purpose |
|---|---|
| `EMAIL_TEAM_ALIAS` | Override default To (defaults to `kdms@microsoft.com`) |
| `EMAIL_DEFAULT_CC` | Optional CC, comma-separated |

## Trigger → action mapping
| User intent | Action |
|---|---|
| "email the team", "send an email to the team", "email kdms", "mail out the daily report" | **send** to `kdms@microsoft.com` (or `$env:EMAIL_TEAM_ALIAS`) |
| "email <address>: <subject> — <body>" | **send** to the supplied address |
| "email the daily report" | **send** with today's `<repo>\reports\daily\YYYY-MM-DD.md` rendered as HTML |

## Inputs the skill accepts
- `To` — one or more addresses (default: team alias)
- `Cc` / `Bcc` — optional (semicolon-separated strings for Outlook COM)
- `Subject` — required; if the user didn't give one, derive from the first heading / report title, or ask once. **Always prepend `[Nirvana] - `** (skip if it already starts with that prefix).
- `Body` — plain text, markdown, or a path to a markdown report
- `Attachments` — optional file paths

## Steps

1. **Preflight: confirm Outlook is running.**
   ```powershell
   if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
       throw 'Outlook is not running. Please start Outlook and retry.'
   }
   ```
   Do not auto-launch Outlook.

2. **Resolve the subject.** If the final subject does not already start with `[Nirvana] - `, prepend it.

3. **Resolve the body.**
   - Markdown file → read, convert to simple HTML (preserve headings, lists, tables, code blocks), wrap in `<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">…</body></html>`.
   - Inline markdown → same conversion.
   - Plain text → escape HTML entities, wrap paragraphs in `<p>`.
   - **Always append the Nirvana signature** as the final block, separated from the body by an `<hr>`. **Single source of truth: `<repo>\.copilot\skills\_shared\signature.md`** — use the helper:
     ```powershell
     . '<repo>\.copilot\skills\_shared\signature.ps1'
     $sig = Get-NirvanaSignature -NoSig:$noSig
     $html += $sig    # already includes the <hr>, the canonical wording, and the optional notice
     ```
     The helper returns the canonical line (`Sent on Nir's behalf by **Nir**vana — Nir's agent.`) plus an optional one-line notice loaded from `_shared/signature-notice.txt` (currently a heads-up about the May 18th show & tell). To change the notice in one place, edit that file.
     Append the signature exactly once — if the body already ends with this signature, don't duplicate.
     **Skip the signature if the user (or invoking skill) set `NOSIG`** (the helper handles this when you pass `-NoSig`).
   - **Always include a short, relevant joke or one-liner** in the body (saved Nir preference). Place it just before the `<hr>` signature, in its own `<p><em>…</em></p>`. **Consult `<repo>\.copilot\skills\_shared\joke-playbook.md`** for technique, anti-patterns, and worked examples. Keep it tasteful and on-topic — pull a concrete noun from the actual content; a missing joke beats a forced one. **Skip the joke if the user (or invoking skill) set `NOJOKE` / `NO JOKE` / `no-joke` / explicitly said "no joke".** Detect by scanning the request text, the subject, and the body for these tokens (case-insensitive).

4. **Preview-before-send**(mandatory when the body was auto-generated from a file OR longer than 20 lines OR has attachments). Show subject + first ~15 lines + attachment list, and wait for the user's explicit "send" / "yes". Skip the preview only if the user said "send now" / "don't preview" or provided the exact body inline.

5. **Send via Outlook COM:**
   ```powershell
   $ol   = New-Object -ComObject Outlook.Application
   $mail = $ol.CreateItem(0)            # 0 = olMailItem
   $mail.To       = ($To  -join '; ')
   if ($Cc)  { $mail.CC  = ($Cc  -join '; ') }
   if ($Bcc) { $mail.BCC = ($Bcc -join '; ') }
   $mail.Subject  = $Subject
   $mail.HTMLBody = $Html
   foreach ($path in $Attachments) {
       if (-not (Test-Path $path)) { throw "Attachment not found: $path" }
       if ((Get-Item $path).Length -gt 10MB) { throw "Attachment too large (>10 MB): $path" }
       [void]$mail.Attachments.Add($path)
   }
   $mail.Send()
   ```
   - Do **not** set `SentOnBehalfOfName` or `SendUsingAccount` unless the user explicitly asked to send from a different account.
   - After `$mail.Send()`, release COM refs:
     ```powershell
     [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
     [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
     ```

6. **Log.** Append one line to `<repo>\reports\email\YYYY-MM-DD.md`:
   ```
   - <HH:mm> to=<csv> cc=<csv> subject="<subject>" attachments=<N> status=sent  <optional:sourceFile>
   ```
   Create folder/file if missing.

7. **Report to user**, one line only:
   `Email sent to <N> recipient(s): "<subject>"  (via Outlook)`

## What NOT to do
- Do **not** attempt Microsoft Graph or SMTP fallbacks — Graph requires admin consent that the user doesn't have, SMTP is disabled by tenant policy. This skill is intentionally Outlook-COM-only.
- Do **not** auto-start Outlook if it isn't running — abort and tell the user.
- Do **not** send to any address the user didn't ask for — no silent CC, no "FYI" additions.
- Do **not** change the sending account (`SendUsingAccount`) unless the user explicitly requested it.
- Do **not** re-send on ambiguous failure — ask the user first.
- Do **not** attach files from outside the workspace (`c:\dev\agents\…`) without explicit confirmation, and refuse attachments over **10 MB**.
- Do **not** modify any ADO work items as part of this skill.
- Do **not** prompt the user for tenant IDs, credentials, or any auth config — this path needs none.

## Troubleshooting
- **COMException "The server is not available / RPC server is unavailable"** → Outlook was starting up or a modal dialog was open. Ask the user to make sure Outlook is fully loaded with no dialogs, then retry.
- **COMException 0x80080005** → PowerShell is elevated and Outlook is not. Relaunch the agent / terminal as a standard (non-admin) user. The elevation preflight should catch this before the COM call.
- **Mail sits in Outbox** → Outlook is in offline mode. Ask the user to toggle *Send/Receive → Work Offline* off.

