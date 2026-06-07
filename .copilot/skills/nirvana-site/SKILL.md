# nirvana-site — Skill

Builds a self-contained single-file HTML "Nirvana Explorer" at `reports/site/nirvana.html`. Lets Nir browse all skills, personas, workspace artifacts, scheduled tasks, and conventions in one place. Read-only (Phase 1) with clipboard-copy of skill triggers.

## Trigger phrases (case-insensitive)
- "build the nirvana site"
- "rebuild nirvana explorer"
- "regen the site"
- "open the nirvana site"
- "nirvana-site"

## What it does
1. Reads `config/skills.json` (the single source of truth for skills).
2. For each skill, loads its `SKILL.md` if it exists. Skills are grouped by their
   `role` field into the **6 role-agents** (Chief of Staff, Sprint & Delivery,
   Reliability / DRI, Code & Knowledge, Comms, Personal Life). `role_order` in
   `build.py` controls the display order + per-agent blurbs; `category` is kept as
   a secondary badge on each skill.
3. Loads team personas from `.copilot/skills/team-personas/people/*.md`.
4. Loads workspace artifacts:
   - `reports/directs-scope/scope-board.md`
   - `reports/team-agenda/open-discussions.md`
   - `reports/personal-todos/todos.md`
   - `reports/reminders/reminders.md`
   - `reports/one-on-ones/*.md`
   - `config/sdk-rotation.md`
   - `.copilot/skills/team-personas/ownership-snapshot.md`

   Workspace entries are picked by explicit path — they don't have to live under `reports/`. Anything that's operational state Nir actively manages (rotations, scope boards, agendas, reminders, ownership snapshots) belongs here regardless of where on disk it sits.
5. Loads conventions: `.copilot/skills/_shared/joke-playbook.md`, `_shared/signature.md`, `config/voice.md`. Conventions are tone/style/format guides — not operational state.
6. Lists `DM-*` scheduled tasks via `Get-ScheduledTask`.
7. Renders all markdown to HTML, embeds as JSON, emits a single self-contained HTML file at `reports/site/nirvana.html`.

## How to run
```powershell
python .\.copilot\skills\nirvana-site\build.py
```
Then open `reports/site/nirvana.html` in a browser.

## Conventions
- Clawpilot theme (warm off-white light / dark charcoal dark, deep rose accent).
- Theme detection script + CSS vars per `web-artifacts-builder` skill mandate.
- System font stack (Segoe UI, Aptos, …); no external CDN dependencies (fully offline).
- Hash-based routing (`#skills/sprint-create`, `#people/lea-Teammate2`, etc.).

## Files
- `build.py` — the builder.
- `SKILL.md` — this file.

## Future
- Daily scheduled rebuild via `DM-NirvanaSiteBuild` (not yet registered).
- Phase 2: "Copy as full prompt" buttons that prefill multi-arg skill calls.
- Phase 3: optional local backend that actually invokes skills from the UI.

