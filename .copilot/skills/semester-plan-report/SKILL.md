# semester-plan-report

Builds and emails the **DM Semester Plan progress dashboard** to Your VP (PM), A Peer (PM's manager), and Your Manager (Nir's manager). Nir is on CC.

**Cadence**: every other Thursday at 16:00 IST, gated to **sprint close only**. Scheduled task `DM-SemesterPlanReport` runs weekly; the runner self-gates against the current ADO iteration's `finishDate` and exits quietly on non-sprint-end weeks.

## Trigger phrases

- `run semester plan report` / `run semester plan` / `semester plan report`
- `build semester plan dashboard`
- `semester pulse` / `run semester pulse`
- `preview semester plan` / `semester plan dry run`
- `email semester plan` / `send semester plan`

## What it does

1. **Refresh ADO state** (every run)
   - Loads `feature-ids.json` (the 27 Feature IDs from Your Manager's planning sheet "Nir" tab).
   - Runs a WIQL `WorkItemLinks` recursive query → descendant tree → `state/link-tree.json`.
   - Batch-fetches all Features + descendants via `wit/workitemsbatch?api-version=7.1` (max 200 IDs per call) → `state/all-items.json`.
2. **Render** `state/dashboard.html` via `build.py` — Feature + PBI level only, Clawpilot theme, single self-contained file with theme toggle.
3. **Email** via Outlook COM:
   - To: `someone@example.com; someone@example.com; someone@example.com`
   - Cc: `you@example.com; team@example.com`
   - Subject: `DM Semester Plan - bi-weekly progress (Sprint N of 14, <verdict>)`
   - Body: pulse summary (semester window, day X of 183, sprint N of 14, PBI %, verdict), brief change notes if any, joke, signature.
   - Attaches `dashboard.html`.
4. **Log** to `reports/logs/semester-plan-report-YYYY-MM-DD_HHmm.log`.

## Inputs

| File | Purpose | Refresh |
|---|---|---|
| `nir-sheet.json` | Snapshot of Your Manager's planning xlsx "Nir" tab (87 rows, headers + CUTLINE). | Manual — when Your Manager changes the plan, re-snapshot via `ms-excel:ofe\|u\|<share-url>` + WinPS 5.1 Excel COM. |
| `feature-ids.json` | The 27 ordered Feature IDs derived from `nir-sheet.json`. | Manual, regenerate alongside `nir-sheet.json`. |
| `state/link-tree.json` | WIQL hierarchy result. | Auto, every run. |
| `state/all-items.json` | ADO batch fetch result. | Auto, every run. |

## Outputs

- `state/dashboard.html` — single-file Clawpilot dashboard (~90 KB).
- `reports/logs/semester-plan-report-*.log` — full run log.

## Sprint-close self-gate

The runner queries `https://your-ado-org.visualstudio.com/One/_apis/work/teamsettings/iterations?$timeframe=current&api-version=7.1` with team `Your Team` and compares `finishDate` (date portion, IST) to today. Override flags:

| Flag | Effect |
|---|---|
| `-Force` | Skip sprint-end check, always send. |
| `-DryRun` | Build dashboard, do not send. Email subject/body printed to log. |
| `-PreviewOnly` | Build + send to Nir only (no VP/A Peer/Your Manager), for verification. |

## Auth

- ADO REST via `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798`. The signed-in account (`someone@example.com`) needs read access to the `One` project work items.
- Outlook COM uses the running Outlook session for sends.

## Voice rules

- Joke + signature mandatory (per `AGENTS.md` voice rules) unless `NOJOKE` / `NOSIG` appears in the override.
- Joke pool — rotate Nirvana-band references (see `.copilot/skills/_shared/joke-playbook.md` + `examples/voice-profiles/nirvana-band.md`). Already used in prior sends: "Come As You Are", "On a Plain", "Plateau" — avoid back-to-back repeats.
- Signature: `Get-NirvanaSignature` from `.copilot/skills/_shared/signature.ps1` — speaks "on Nir's behalf". External audience, so include the show-and-tell promo (do NOT pass `-NoNotice`).

## Refreshing the plan (when Your Manager's xlsx changes)

When Your Manager adds, removes, or re-ranks Features:

1. Open Your Manager's share URL with `Start-Process "ms-excel:ofe|u|<share-url>"`.
2. Attach via Windows PowerShell 5.1: `& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[System.Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')"` and dump the "Nir" sheet rows + hyperlinks.
3. Regenerate `nir-sheet.json` + `feature-ids.json` in the skill folder.
4. Commit the snapshot.

This is a manual step — keep it that way (the plan sheet is Your Manager's source of truth, not Nirvana's to read every cycle).

## Files

- `SKILL.md` — this file
- `build.py` — Python renderer
- `nir-sheet.json` — committed snapshot of the planning sheet
- `feature-ids.json` — committed Feature ID order
- `state/` — runtime data, gitignored
- `../run-semester-plan-report.ps1` — orchestrator (runner)

## Scheduled task

```
Name:      DM-SemesterPlanReport
Trigger:   Weekly, Thursdays, 16:00 IST
Action:    wscript.exe "...\run-hidden.vbs" "...\run-semester-plan-report.ps1"
Self-gate: today == current iteration finishDate, else exit 0
```

## Tests

`tests\semester-plan-report.tests.ps1` covers:

- Skill manifest schema (name/path/show_in_agents/ship_in_snapshot)
- Runner ASCII-only constraint (PS 5.1)
- Joke + signature present in compose path
- Recipients hardcoded correctly
- Single-instance lock acquisition
- Dry-run produces dashboard.html without sending

## History

- 2026-05-14: v1 (Task-level) drafted, replaced same day with v2 (Feature + PBI level only + Semester Pulse intro). First external send to VP/A Peer/Your Manager 2026-05-14 ~10:09 IST. Skill productized + scheduled.
- 2026-05-17: v3 — answers A Peer's two follow-up asks. Adds **Capacity & Pace** section (budget 212.75 PW vs commit 216 PW, +3.25 over; person-weeks delivered+in-flight vs elapsed-time target; per-Feature pace chip on Active Features). Adds **"What changed since last refresh"** panel (diff vs newest prior `state/snapshots/YYYY-MM-DD.json`: PBIs added/removed/completed/slipped/pulled-in + Feature %-done deltas). `build.py` now also writes today's snapshot to `state/snapshots/<today>.json` for next run's diff. DRI accounting conflict (23 weeks/person net vs 36 PW DRI line above cutline) surfaced as an inline flag for Your Manager to reconcile.

