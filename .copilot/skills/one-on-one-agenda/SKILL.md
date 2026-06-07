# one-on-one-agenda

Tracks talking points Nir wants to raise at the next 1:1 with a specific person. One markdown file per person at `reports/one-on-ones/<slug>.md` with `ON-NNN` IDs. Same item shape as `team-agenda` (`Discussion` / `Follow-up` Kind, Status, Summary, Why it matters, Next step).

Scales to any 1:1 partner — manager (Your Manager), VP (Your VP), peers, direct reports, leadership. The skill doesn't hard-code the roster; Nirvana resolves names ("Your Manager", "VP", "Teammate1") to the right file slug.

**Built-in scheduled reminder:** `DM-OneOnOneAgenda` — every 5 min, 24/7. Each tick the runner (`.copilot/skills/run-one-on-one-agenda.ps1`) scans `reports/one-on-ones/*.md`, finds any file with open `ON-NNN` items, then queries Outlook for any meeting starting in the next ~35 min whose subject contains the person's name (from the file's `# 1:1 agenda - <Person>` header) AND a 1:1 indicator (`1x1`, `1:1`, `1-on-1`, `1on1`, `one-on-one`, `1 on 1`). For every match it fires exactly one email to Nir with the open agenda table, then stamps `state/sent-instances.txt` so the same meeting instance never re-fires. **Auto-extends to new partners — drop a new `reports/one-on-ones/<slug>.md` with the standard header and items, no extra config.**

## Trigger phrases → mode

| User says | Mode |
|---|---|
| "add to my 1:1 with <X>", "add to my next 1:1 with <X>", "for my 1:1 with <X>", "track for my next 1:1 with <X>", "raise with <X> at our next 1:1", "save for my 1:1 with <X>", "for next 1:1 with <X>" | **Add item** |
| "what's on my 1:1 with <X>", "list my 1:1 agenda with <X>", "show my <X> 1:1 agenda", "what's on my agenda with <X>" | **List open** |
| "close ON-NNN", "mark ON-NNN closed", "we covered ON-NNN", "ON-NNN done" | **Close item** |
| "one-on-one-agenda", "1:1 agenda" | **Help / disambiguate** |

## Modes

### Add item

1. **Resolve the person to a file** — `reports/one-on-ones/<slug>.md`.
   - Slug rule: lowercase first name (e.g. `Your Manager.md`, `Teammate1.md`). Use `firstname-lastname` only when disambiguation is needed.
   - Common shortcuts: `Your Manager` → `Your Manager.md` (manager), `VP` → `vp.md` (Your VP), `A Peer` → `A Peer.md`.
   - If the file doesn't exist, the helper creates it with the standard skeleton.

2. **Pick a Kind:** `Discussion` (new topic to raise) or `Follow-up` (revisit an earlier 1:1 item). Default `Discussion` unless Nir's phrasing screams follow-up ("circle back on…", "check in on…", "still pending…").

3. **Call the helper — MANDATORY, never hand-roll Markdown.** Same lesson as `personal-todos` (silent ID-write bug, 2026-05-12).

   ```powershell
   python .copilot\skills\one-on-one-agenda\add-item.py `
     --agenda-file reports\one-on-ones\Your Manager.md `
     --person Your Manager `
     --title "<short title>" `
     --kind discussion `
     --opened-by Nir `
     --owner TBD `
     --summary "<one-paragraph problem statement, in Nir's voice>" `
     --why-matters "<one-line stake>" `
     --next-step "<concrete next action — discuss, decide, ask X>" `
     --notes "<optional extra context, single line>"
   ```

4. **Confirm to Nir:** `Added ON-NNN to my 1:1 with <X> — <title> (<Kind>). Now N open items.`

### List open

Parse the per-person file. Show a one-line summary per open item:

```
ON-NNN — <title> (<Kind>, opened YYYY-MM-DD)
```

Don't dump full sections unless Nir asks. If the file doesn't exist, say so cleanly: `No 1:1 agenda yet for <X>.`

### Close item

1. Locate `### ON-NNN` in the appropriate file (Nirvana scans `reports/one-on-ones/*.md` if the person isn't specified).
2. Flip `Status:` to `Closed`. Add `Closed on: YYYY-MM-DD`.
3. Move the whole section to the `## Closed` section at the bottom.
4. Confirm: `Closed ON-NNN in my 1:1 with <X>. M open items remain.`

## File shape (one per person)

```markdown
# 1:1 agenda - <Person>

Open talking points Nir wants to raise at the next 1:1 with <Person>.

---

## Open

### ON-001 — <title>

- **Status:** Open
- **Kind:** Discussion | Follow-up
- **Opened by:** Nir
- **Opened on:** YYYY-MM-DD
- **Owner:** TBD
- **Summary:** <one paragraph>
- **Why it matters:** <one line>
- **Next step:** <concrete next action>
- **Notes:** <optional>

---

## Closed

_(Empty — closed items will be moved here for history.)_
```

## Parsing rules (for future renderers / tools)

- Heading regex: `^###\s+(ON-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$` — accepts em-dash OR ASCII hyphen on read; the helper always writes em-dash (`\u2014`), matching `team-agenda`.
- Field regex: `^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$`.
- Known fields: `Status`, `Kind`, `Opened by`, `Opened on`, `Owner`, `Summary`, `Why it matters`, `Next step`, `Notes`, `Closed on`.
- Item is **Open** iff `Status == Open` AND its section sits above the `## Closed` marker (defense-in-depth).
- `Kind` values: `Discussion` or `Follow-up` (case-insensitive; anything starting with `follow` counts as Follow-up; missing/blank → Discussion). Mirrors `team-agenda`.

## Helper contract (`add-item.py`)

- Computes next `ON-NNN` from the target file (max existing + 1, zero-padded). Counter is **per-file**, not global — each person gets their own ON-001, ON-002, etc.
- Validates `--title` non-empty.
- Normalizes `--kind` (accepts `discussion`, `follow-up`, `followup`, `fu` — anything starting with `follow` → `follow-up`).
- If `--agenda-file` doesn't exist, creates the skeleton (uses `--person` as the display label, falls back to title-cased file stem).
- Strips the `## Open` empty-state placeholder when present so the first real item lands clean.
- Atomic write: `.tmp` → rename.
- Emits one TSV line on stdout: `ON-NNN<TAB>title<TAB>kind`.

## Voice rules

This skill writes to disk only. Any email / chat output (e.g. Nirvana's confirmation line, a future weekly digest) follows standard email voice rules: joke + signature mandatory unless `NOJOKE` / `NOSIG` appears.

## Future enhancements

- **Per-person 1:1 subject override:** optional `Meeting subject match:` preamble field in each file for cases where the default `<person name> + 1:1-indicator` logic produces false positives or misses (e.g. a calendar where 1:1s are titled `Sync` instead of `1x1`).
- **Closed-items retro:** monthly digest of recent ON-NNN closures across all 1:1 files for retrospective tracking.
- **Cross-link to ADO:** allow `Linked PBI/Task: <id>` field so closure flows back to work items.

## Files

- `SKILL.md` — this file
- `add-item.py` — atomic add helper (the ONLY supported way to write items)
- `../run-one-on-one-agenda.ps1` — pre-1:1 polling reminder runner (every 5 min via `DM-OneOnOneAgenda`)
- `state/sent-instances.txt` — per-meeting-instance idempotency (line per `<slug>:<start ISO>`)
- `state/preview.html` — last rendered email (handy for debugging)
- `../../reports/one-on-ones/<slug>.md` — per-person agendas (source of truth)

## Runner contract (`run-one-on-one-agenda.ps1`)

Manual run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot\skills\run-one-on-one-agenda.ps1
```

Flags:

- `-DryRun` — parse + match + log + write preview HTML, do NOT send.
- `-Force` — bypass per-meeting-instance idempotency.
- `-LookAheadMin <N>` — how far ahead to scan Outlook. Default `35` (= 30-min fire offset + 5-min poll slack).
- `-OffsetMin <N>` — fire when meeting is `<= N` min away. Default `30`.
- `-AsOfDate <s>` — override "now" for testing.

Subject match logic — case-insensitive substring of the person token (from the `# 1:1 agenda - <Person>` header) AND any 1:1 indicator (`\b1x1\b`, `\b1:1\b`, `\b1-on-1\b`, `\b1on1\b`, `\bone[- ]on[- ]one\b`, `\b1\s+on\s+1\b`). Both must hit. This keeps "Your Manager farewell party" or "VP all-hands" from triggering by accident while still matching `Nir / Your Manager - 1x1`, `VP <-> Nir 1on1`, etc.

## History

- 2026-05-14: Skill created. First file: `reports/one-on-ones/Your Manager.md` seeded with `ON-001` (Business Events velocity — pre-AI sanity check). Paired with `RM-NNN` in the `reminders` skill firing 30 min before the next "Nir / Your Manager - 1x1" (Mon 2026-05-25 14:00 IST).

