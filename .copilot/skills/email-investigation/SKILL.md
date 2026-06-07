# Skill: email-investigation

## Purpose
Send an **investigation-style** email — the dark-hero / stat-grid / data-table / numbered-recommendations layout Nir liked from the `KvcIngestMonitorJob INGEST-KUTRIDENTHOSTER1EUS` post-mortem. Use whenever the message is the writeup of an incident, RCA, deep-dive, code-path autopsy, perf investigation, or any "I dug into X, here's what I found" content.

This skill is a **content / style wrapper** — it builds the HTML and then hands off to the same Outlook COM send path documented in `email-team`. It does not introduce a new send mechanism.

## When to use
Trigger phrases (case-insensitive, partial match OK):

- "send investigation email", "email this investigation", "investigation-style email"
- "send analysis with the fancy UI", "send the analysis with the styled UI", "use the investigation style"
- "send the investigation we just discussed", "email me this investigation"
- "RCA email", "post-mortem email"

If the user just says "email this", **don't** auto-pick investigation style — use plain `email-team`. Investigation style is opt-in.

## Fixed context
- Default recipient: **Nir only** (`someone@example.com`) — investigations are usually for Nir to review before he forwards. If the user explicitly names a wider audience (`team`, a person), honor it.
- Renderer (single source of truth): `<repo>\.copilot\skills\_shared\investigation-email.ps1`
- Send mechanism: identical to `email-team` (Outlook COM, same preflight rules).
- Log folder: `<repo>\reports\email\` (same as `email-team`).
- Subject prefix: **always prepend `[Nirvana] Investigation: `** unless it already starts with that (or with `[Nirvana] `).

## Hard prerequisite
Same as `email-team`: Outlook desktop must be running and PowerShell must be **non-elevated**. Run the elevation preflight from `email-team` before doing anything else.

## The spec shape
The renderer takes a single hashtable `$spec`. Compose it from the conversation content — every field except `Title` is optional, but a good investigation usually carries all of them.

```powershell
$spec = @{
    Title    = '<short headline, no [Nirvana] prefix>'       # required
    Eyebrow  = 'Investigation'                                # optional override (e.g. 'Post-mortem', 'Deep Dive')
    Subtitle = '<1-2 sentence HTML lede>'                     # optional, HTML allowed
    Chips    = @(                                             # optional, 2-5 chips, dark-hero palette
        @{ Label = '2026-04-20 06:11 UTC'; Tone = 'neutral' }
        @{ Label = '2 BAD NODES';          Tone = 'bad'     }
        @{ Label = '55 HEALTHY';           Tone = 'good'    }
    )
    Tldr     = '<one-paragraph HTML, no leading "TL;DR" — renderer adds the eyebrow>'
    Stats    = @(                                             # optional, 1-4 cards (4 is the sweet spot)
        @{ Label = 'Broken nodes';        Value = '2';     Sublabel = 'D & K';            Tone = 'bad'  }
        @{ Label = 'Failed RPCs (30 min)'; Value = '3,055'; Sublabel = '100% failure';     Tone = 'bad'  }
        @{ Label = 'Healthy peers';        Value = '55';    Sublabel = '~50k successes';   Tone = 'good' }
        @{ Label = 'Bad-traffic share';    Value = '~3.5%'; Sublabel = 'probe + customer'; Tone = 'warn' }
    )
    Sections = @(                                             # narrative cards, ordered
        @{
            Title        = 'What the data shows'
            SubtitleHtml = 'Side-by-side outbound gRPC, 30 min window.'
            BodyHtml     = '<table>...the data table...</table>'
            Callout      = @{ Tone = 'accent'; Html = '<strong>Punchline sentence.</strong>' }   # optional
        }
        @{
            Title    = "Why self-heal can't escape"
            BodyHtml = '<ol><li>...</li></ol>'
            Callout  = @{ Tone = 'warn'; Html = '...' }
        }
    )
    Recommendations = @(                                      # numbered cards with priority chips
        @{ Priority = 'P0 - Today';      Tone = 'bad';    Title = '...'; BodyHtml = '...' }
        @{ Priority = 'P1 - This week';  Tone = 'warn';   Title = '...'; BodyHtml = '...' }
        @{ Priority = 'PBI';             Tone = 'accent'; Title = '...'; BodyHtml = '...' }
        @{ Priority = 'Optional';        Tone = 'muted';  Title = '...'; BodyHtml = '...' }
    )
    Joke = 'One specific, on-topic one-liner. Skip if NOJOKE.'
}
```

### Tone values
`neutral` | `good` | `bad` | `warn` | `accent` | `muted`

These map to color pairs inside the renderer. Use:
- `bad` for failure counts, broken nodes, downtime
- `good` for successes, healthy peers, recovery
- `warn` for partial outages, in-rotation-but-broken metrics
- `accent` for neutral highlights / "noteworthy" items
- `muted` for cosmetic/optional rows
- `neutral` for facts without a value judgement (timestamps, IDs)

## Steps

1. **Preflight** (copy from `email-team` SKILL.md):
   ```powershell
   if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
       throw 'Outlook is not running. Please start Outlook and retry.'
   }
   $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
   if ($isElevated) { throw 'Session is elevated; relaunch non-elevated and retry.' }
   ```

2. **Compose the `$spec` hashtable** from the conversation. Required:
   - `Title` — pull the headline from what you already wrote in chat.
   - Either `Tldr` OR `Sections` (at minimum one of them). Empty investigations get rejected by the renderer.

3. **Render the HTML:**
   ```powershell
   . '<repo>\.copilot\skills\_shared\investigation-email.ps1'
   $body = Build-InvestigationEmailHtml -Spec $spec
   ```

4. **Append the signature** via the shared helper:
   ```powershell
   . '<repo>\.copilot\skills\_shared\signature.ps1'
   $body += Get-NirvanaSignature
   ```
   Honor `NOSIG` / `NOJOKE` exactly like `email-team` (pass `-NoSig` switch when needed; drop the `Joke` field from the spec when needed).

5. **Resolve subject.** If the user gave one, use it; otherwise derive from `Title`. Then prepend `[Nirvana] Investigation: ` (only if it doesn't already start with `[Nirvana] `).

6. **Preview-before-send** is *mandatory* for this skill — investigations are dense and easy to get wrong. Show: final subject, first ~15 lines of the rendered HTML body stripped of tags, and the chip+stat values. Wait for explicit "send".

   Optional escape: if the user said "send now, no preview" / "skip preview", proceed.

7. **Send via Outlook COM** (same code as `email-team` step 5).

8. **Log** one line to `<repo>\reports\email\YYYY-MM-DD.md`:
   ```
   - <HH:mm> to=<csv> cc=<csv> subject="<subject>" attachments=0 status=sent  skill=email-investigation
   ```

9. **Report to user** one line:
   `Investigation email sent to <N> recipient(s): "<subject>"  (via Outlook)`

## Worked example (the one Nir liked)

```powershell
. '<repo>\.copilot\skills\_shared\investigation-email.ps1'
. '<repo>\.copilot\skills\_shared\signature.ps1'

$dataTable = @'
<table cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:13px;">
  <thead><tr style="background:#faf9fd;">
    <th align="left" style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#57606a;text-transform:uppercase;font-size:11px;letter-spacing:0.5px;">Source machine</th>
    <th align="left" style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#57606a;text-transform:uppercase;font-size:11px;letter-spacing:0.5px;">10.3.0.35:23108 (FabricManager)</th>
    <th align="left" style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#57606a;text-transform:uppercase;font-size:11px;letter-spacing:0.5px;">10.3.0.62:23222 (DmAdmin)</th>
  </tr></thead>
  <tbody>
    <tr style="background:#fef0ee;"><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:700;">KSDATAMAN00000D</td><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:600;">1,413 &middot; 0 succeed</td><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:600;">3 &middot; 0 succeed</td></tr>
    <tr style="background:#fef0ee;"><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:700;">KSDATAMAN00000K</td><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:600;">1,636 &middot; 0 succeed</td><td style="padding:10px 12px;border-bottom:1px solid #e2e1ec;color:#b42318;font-weight:600;">3 &middot; 0 succeed</td></tr>
    <tr style="background:#e7f6ee;"><td style="padding:10px 12px;color:#0f7a3c;font-weight:700;">Every other node (55)</td><td style="padding:10px 12px;color:#0f7a3c;font-weight:600;">800-1,200 each &middot; 100% succeed</td><td style="padding:10px 12px;color:#0f7a3c;font-weight:600;">100% succeed</td></tr>
  </tbody>
</table>
'@

$spec = @{
    Title    = 'KvcIngestMonitorJob FAIL on INGEST-KUTRIDENTHOSTER1EUS'
    Eyebrow  = 'Incident Analysis'
    Subtitle = 'Two gateway nodes (<strong>KSDATAMAN00000D</strong> &amp; <strong>KSDATAMAN00000K</strong>) are partitioned from FabricManager + DmAdmin primaries. The other 55 nodes route fine.'
    Chips    = @(
        @{ Label = '2026-04-20 06:11 UTC'; Tone = 'neutral' }
        @{ Label = 'CID 240a18ff&hellip;'; Tone = 'neutral' }
        @{ Label = '2 BAD NODES';          Tone = 'bad'     }
        @{ Label = '55 HEALTHY';           Tone = 'good'    }
    )
    Tldr  = 'It is <strong>not</strong> a gRPC self-heal bug. It is a <strong>node-pair network partition</strong> that no application-level self-heal can recover from, because nothing tells the gateway node to step <em>out</em> of the load balancer.'
    Stats = @(
        @{ Label = 'Broken nodes';        Value = '2';     Sublabel = 'D & K';            Tone = 'bad'  }
        @{ Label = 'Failed RPCs (30 min)'; Value = '3,055'; Sublabel = '100% failure';     Tone = 'bad'  }
        @{ Label = 'Healthy peers';        Value = '55';    Sublabel = '~50k successes';   Tone = 'good' }
        @{ Label = 'Bad-traffic share';    Value = '~3.5%'; Sublabel = 'probe + customer'; Tone = 'warn' }
    )
    Sections = @(
        @{
            Title        = 'What the data shows'
            SubtitleHtml = 'Side-by-side outbound gRPC, 2026-04-20 06:00-06:30 UTC.'
            BodyHtml     = $dataTable
            Callout      = @{ Tone = 'accent'; Html = 'Two nodes &middot; two destinations &middot; two ports &mdash; <strong>identical 100% failure</strong>. That isn&rsquo;t &ldquo;gRPC stale&rdquo;. That&rsquo;s a <strong>host-level SDN partition</strong>.' }
        }
    )
    Recommendations = @(
        @{ Priority = 'P0 - Today';     Tone = 'bad';    Title = 'Bounce D & K together'; BodyHtml = 'Almost certainly co-located on the same Azure host.' }
        @{ Priority = 'P1 - This week'; Tone = 'warn';   Title = 'File partner ticket with Azure SDN';  BodyHtml = "Outbound to specific internal IPs blackholes from this VM pair while peers work fine." }
        @{ Priority = 'PBI';            Tone = 'accent'; Title = 'Self-fence on the gateway';           BodyHtml = "Fail the readiness probe when N consecutive internal RPC failures exceed a threshold, so the LB pulls the node out of rotation." }
    )
    Joke = 'Two nodes, two destinations, zero packets &mdash; D and K achieved perfect symmetry, just in the wrong direction.'
}

$body = (Build-InvestigationEmailHtml -Spec $spec) + (Get-NirvanaSignature)
# ...then send via Outlook COM (same as email-team) with subject:
#   '[Nirvana] Investigation: KvcIngestMonitorJob FAIL on INGEST-KUTRIDENTHOSTER1EUS - node-pair SDN partition'
```

## What NOT to do
- Do **not** use this style for routine team emails, status updates, or daily reports — use `email-team` for those. Investigation styling on a non-investigation looks performative.
- Do **not** invent stats. If you don't have a real number, drop the `Stats` block entirely; an investigation without stats is fine.
- Do **not** skip the preview when the body was auto-composed.
- Do **not** bundle multiple investigations into one email — one investigation per email keeps the hero / TL;DR clean.
- Do **not** modify the palette per-email. The whole point is consistency. If a palette change is needed, edit `_shared/investigation-email.ps1` so all future investigations get it.
- Do **not** introduce a parallel send path. Always go through Outlook COM, same as `email-team`.

## Cross-skill composition
- Future incident-flavored skills (e.g. an automated post-mortem composer fed by the DRI pulse, or an SDN partition detector) should dot-source `_shared/investigation-email.ps1` and produce a `$spec` rather than hand-rolling HTML.
- When `inbox-watch` sees an incident-shaped inbound mail and Nir asks to "reply with an investigation", route through this skill.

