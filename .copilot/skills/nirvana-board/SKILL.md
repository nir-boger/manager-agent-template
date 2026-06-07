# nirvana-board

Local browser-based dashboard for the four Nirvana task stores Nir lives in:

- **Todos** (`reports/personal-todos/todos.md`, PT-NNN)
- **1:1s** (`reports/one-on-ones/<slug>.md`, ON-NNN per partner)
- **Team Agenda** (`reports/team-agenda/open-discussions.md`, TA-NNN)
- **AI Plan** (`reports/ai-plan/ai-plan.md`, AP-NNN — same section shape as Team Agenda)
- **Scope board** (`reports/directs-scope/scope-board.md`, GFM tables - every cell editable in-place)
- **SDK rotation** (`config/sdk-rotation.md`, GFM table - every cell editable, rows drag-to-reorder; column 0 auto-renumbered)

Nir already has Nirvana chat to add items by voice and daily emails to nudge
him. The board is the *visual* surface: a Clawpilot-themed web app at
`http://localhost:5180` for when Nir wants to scan everything at once, add
several items in a row, or close a batch without typing chat commands.

**Markdown files remain the single source of truth.** Every Nirvana skill
(daily PT email, team-agenda Mon/Tue reminders, one-on-one-agenda
pre-meeting reminder, +Nirvana handoff, inbox-watch auto-PT, etc.) keeps
working unchanged. The board reads + writes the same files those skills do.

## Trigger phrases

| Nir says | Mode |
|---|---|
| "open my board", "launch the board", "open nirvana board", "start the board", "nirvana board", "show me the board" | Start the server + open browser |
| "stop the board", "close the board", "kill the board" | Stop the server |

## How it works

- `serve.py` is a Python 3.12 stdlib `http.server` on `127.0.0.1:5180`.
  No Flask, no FastAPI, no pip install required.
- `markdown_io.py` parses the three markdown shapes into JSON and writes
  closes / snoozes back atomically (temp-file + rename, same pattern as
  `personal-todos/add-item.py`).
- Adds shell out to the canonical helpers so the proven write path is
  reused:
  - `personal-todos/add-item.py` (PT-NNN)
  - `one-on-one-agenda/add-item.py` (ON-NNN per file)
  - `team-agenda/add-item.py` (TA-NNN — new, mirrors the PT/ON shape)
  - `team-agenda/add-item.py --id-prefix AP` (AP-NNN — the **AI Plan** board reuses the same helper and section shape with an AP- id prefix, writing to `reports/ai-plan/ai-plan.md`)
- Frontend is one `index.html` + `app.js` + `style.css`, vanilla JS,
  Clawpilot tokens copied from `nirvana-site/template.html`.

## API surface (localhost only)

| Method | Path | Effect |
|---|---|---|
| GET    | `/` | Board SPA (Todos / Agenda / AI Plan / 1:1s) |
| GET    | `/explorer` | Serves the latest `reports/site/nirvana.html` (Nirvana Explorer). 503 with a "rebuild me" page if the artifact is missing. |
| GET    | `/api/health` | `{ok:true,version}` |
| GET    | `/api/board`  | Snapshot of all three sources |
| POST   | `/api/todos`  | Shell out to `personal-todos/add-item.py` |
| PATCH  | `/api/todos/PT-NNN` | Close / snooze / reopen via `markdown_io` |
| POST   | `/api/one-on-ones/<slug>` | Shell out to `one-on-one-agenda/add-item.py` |
| PATCH  | `/api/one-on-ones/<slug>/ON-NNN` | Close via `markdown_io` |
| POST   | `/api/agenda` | Shell out to `team-agenda/add-item.py` |
| PATCH  | `/api/agenda/TA-NNN` | Close via `markdown_io` |
| POST   | `/api/ai-plan` | Shell out to `team-agenda/add-item.py --id-prefix AP` (writes `reports/ai-plan/ai-plan.md`) |
| PATCH  | `/api/ai-plan/AP-NNN` | Close / reopen / edit via `markdown_io` |
| GET    | `/api/scope-board` | Parsed view of `reports/directs-scope/scope-board.md` (every GFM table, each cell as `{raw, html}`). Also embedded in `/api/board` under `scope_board`. |
| PATCH  | `/api/scope-board` | Update one cell. Body `{table, row, col, value}`. Atomic write via `scope_board_io.mutate_scope_board_cell`. Powers the **Scope board** tab in the Board UI. |
| GET    | `/api/sdk-rotation` | Parsed view of `config/sdk-rotation.md` (same shape as scope-board plus `order_table_index` pointing at the `## Current order` table). Also embedded in `/api/board` under `sdk_rotation`. |
| PATCH  | `/api/sdk-rotation` | Update one cell. Body `{table, row, col, value}`. Atomic write via `sdk_rotation_io.mutate_sdk_rotation_cell`. |
| PATCH  | `/api/sdk-rotation/order` | Reorder the rows of the `## Current order` table. Body `{order: [int, ...]}` is a permutation of `[0..N-1]`. Column 0 (`#`) is auto-renumbered. Atomic write via `sdk_rotation_io.reorder_sdk_rotation_rows`. Powers the drag handle in the **SDK rotation** tab. |

Server binds to `127.0.0.1` only. No auth - single-user, single-host.

## One Nirvana, one URL

The board co-hosts the **Nirvana Explorer** (the read-only browse site
built by the `nirvana-site` skill) at `/explorer`. Top-right pill in the
Board topbar links to it; the Explorer's topbar carries a reciprocal
"Board ->" pill that live-probes `/api/health` to indicate whether the
Board is currently up. Both surfaces still work standalone:

- The Explorer remains a committable single-file `reports/site/nirvana.html`
  (rebuilt nightly by `DM-NirvanaSiteBuild`). Open it directly via `file://`
  and the Board pill just greys out gracefully.
- The Board still runs on demand. When it's up, the Explorer is one click away.

## Launching

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-nirvana-board.ps1
```

Flags:

- `-Port 5180` (default)
- `-NoBrowser` — start the server but don't open a browser tab
- `-Stop` — stop a running board

The runner starts `serve.py` detached, polls `/api/health` until ready
(max 10s), then opens the default browser at `http://localhost:5180/`.

## What this skill does NOT do

- No scheduled task. The board is opened on demand only.
- No new markdown formats — uses the existing PT / ON / TA shapes verbatim.
- No PR review queue / Reminders / Milestones tabs (yet — they can be added
  as new tabs reading the same way).
- No authentication, no HTTPS, no remote access.
