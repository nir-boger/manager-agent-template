# Nirvana email signature - canonical source

> Single source of truth. **Do not** hard-code signature HTML in skill SKILL.md files - reference this file (and the helper `signature.ps1`) instead.

## Canonical wording

| Variant | When to use | Text |
|---|---|---|
| `Default` | Most emails: `email-team`, `agent-todos`, ad-hoc Outlook COM sends, manual email composition. | `Sent on Nir's behalf by Nirvana - Nir's agent.` |
| `InboxAuto` | `inbox-watch` auto-replies (mandatory disclosure - the recipient must know an autoresponder spoke). | `Sent on Nir's behalf by Nirvana - Nir's agent. Nir is on the thread; reply directly if I got it wrong.` |
| `RunnerHeartbeat` | `_runner-email.ps1` heartbeats from scheduled tasks (DailySummary import, persona import, etc.) - low-signal, manager-internal. | `Automated heartbeat from Nirvana - Nir's agent. Source: <runner> on <YYYY-MM-DD HH:mm> IST.` |
| `WhatsAppGroupHe` | Plain-text Hebrew variant for **all** WhatsApp messages — every recipient, 1:1 or group, including Partner (saved Nir preference 2026-05-06; was originally Kusto-DM-Team-only, hence the legacy variant name). Rendered as the last line of the message body. Honors `NOSIG`. | `- נירוונה, הסוכן של ניר` |

Plain "Nir's agent" - never add team/role qualifiers (e.g. "his Your Team agent", "his ADO agent", "his personal agent"). The persona is Nirvana, the principal is Nir; nothing else belongs in the signature.

## Optional notice

Every signature can carry one extra short announcement (OOO heads-up, event invite, etc.). The notice is appended as a small italic line **below** the core signature.

- **Source file:** `<repo>\.copilot\skills\_shared\signature-notice.txt`
- **To change the notice:** edit that file. One-line body. `#`-prefixed lines are stripped (use them for header comments).
- **To disable the notice:** delete the body (leave only `#` comments, or empty file).
- **Inline HTML** (e.g. `<a href="...">link</a>`) is allowed. Use HTML entities for `&` (i.e. `&amp;`).
- **Per-skill suppression:** call `Get-NirvanaSignature -NoNotice` if a skill needs to skip the notice for that one email (rarely useful).

Current notice (as of file creation): a heads-up about the May 18th AI Agent show & tell meeting.

## How skills should use this

### From PowerShell (preferred)

```powershell
. '<repo>\.copilot\skills\_shared\signature.ps1'

# Default user-facing email:
$sig = Get-NirvanaSignature
$mail.HTMLBody = $bodyHtml + $(if ($noSig) { '' } else { $sig })

# Inbox auto-reply:
$sig = Get-NirvanaSignature -Variant InboxAuto

# Runner heartbeat:
$sig = Get-NirvanaSignature -Variant RunnerHeartbeat -RunnerName 'DailySummary import'

# Honor the NOSIG override:
$sig = Get-NirvanaSignature -NoSig    # returns ''
```

### From skills that don't run code (inline composition)

If you're composing an email by hand-pasting HTML, copy the canonical block below verbatim - then **also** check `signature-notice.txt` and append the notice paragraph if the body isn't whitespace-only.

```html
<hr><p style="color:#666;"><em>Sent on Nir's behalf by <strong>Nir</strong>vana &mdash; Nir's agent.</em></p>
```

Inbox-auto variant:

```html
<hr><p style="color:#666;"><em>Sent on Nir's behalf by <strong>Nir</strong>vana &mdash; Nir's agent. Nir is on the thread; reply directly if I got it wrong.</em></p>
```

Notice paragraph (when notice is non-empty):

```html
<p style="color:#666;font-size:90%;margin-top:4px;"><em>&#128226; <NOTICE-BODY></em></p>
```

## Hard rules

- Skills must not invent new signature text. Use this file or the helper.
- Skills must not echo the notice into prose elsewhere - it lives only in the signature footer.
- Teams posts (`post-to-teams`) are **exempt** - they remain unsigned and notice-free unless explicitly asked.
- `NOSIG` override on a request suppresses the entire signature (including notice).
- `NOJOKE` is unrelated to this file - it controls the joke, which is part of the body, not the signature.


