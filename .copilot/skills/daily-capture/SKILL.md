---
name: "daily-capture"
surface: "engine"
---

# Skill: daily-capture

Once-a-day replacement for Cowork's OneDrive feed. Produces the two daily
artifacts Cowork used to drop, using Nirvana's own read path (WorkIQ) instead of
Cowork's Microsoft Graph access, and publishes them to a **local** handoff folder
(both importers run on this same machine, so there is no OneDrive round-trip):

1. **Daily activity summary** — `DailySummary_<YYYY-MM-DD>.md` under
   `reports/daily-capture/published/daily-summary/`. Consumed by
   `run-daily-summary-import.ps1` (which polls that folder every 10 min) and
   routed into `team-personas`.
2. **Per-direct-report capture** — one Markdown file per direct report under
   `reports/daily-capture/published/personas/<YYYY-MM-DD>/`, a raw-ish data drop
   for the persona agent to analyze later.

## Why this exists
Cowork stopped producing real content (last good ingest 2026-05-28). Nir asked
Nirvana to "do the import once a day instead of Cowork." This skill is the
producer; the existing `DM-DailySummaryImport` task stays the consumer.

## Fixed context
- **Runner:** `.copilot/skills/run-daily-capture.ps1`.
- **Prompts:** `prompt-daily-summary.md` (Prompt A) + `prompt-personas-capture.md`
  (Prompt B). The runner substitutes `{{DATE}}`, `{{WINDOW_START}}`,
  `{{WINDOW_END}}`, and the absolute **staging** output paths, then feeds each
  prompt to a `copilot` subprocess via `Invoke-CopilotAgent` (stdin temp file).
- **Scheduled by:** `DM-DailyCapture` — daily **18:00 IST**,
  `execution_time_limit: PT45M` (two subprocesses × many WorkIQ reads).
- **State:** `reports/daily-capture/state/<YYYY-MM-DD>.json` — per-phase A status
  + per-person B status. Idempotency keys on this file, NOT on output-file
  existence (the importer deletes the summary after ingest).
- **Staging:** subprocesses write under `reports/daily-capture/staging/<date>/`
  (inside the agent root / cwd, so no `--add-dir` is needed and the every-10-min
  importer never sees a half-written file). The runner VALIDATES the staged
  output, then COPIES it to the local handoff folder (atomic publish).
- **Log:** `reports/logs/daily-capture-<YYYY-MM-DD>_HHmm.log` (+ per-phase agent
  logs `..._A.log` / `..._B.log`).
- **Handoff base (local):** `reports/daily-capture/published/`
  (`daily-summary/` + `personas/<date>/`). Paths are configurable via
  `paths.daily_capture_summary` / `paths.daily_capture_personas` in
  `config/agent.json`. No OneDrive — Cowork's old sync channel is retired.

## Read-fidelity caveat (important)
WorkIQ (`workiq-ask_work_iq`) is Nirvana's only M365 read path and it
**summarizes / paraphrases** — it cannot return verbatim message bodies the way
Cowork's Graph access did. Therefore:
- Prompt A (a summary by design) is fully honored.
- Prompt B's original "RAW, do not summarize, verbatim bodies" requirement
  **cannot be fully met**. Prompt B is best-effort structured/summarized capture,
  and every personas file carries an explicit fidelity caveat line. The prompt is
  written to NOT claim verbatim capture, and the runner validates the caveat is
  present.

## Contract for Prompt A (so the importer ingests it)
The staged `DailySummary_<date>.md` MUST contain:
- A top overview section (totals, top 3 themes, urgent / action-required items).
- A `## By Person` (or `## Activity by Person`) section with one `### <Name> - <Role>`
  block per person, each block self-contained and factual (no bare "today"/pronouns).

The runner refuses to publish (and marks the phase failed) if the staged file is
empty, lacks the `## By Person` section, has no `### Name - Role` block, or looks
like agent error/apology text.

## What the runner owns vs the subprocess
- **Subprocess (copilot + WorkIQ):** retrieval + drafting the Markdown into staging.
- **Runner (PowerShell):** preflight, prompt substitution, per-phase state,
  validation, atomic publish to the local handoff folder, and the single signed
  summary email.
  The subprocesses never send email.

## Summary email
After both phases, the runner sends ONE summary email to Nir via
`Send-RunnerSummaryEmail` (canonical signature + joke), reporting a per-phase
failure taxonomy: produced / validated / published / skipped (state) / failed,
plus the Prompt B per-person file count and the local handoff folder paths/link.

## Manual usage
```
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-daily-capture.ps1
```
Flags: `-Force` (ignore state, regenerate), `-OnlyA`, `-OnlyB`, `-DryRun`
(compose prompts + report plan, spawn nothing, send nothing).

## Direct reports captured by Prompt B (14)
Teammate9, Teammate10, Teammate14, Teammate2, Teammate1,
Teammate13, Teammate12, Teammate8, Teammate4, Teammate7, Teammate5,
Teammate3, Teammate6, Teammate11. (Emails are listed verbatim in
`prompt-personas-capture.md`.)

