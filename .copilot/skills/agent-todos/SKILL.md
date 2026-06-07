---
name: "agent-todos"
description: "Process the Outlook task list named '🖥 Nirvana Agent' (match by emoji + 'Nirvana Agent' substring; the displayed name contains a stealth Unicode space). Each task's Title + Body is a free-form instruction Nir is delegating: send an email, reply to a thread, post to Teams, send a WhatsApp message, do research, ask a codebase question, or any multi-step combination. After acting, ALWAYS reply to Nir with a summary email and mark the task complete. Auto-polled every 5 min, 24/7 (all hours, all days) by the DM-NirvanaAgentTodos scheduled task; also triggerable via 'process my nirvana agent', 'run my nirvana agent todos', 'scan nirvana agent', 'nirvana agent todos', 'what's in my agent list'."
---

# Skill: agent-todos

## Purpose
This is Nir's **single inbox for delegating work to Nirvana**. He drops free-form instructions into the Outlook task list `🖥 Nirvana Agent`. For each open task, Nirvana:
1. Reads the **Title + Body** as the instruction.
2. Classifies the intent (`email` / `reply` / `teams-post` / `research` / `code-question` / `multi-step` / `unknown`) and dispatches.
3. Sends a **summary reply email** back to Nir at `you@example.com`.
4. Marks the task complete — **only on success**. On failure or ambiguity, leaves the task open and emails Nir what was tried and why it stopped.

Auto-polled every 5 min **24/7** (all hours, all days) by `DM-NirvanaAgentTodos` (runner: `<repo>\.copilot\skills\run-agent-todos.ps1`).

## Trigger phrases
- "process my nirvana agent" / "process my nirvana agent todos"
- "run my nirvana agent todos" / "run my agent list"
- "scan nirvana agent" / "scan my agent list"
- "what's in my agent list" / "anything in my agent list"
- "nirvana agent todos"
- Or pick up proactively when Nir mentions a task in that list.

## Inputs
None — the skill reads `🖥 Nirvana Agent` directly from Outlook.

## Hard prerequisite
Outlook desktop must be running. If not, abort the skill — do **not** auto-launch.

```powershell
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    throw 'Outlook is not running. Please start Outlook and retry.'
}
```

---

## Steps

### 1. Read the agent task list
Match by emoji + `Nirvana Agent` substring (the displayed name has a stealth zero-width / non-breaking space — never match by exact equality):

```powershell
$ol = New-Object -ComObject Outlook.Application
$ns = $ol.GetNamespace('MAPI')
$tasksRoot = $ns.DefaultStore.GetRootFolder().Folders.Item('Tasks')
$agentList = $tasksRoot.Folders | Where-Object { $_.Name -match 'Nirvana\s*Agent' } | Select-Object -First 1
if (-not $agentList) { throw "Couldn't find the '🖥 Nirvana Agent' task list under Tasks." }

$candidates = @()
foreach ($t in $agentList.Items) {
    if ($t.Complete) { continue }
    $candidates += [pscustomobject]@{
        EntryID  = $t.EntryID
        Subject  = $t.Subject
        Body     = $t.Body
        Created  = $t.CreationTime
        Modified = $t.LastModificationTime
    }
}
```

If `$candidates` is empty, exit cleanly (no summary email, no completion message).

### 2. Settle period
Skip any task whose `CreationTime` is within the last **60 seconds** — Nir may still be typing. **Do NOT key off `LastModificationTime`**: tasks created on phone / Microsoft To Do sync via Exchange ActiveSync, and every incremental sync bumps `LastModificationTime` even when nothing was edited. Using mod-time would starve mobile-created tasks (we hit this in production: a phone-created TODO sat for ~32 min before the sync went idle long enough to clear the window). `CreationTime` is set once and never moves.

### 3. Classify each candidate
Combine Title + Body, lowercase for matching, but **preserve the original casing** when extracting recipients/topics/quoted strings.

Classification (first match wins; check in this order):

| Intent | Detection signals (any in Title or Body) |
|---|---|
| **`reply`** *(special-case of email)* | `reply`, `reply all`, `reply-all`, `reply to all`, or a quoted subject starting with `Re:` |
| **`email`** | Title starts with `Send Email`, `Email`, `Mail`, `Write to`, `Draft email`; or body says `send an email` / `email <name>` |
| **`teams-post`** | Title starts with `Post to Teams`, `Teams:`, `Channel:`, `Tell the team on Teams`; or body says `post to teams` / `post to the channel` |
| **`whatsapp`** | Title or body uses an **imperative WhatsApp send** form with a recipient: `send whatsapp to <name>`, `whatsapp <name> saying <text>`, `tell <name> on whatsapp`, `msg <name> on whatsapp`; or `use the whatsapp skill` directive. **Casual mention** of the word "whatsapp" (e.g. *"follow up on the whatsapp thread later"*) does **not** match — the verb must be imperative AND a recipient must be named. |
| **`research`** | Title starts with `Research`, `Find`, `Look up`, `Investigate`, `Compare`, `Summarize`; or body says `do some research` / `find out` / `look into` / `summarize` |
| **`code-question`** | Body or title says `use the codebase skill`, `in the codebase`, `where does ... live`, `review PR`, or a clear codebase Q (route to `codebase`) |
| **`multi-step`** | Two or more of the above are clearly present (e.g. "research X **then** email the team") |
| **`unknown`** | None of the above match confidently |

**Skill-name overrides classification.** If the body says `use the <skill> skill`, that skill is part of the plan regardless of heuristics. See §"Skill composition" below.

### 4. Parse directives from Title + Body (CRITICAL — do not skip)
Scan the full Title and Body (case-insensitive) for these directives. They override defaults. If a directive is recognized, log it; do **not** echo it into the outgoing email body.

| Directive (any of these tokens) | Effect |
|---|---|
| `reply all`, `reply-all`, `reply to all`, or just `reply` (default = Reply All per Nirvana convention) | **Reply mode** — find the existing thread; use `MailItem.ReplyAll()` (or `Reply()` if user explicitly said "reply only" / "reply just to sender"). See §"Reply-mode thread search". |
| `cc the team`, `keep my team informed`, `keep the team in the loop`, `cc team` | Add `team@example.com` to CC. |
| `cc <name/email>` | Add that person to CC (resolve via persona / GAL). |
| `bcc <name/email>` | Add to BCC. |
| `NOJOKE`, `NO JOKE`, `no-joke` | Omit the joke (signature stays). |
| `NOSIG` | Omit the signature too. |
| `draft only`, `do not send`, `preview only` | Compose, save to Drafts (`$mail.Save()`), do **not** call `Send()`. Show preview. |
| `PREVIEW` | Always preview before sending, even for routine TODOs. |
| `use <skill-name>` (e.g. `use your codebase skill`, `use codebase`, `via team-personas`) | **Skill composition** — read `.copilot/skills/<skill>/SKILL.md` and run that skill first; integrate its output into the email/post/summary. |
| `add to my personal todo`, `add a personal todo`, `PT add`, `add to my todo list` | **Personal-todos route** — read `.copilot/skills/personal-todos/SKILL.md` and run **Add item** mode on the body. Parse title / category / priority / due / notes, then **invoke the helper** `python .copilot/skills/personal-todos/add-item.py --todos-file reports/personal-todos/todos.md --title "<title>" [--category work\|personal] [--priority H\|M\|L] [--due <natural>] [--notes "<…>"]`. Never hand-roll Markdown — the helper is the single source of truth for ID assignment and field shape. Capture stdout (`PT-NNN\t…\t…`), then mark the agent task complete with a one-line summary email. |
| `PT accept N[,N,...]` (e.g. `PT accept 1,3,5`) | **Suggest-accept route** — read `.copilot/skills/personal-todos/state/last-suggest.json`, materialize the numbered candidates into real `PT-NNN` rows under `## Open` in `reports/personal-todos/todos.md`, summarize which were added. |
| Explicit subject hint in quotes (e.g. `"Re: [PUBLIC] Sev 3: ID 768835342: …"`) | Use that as the **thread search query** in §"Reply-mode thread search". |
| ICM ID like `ID 768835342` or `ICM 12345` | Use as the thread search query. |

### 5. Dispatch
Execute each item independently. **One item's failure must not abort the others** — capture the exception, log it, leave that item incomplete, and continue.

#### 5a. `email` / `reply`
**Subject grammar for new emails** (be permissive):
```
Send Email to <recipient> about <topic>
Send Email to <recipient> [: |- ] <topic>
Send Email to <recipient>            (no topic — use Body for context)
```
Topic = text after `about` / `:` / `-`. If absent, use the Body as topic seed. If both are absent, skip and report.

For new emails:
1. Resolve the recipient (§"Recipient resolution").
2. Resolve any `cc` / `bcc` directives the same way.
3. If a `use <skill>` directive is present, run that skill first (§"Skill composition") and integrate its output.
4. Draft the body in Nirvana voice (§"Draft the email").
5. Send (§"Send mechanics — new email").

For replies:
1. Build a thread search query and locate the original message (§"Reply-mode thread search").
2. If 0 matches → STOP for that item; do **not** silently fall back to a fresh email.
3. Compose new content (§"Draft the email" — but no salutation if it's already in the quoted history).
4. Send via `MailItem.ReplyAll()` / `Reply()` (§"Send mechanics — reply").

##### 5a.1 Outbound content sanity check — **compose, don't paste** (mandatory)

The outbound email body must be a **fresh compose written *as Nir* to the named recipients** — never a paste of a prior internal Nirvana → Nir analysis. If the TODO chain is `(1) email me the analysis → (2) now send that to <person>`, treat step 2 as a re-compose, not a forward of step 1.

Before calling `Send()`/`ReplyAll()`/`Reply()` on any outbound email, scan the assembled HTML body and **reject the send (back to compose) if any of these appear**:

- Section headers that are meta-framing for Nir, including but not limited to: `Status:`, `What I did`, `What <name> Got Right`, `Suggested Response`, `Suggested Reply`, `Suggested Followup`, `Output / artifacts`, `Analysis Results`, `Most Critical Finding`, `Important Gaps`, `Findings`, `Notes / open questions`. These belong **only** in the §6 internal summary email to Nir.
- Local file paths: any `C:\`, `D:\`, `\\?\`, `~/`, `$env:TEMP`, `$env:LOCALAPPDATA`, or `%TEMP%` substring. Internal artifact paths never go outbound.
- Internal Nirvana scaffolding: literal strings `[Nirvana]`, `[Nirvana] - Done`, `[Nirvana] - Needs your input`, ``$mail.``, ``$sig``, ``Get-NirvanaSignature``, ``EntryID``.
- Third-person commentary *about* a recipient who is in the To/CC line (e.g., a "What X Got Right / Wrong" block addressed to X).
- **Duplicate signature blocks** — search for two occurrences of the signature opening (`Sent on Nir's behalf by Nirvana` or `— Nirvana` on its own line in non-PR-comment contexts). If found, strip the second.

If the body fails this check, **do not auto-strip and send** — back out to compose, rewrite from scratch in Nir's voice as if writing the email cold, and re-validate.

##### 5a.2 Wide-distribution / automation-list sanity check (mandatory)

Before `Send()`, inspect the resolved To + CC. If **any** address matches a DL / automation pattern, **stop and email Nir a `Needs your input` summary** with the proposed body and the offending recipient(s) — do **not** auto-send.

DL / automation patterns to trip on:

- Explicit DLs: `escalation-dl@`, `team@` (unless Nir said `cc the team` / `cc team`), `Kusto ICM Escalation`, `Your Team`, any address whose display name contains `Escalation`, `On-Call`, `Distribution List`, `(DL)`, `Team` (with no first-name), `All Hands`.
- Automation accounts: `gauto*@`, `*ServiceAccount*@`, `Incident Automation*`, `noreply@`, `donotreply@`, `sas-mail@`, any address with display name containing `Service Account` or `Automation`.
- ICM/incident threads: subject contains `[ErrorsDetectionAutomation]`, `[ICM]`, `Sev 1`, `Sev 2`, `Sev 3`, `Sev 4`, or `Incident `; or original sender domain is `noreply.icm.*`.

Carve-out: if the TODO body explicitly names the DL — e.g. `reply all and keep escalation-dl` or `cc team` — pass the check.

For ICM/incident-thread outbounds that pass the gate, **also drop the optional signature notice** (`Get-NirvanaSignature -NoNotice`) — the show & tell / weekly-announcement notice is appropriate for team and 1:1 mail but jarring on an active incident thread.

#### 5b. `teams-post`
1. Build the message body from the task body (markdown OK; convert to the HTML fragment style described in `post-to-teams/SKILL.md` step 2).
2. Subject: `NirvanaTeams <one-line summary of the task>`. **No brackets** around `NirvanaTeams`.
3. Send via Outlook COM exactly as in `post-to-teams/SKILL.md` step 5.
4. Skip the preview prompt — this skill is dispatch-mode. Exception: preview if the directive `PREVIEW` is set on the task.
5. Log to `<repo>\reports\teams\YYYY-MM-DD.md` per that skill.

#### 5c. `whatsapp`
1. **Resolve the recipient** from the task body — contact name or group name. Verify it's on the WhatsApp allowlist (`.copilot/skills/whatsapp/allowlist.txt`, case-insensitive match against the entry, ignoring the `[group]` prefix). If the chat is not on the allowlist, **skip with `Needs your input`** in the summary email — do **not** auto-add to the allowlist.
2. **Compose the message body in Hebrew** per the per-recipient voice rules in `whatsapp/SKILL.md` §"Per-recipient style". Apply group canon where relevant (Your Team wine/Reformer/lunch in-jokes; maternity-group restraint; **load `spouse-or-partner-template/SKILL.md` if it's Partner** — that's her single-source-of-truth). For replies, run `read` first via `whatsapp.ps1 read --chat "<name>" --limit 30` to match the thread tone.
3. **Auto-send (no preview, no confirmation prompt).** This is the carve-out from the WhatsApp skill's normal preview-first rule — see `whatsapp/SKILL.md` §"Invocation modes":
   ```powershell
   & '<repo>\.copilot\skills\whatsapp\whatsapp.ps1' send --chat "<name>" --message "<hebrew body>" --confirm SEND
   ```
   Do **not** call `Send-WhatsAppPreviewEmail`. The TODO is Nir's authored intent; the summary email back to Nir is the audit trail.
4. **Honor `PREVIEW` / `draft only` directive overrides.** If the TODO body contains either token (case-insensitive), drop the `--confirm SEND` flag and route through `Send-WhatsAppPreviewEmail` instead — wait for Nir's `send` reply before firing.
5. The Node runner fails closed on send-verification timeout (`#main div.message-out` bubble must appear within ~20s). Capture its exit code; on failure surface as `Failed ❌` in the summary email status, with the runner's stderr in the artifacts block — do **not** retry automatically.
6. The WhatsApp skill itself logs to `reports/whatsapp/YYYY-MM-DD.md` (with `via=agent-todos`); this skill **also** logs to `reports/agent-todos/YYYY-MM-DD.md` per §8 with `intent=whatsapp`.

#### 5d. `research`
1. Use **`web_search`** for current/external topics. Use **`codebase`** for internal-codebase questions. Use both if the task spans both (e.g. "compare our X impl to upstream").
2. Capture: a 5–15 line answer in markdown, citations/links, doc paths.
3. The result becomes the **body of the summary email** (no separate outgoing email — the summary email IS the deliverable for research tasks).

#### 5e. `code-question`
Run `codebase` per its SKILL.md. Capture the answer + cited file paths + any commands quoted verbatim. Treat output the same as `research`: it lands in the summary email body.

#### 5f. `multi-step`
Execute steps in the order they appear in the task body. Pass artifacts forward:
- `research` / `code-question` → produces facts/links, which can be embedded into a subsequent `email` or `teams-post`.
- If any step fails, **stop the chain**, leave the task incomplete, and email Nir the partial results + which step failed.

#### 5g. `unknown`
Do **not** guess. Skip dispatch. The summary email becomes a "needs your input" note.

### 6. Compose the summary reply email (always sent — even on failure)
Recipient: **`you@example.com`** (To). No CC/BCC unless the task body explicitly says so.

Subject:
- Success → `[Nirvana] - Done: <task title>`
- Skipped / partial / failed → `[Nirvana] - Needs your input: <task title>`

Body (HTML; signature + joke per Nirvana voice rules — honor `NOJOKE` / `NOSIG` directives; honor per-recipient `## Voice rules` from `team-personas/people/<alias>.md` when the recipient has a persona file):

```
<p><b>Task:</b> <task title></p>
<p><b>Status:</b> <Sent ✅ | Posted ✅ | Researched ✅ | Skipped ⚠️ | Failed ❌></p>
<p><b>What I did:</b></p>
<ul>
  <li>...one bullet per concrete action (skill invoked, recipient, subject, link, file path)...</li>
</ul>
<p><b>Output / artifacts:</b></p>
<blockquote>... research summary, draft preview, link to Teams post, etc. ...</blockquote>
<p><b>Notes / open questions:</b> <only if applicable></p>
```

For `research` and `code-question` items where the deliverable IS the answer, the `<blockquote>` contains the full answer (with citations). For `email` / `teams-post` items, it contains an excerpt (first ~10 lines of the body) plus a link or message-ID reference if available.

```powershell
$mail = $ol.CreateItem(0)
$mail.To = 'you@example.com'
$mail.Subject = $summarySubject
. '<repo>\.copilot\skills\_shared\signature.ps1'
$sig = Get-NirvanaSignature -NoSig:$noSig
$mail.HTMLBody = $bodyHtml + $sig
$mail.Send()
```

The summary email is **always sent** — it's the audit trail. Even on `unknown` / failure, Nir gets an email explaining what stopped me.

### 7. Mark the task complete (success only)
```powershell
if ($itemSucceeded) {
    $task = $ns.GetItemFromID($entryId)
    $task.MarkComplete()
    $task.Save()
}
```

If status is `Skipped` / `Failed` / `Partial`, **do not** mark complete. Leave it for Nir to triage.

### 8. Append to the daily log
`<repo>\reports\agent-todos\YYYY-MM-DD.md`, one line per item:
```
- <HH:mm> entry=<EntryID-prefix> intent=<email|reply|teams-post|research|code-question|multi-step|unknown> status=<sent|posted|researched|skipped|failed> title="<task title>"  notes=<short>
```
Create folder/file if missing.

### 9. Report back to Nir in chat (only when invoked interactively)
Markdown table at the end:

| Task | Intent | Status | Output | Marked complete |
|---|---|---|---|---|
| Send Email to the team about Connect | email | Sent ✅ | `[Nirvana] - Microsoft Connect` to team | Yes |
| Research X vs Y for Q3 plan | research | Researched ✅ | summary in reply email | Yes |
| Post to Teams: lunch & learn Friday | teams-post | Posted ✅ | NirvanaTeams subject ... | Yes |
| (vague body — couldn't classify) | unknown | Skipped ⚠️ | reply email asks for clarification | No |

If anything was skipped/failed, call it out at the bottom and ask Nir how to proceed. **Suppress the chat report when running under the auto-poll scheduled task** — the summary emails are the audit trail there.

---

## Email mechanics (used by §5a — kept inline for self-containment)

### Recipient resolution (in this order)
1. **Persona store first** — check `.copilot/skills/team-personas/people/*.md` for a matching first-name / alias. If found, use the email from the persona header.
2. **Hard-coded shortcuts:**
   | Phrase | Address |
   |---|---|
   | `team`, `the team`, `team` | `team@example.com` |
   | `myself`, `me`, `nir`, `Your Name` | `you@example.com` |
3. **Outlook GAL** — `$r = $ns.CreateRecipient($name); $r.Resolve()`. If it resolves uniquely, use it.
4. **`m365_search_people`** — last resort.
5. If 0 results or ambiguous, STOP for that item — do **not** guess.

### Skill composition (when body says "use <skill>")
1. Read `.copilot/skills/<skill>/SKILL.md` to understand its modes.
2. For `codebase` "find docs" requests: run its **Find-docs sub-mode** with the topic from the TODO. Capture the matched file path + the exact command/snippet.
3. Quote the resulting command **verbatim** in the email (don't paraphrase commands — they're executed by humans).
4. Cite the doc file path in a small footer (e.g. *"Ref: Doc/InternalKusto/.../deadletterqueue-commands.md"*) so the recipient can verify.
5. If the named skill **isn't found** under `.copilot/skills/`, STOP — report back; don't fake it.

### Reply-mode thread search
1. **Build a search query** from these signals (best-first):
   - Quoted subject from the TODO body.
   - ICM/ID number.
   - `<recipient name>` + topic keywords.
2. **Search Inbox first, then Sent Items**, last 30 days:
   ```powershell
   $inbox = $ns.GetDefaultFolder(6)   # olFolderInbox
   $sent  = $ns.GetDefaultFolder(5)   # olFolderSentMail
   $cutoff = (Get-Date).AddDays(-30)
   $hits = @()
   foreach ($folder in @($inbox, $sent)) {
       foreach ($item in $folder.Items) {
           if ($item.Class -ne 43) { continue }   # 43 = olMail
           if ($item.ReceivedTime -lt $cutoff -and $item.SentOn -lt $cutoff) { continue }
           if ($item.Subject -match [regex]::Escape($query) -or $item.Body -match [regex]::Escape($query)) {
               $hits += $item
           }
       }
   }
   $thread = $hits | Sort-Object -Property ReceivedTime -Descending | Select-Object -First 1
   ```
3. **If multiple matches**, pick the **newest message in the matching thread** (by `ConversationID` if available, else newest by `ReceivedTime`).
4. **If 0 matches**, **STOP** — do **not** silently fall back to a fresh email. Report: *"Couldn't find the thread to reply to (searched: \<query>). Want me to send a new email instead, or is the thread older than 30 days?"*

### Draft the email — Nirvana voice
Per `<repo>\AGENTS.md`:
- Concise. No preamble.
- Sign off `— Nirvana` (omit if `NOSIG`).
- **Joke**: include a short relevant one-liner before the signature. Skip if `NOJOKE` directive is set or if Nir globally said "no joke".
- For the team alias, "Hi team,". For individuals, "Hi <FirstName>,". For self, no salutation.
- For replies: skip the salutation if it's already in the quoted history; lead with the substantive content.

Filler is OK for high-level topics; never fabricate technical specifics (cluster names, SHAs, ICM IDs, command parameters). When unsure, use a placeholder (e.g. `INGEST-XXXX`) and call it out.

### Send mechanics — new email
- For `team@example.com` (To) → invoke the `email-team` skill (it has team-specific conventions).
- Other recipients → direct Outlook COM as **HTML**:
  ```powershell
  $mail = $ol.CreateItem(0)
  $mail.To = $address
  if ($cc)  { $mail.CC  = $cc }
  if ($bcc) { $mail.BCC = $bcc }
  $mail.Subject = if ($subject -like '[Nirvana]*') { $subject } else { "[Nirvana] - $subject" }
  . '<repo>\.copilot\skills\_shared\signature.ps1'
  $sig = Get-NirvanaSignature -NoSig:$noSig
  $mail.HTMLBody = $bodyHtml + $sig
  $mail.Send()
  ```

### Send mechanics — reply
```powershell
$reply = $thread.ReplyAll()    # or $thread.Reply() if 'reply only' was set
# subject is auto-prefixed with "Re:" by Outlook — do NOT add [Nirvana] - on replies
if ($extraCc) { $reply.CC = ($reply.CC + '; ' + $extraCc).Trim('; ') }
$reply.HTMLBody = $newBodyHtml + $reply.HTMLBody   # preserve quoted history
$reply.Send()
```
- **Do NOT prepend `[Nirvana] - ` on replies** — it breaks the `Re:` chain.
- **Preserve the quoted history** (`$reply.HTMLBody` already contains it; prepend your new content).

### Send mechanics — meeting invite (AppointmentItem)
**Every Nirvana-sent meeting invite MUST include a Teams join link** (saved Nir preference, 2026-05-05). No exceptions for internal-only / 1:1 / quick-sync invites — always Teams. Applies to invites created by **any** Nirvana skill, not just this one.

```powershell
$appt = $ol.CreateItem(1)        # olAppointmentItem
$appt.MeetingStatus = 1          # olMeeting
$appt.Subject = $subject
$appt.Start = $startLocal
$appt.Duration = $minutes
$appt.Body = $bodyText            # set BEFORE the helper - the add-in preserves it and appends Teams boilerplate
# Do NOT set Location -- the Teams add-in sets it to "Microsoft Teams Meeting"
$null = $appt.Recipients.Add($attendeeSmtp); $appt.Recipients.ResolveAll()

# --- Attach Teams link (mandatory) ---
# AppointmentItem.OnlineMeetingProvider / IsOnlineMeeting / ConferenceLink
# are read-only via COM (Outlook 16.x), and the Outlook profile toggle
# `AddOnlineMeetingForAllMeetings` does NOT attach a Teams link for
# COM-created invites (proven empirically 2026-05-05, even after restart).
#
# Working recipe: $appt.GetInspector.Display($false) wakes up the
# `TeamsAddin.FastConnect` COM add-in, which provisions a real Teams
# meeting and APPENDS the Microsoft Teams boilerplate (joinUrl + meeting
# ID + passcode) to the existing Body. Your intro/joke/signature stay
# at the top untouched. The structured properties remain at default
# (False / 5 / "") -- detection MUST scan Body for the URL pattern.
# Verified 2026-05-05 by real send to Zvi Schneider.
. '<repo>\.copilot\skills\_shared\teams-meeting.ps1'
$ok = Add-TeamsLinkToAppointment -Appointment $appt -TimeoutSeconds 30
if (-not $ok) {
    # Teams add-in didn't inject the URL within the timeout. Fail closed --
    # do NOT send a Teams-less invite. Surface to the summary email.
    try { $appt.Close(1) } catch {}   # discard the half-baked draft
    throw "Teams add-in did not attach a join link within 30s. Skipping invite."
}

# Body now contains: <your text> + <separator + Microsoft Teams meeting
# block>. Do NOT rewrite it -- doing so will duplicate your intro.
$appt.Send()
```

- **Fail closed** if `Add-TeamsLinkToAppointment` returns `$false` — better to skip the invite and surface a `Needs your input` summary than send a Teams-less invite.
- **Do NOT** try to set `OnlineMeetingProvider` / `IsOnlineMeeting` / `ConferenceLink` directly on the AppointmentItem — they are read-only on Outlook 16.x COM (verified 2026-05-05, build 16.0.0.19929). They will remain at default values (`False / 5 / ""`) even when the Teams URL is present in Body.
- **Do NOT** paste a manually-fabricated Teams URL into the body — the join link must be a real Graph-provisioned meeting (only the `Display`-driven add-in path or Graph API gets you a real URL).
- **Do NOT rewrite `$appt.Body` after the helper returns.** The Teams add-in appends its boilerplate to whatever Body you set BEFORE calling the helper; rewriting will duplicate your intro/joke/signature in the sent invite. Set the body once, before the helper.
- **Do NOT pre-set `Location`** — the Teams add-in sets it to "Microsoft Teams Meeting". A pre-set Location will be overwritten.
- **Graph API fallback** (when running headless without Outlook) is the only correct alternative — POST `/me/onlineMeetings` then create the event with `joinUrl` set. Not implemented in this repo yet; if you need it, ask Nir before adding the dependency.

---

## Failure handling (summary)
- **Outlook not running** → abort the whole skill (don't auto-launch).
- **List not found** → throw the clear error from §1.
- **Per-item failure** → catch, log, leave task open, email summary with `Needs your input`, continue with other items.
- **Sub-skill not found** (e.g. body references `use the foo skill` and `.copilot/skills/foo/` doesn't exist) → skip that item with a clear note in the summary email.
- **Recipient resolution ambiguous** (multiple GAL hits, persona missing) → skip; do not guess.
- **Reply thread not found** → skip; do **not** silently fall back to a fresh email.
- **Research returns no usable answer** → still send a summary email saying so; leave task open if Nir would benefit from rephrasing.

## Auto-send vs. preview
**Auto-send always — for emails, replies, Teams posts, and WhatsApp messages.** Preview only when the TODO body explicitly includes `PREVIEW` or `draft only`. Nothing else triggers a preview. The summary-back-to-Nir email is always auto-sent.

**WhatsApp-specific note:** the WhatsApp skill's default behavior (`whatsapp/SKILL.md` §"Hard safety rails" #2) is preview-first with a `send` confirmation cycle. That preview-first behavior is **only** for *manual* CLI invocation ("send whatsapp to X" typed by Nir this turn). When invocation comes from this skill (the todos pipeline), the WhatsApp skill auto-sends — no preview email, no confirmation. See `whatsapp/SKILL.md` §"Invocation modes" for the full table.

## Edge cases
- **Hebrew names / Hebrew topics**: support both. Subject prefix `[Nirvana] -` stays English.
- **Item Body contains a draft**: prefer the user's draft text and just style-polish + sign off.
- **Item subject is exactly "Send Email" with no recipient**: skip; mark as `Needs your input`.

## What NOT to do
- Do **not** read or process items from any list other than `🖥 Nirvana Agent`. The old `📌 This Week` flow is retired.
- Do **not** delete tasks — only `MarkComplete`.
- Do **not** mark complete on failure / skip / partial.
- Do **not** auto-launch Outlook.
- Do **not** silently fall back to a fresh email when reply mode is requested but the thread can't be found.
- Do **not** fabricate technical specifics (cluster names, ICM IDs, SHAs, command parameters). Use placeholders and call them out.
- Do **not** treat skill references as flavor text. "Use the <skill>" is a directive — load and run it.
- Do **not** abort the whole batch if one item fails — isolate failures.
- Do **not** prepend `[Nirvana] - ` to reply subjects — Outlook's `Re:` chain handles threading.
- Do **not** include the task Body verbatim in outgoing email if it contains private notes — use it as context only.
- Do **not** BCC anyone, and do **not** add CCs unless the task explicitly says so.


