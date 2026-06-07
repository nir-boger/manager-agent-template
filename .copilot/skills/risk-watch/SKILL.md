# risk-watch

Tracks **delivery risks** the Your Team is carrying — things that may slip and need an owner, a RAG level, a mitigation, and a next checkpoint. A living register, plus a **weekly pulse** email to Nir. Distinct from `team-agenda` (discussion items) and `personal-todos` (Nir's action items): this skill is for *risks to delivery*.

**Register file:** `reports/risks/register.md` (markdown, hand-readable, source of truth).
**Scheduled task:** `DM-RiskWatchPulse` — weekly, **Sundays 08:45 IST**, emails **Nir** the open Red + Amber risks.
**Runner:** `.copilot/skills/run-risk-watch-pulse.ps1`.
**Add helper (mandatory):** `.copilot/skills/risk-watch/add-item.py` — single source of truth for `RK-NNN` assignment, field order, atomic write.

## Trigger phrases -> mode

| User says | Mode |
|---|---|
| "add a risk", "track a risk", "log a risk", "this is at risk", "raise a risk" | **Add item** |
| "what are our risks", "list risks", "show the risk register", "open risks" | **List open** |
| "RK-NNN rag red/amber/green", "RK-NNN owner X", "RK-NNN checkpoint <date>", "RK-NNN area X" | **Edit item** |
| "close RK-NNN", "RK-NNN resolved", "RK-NNN no longer a risk" | **Close item** |
| "send the risk pulse now", "remind me of our risks now", "risk-watch" | **Send pulse now** |

## Field model

`Status` is the **lifecycle** (Open / Closed). `Risk` is the **RAG level** (Red / Amber / Green). They are deliberately separate: a Green risk is still Open (tracked, low concern); closing is for risks that are resolved or no longer apply.

```markdown
### RK-007 — <short title>

- **Status:** Open
- **Risk:** Red | Amber | Green
- **Area:** <component / workstream, e.g. Geneva>
- **Owner:** <name, default TBD>
- **Opened on:** YYYY-MM-DD
- **Why at risk:** <one-paragraph: the concrete failure mode / blocker>
- **Mitigation:** <the plan to de-risk; TBD if not yet known>
- **Next checkpoint:** YYYY-MM-DD (or `-`)
- **Linked ADO:** <work item id / url, or `-`>
- **Notes:** <free-form context>
```

## Modes

### Add item

**MANDATORY: always invoke `add-item.py`.** Never hand-roll the markdown (same reasoning as `personal-todos` / `team-agenda` — the helper owns ID assignment, field order, and atomic write).

1. Parse Nir's message. Extract **Title**, and optional `rag=` (default `amber`), `area=`, `owner=`, `checkpoint=<date>`, plus `why`/`mitigation`/`notes` after `--` or `notes:`.
2. Invoke:
   ```powershell
   python .copilot/skills/risk-watch/add-item.py `
     --register-file reports/risks/register.md `
     --title "<title>" `
     [--rag red|amber|green] [--area "<area>"] [--owner "<owner>"] `
     [--checkpoint YYYY-MM-DD] [--why "<why>"] [--mitigation "<plan>"] [--notes "<notes>"]
   ```
   The helper computes `max(RK-NNN) + 1` across both sections, writes atomically (`.tmp` -> rename, UTF-8 LF), and emits one TSV line: `RK-NNN\ttitle\trag`.
3. Echo: `Added RK-NNN — <title> (<rag>). N open risks (X red / Y amber / Z green).`

### List open

Parse the register. One line per open risk, **Red first, then Amber, then Green**; within a band, overdue checkpoint first:
`RK-001 [Amber] Min instance count in the Geneva fix — owner TBD — checkpoint 2026-06-12 (Geneva)`.

### Edit item

`RK-001 rag red` / `RK-001 owner Saeed` / `RK-001 checkpoint 2026-06-19` / `RK-001 area Ingestion`. Locate the `### RK-NNN` section, update the one field, confirm the new value. Chain multiple edits if Nir lists them.

### Close item

1. Locate `### RK-NNN` in `## Open`.
2. Flip `Status` to `Closed`, add `Closed on: YYYY-MM-DD`.
3. Move the whole section to `## Closed`.
4. Confirm: `Closed RK-NNN. N open risks remain.`

### Send pulse now

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-risk-watch-pulse.ps1 -Force
```
`-Force` bypasses the per-week idempotency check. `-DryRun` builds + logs without sending. `-AsOfDate YYYY-MM-DD` overrides "today" (drives checkpoint badges) for testing.

## Parsing rules (for the runner)

- Heading regex: `^###\s+(RK-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$` (em-dash or hyphen).
- Field regex: `^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$`.
- Known fields: `Status`, `Risk`, `Area`, `Owner`, `Opened on`, `Why at risk`, `Mitigation`, `Next checkpoint`, `Linked ADO`, `Notes`, `Closed on`.
- A risk is **Open** iff it is in `## Open` AND `Status` is `Open` or blank. Anything under `## Closed` is treated as closed (defense-in-depth).
- `Risk` normalizes: `r/red`->Red, `a/amber/y/yellow`->Amber, `g/green`->Green; missing/unknown -> Amber.

## Weekly pulse email

- **Subject:** `[Nirvana] Risk watch — <2 red, 1 amber>` (`all green` when only Green open; `nothing tracked` when empty).
- **Body:**
  - Opener with the actionable (Red + Amber) count.
  - **Red table**, then **Amber table** — each sorted overdue-checkpoint-first, then nearest checkpoint, then ID. Columns: ID, Owner/Area, Risk (title + why + mitigation), Checkpoint (badge: `overdue Nd` red, `due this week` amber, `by <date>`, `no checkpoint`).
  - Green risks omitted from the tables with a one-line count.
  - One joke (rotated; honors `NOJOKE`).
  - `Get-NirvanaSignature` (honors `NOSIG`).
- **Always sends**, even all-green or empty, so silence is never ambiguous.

Shared renderer: `.copilot/skills/risk-watch/render.ps1` (`Render-RiskPulse`, `Get-RiskCounts`, `Format-RiskSubjectTail`, `Get-RiskCheckpointInfo`). The runner dot-sources it.

## Idempotency

State file `.copilot/skills/risk-watch/state/last-sent.txt` holds the most recent ISO week tag (`yyyy-Www`) sent. The runner skips when the current week tag already appears, unless `-Force`.

## Cross-skill composition

- **`sprint-digest`** — when the digest flags an at-risk work item that's really a delivery risk, suggest opening an `RK-NNN` here (not auto-filed in v1).
- **`one-on-one-prep` / `team-agenda`** — a risk owned by a direct is good 1:1 material; a risk that needs a team decision is good WSR material. Reference the `RK-NNN` rather than duplicating.

## Privacy / scope

- All content stays in this repo (private). `state/` is gitignored.
- The pulse goes to **Nir only**; never a DL.
- The skill never modifies ADO work items.

