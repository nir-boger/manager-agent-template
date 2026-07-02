#!/usr/bin/env python3
"""nirvana-board HTTP backend.

Stdlib-only (Python 3.12). Binds to 127.0.0.1 on the requested port. Reads +
writes the three Nirvana markdown stores:

  - reports/personal-todos/todos.md          (PT-NNN)
  - reports/team-agenda/open-discussions.md  (TA-NNN)
  - reports/one-on-ones/*.md                 (ON-NNN, one file per partner)

Adds go through the canonical add-item.py helpers via subprocess so the same
counter/shape logic the chat path uses is reused. Closes/snoozes/reopens go
through markdown_io.py directly.

Usage:
  python serve.py [--port 5180] [--host 127.0.0.1] [--repo-root PATH]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
import time
from datetime import date, datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

THIS_FILE = Path(__file__).resolve()
SKILL_DIR = THIS_FILE.parent
STATIC_DIR = SKILL_DIR / "static"
DEFAULT_REPO_ROOT = SKILL_DIR.parent.parent.parent  # .copilot/skills/nirvana-board -> repo root

# Path to the static Explorer artifact (built by the nirvana-site skill).
# The board serves it at /explorer so Nir can flip between the live CRUD
# Board and the read-only Explorer behind a single URL.
EXPLORER_ARTIFACT = DEFAULT_REPO_ROOT / "reports" / "site" / "nirvana.html"

sys.path.insert(0, str(SKILL_DIR))
import markdown_io as mio  # noqa: E402
import scope_board_io as sbio  # noqa: E402
import sdk_rotation_io as sdkio  # noqa: E402
import directs as directs_mod  # noqa: E402

VERSION = "0.10.0"

# Single write-lock guards every PATCH/POST so concurrent requests don't
# clobber each other's reads.
WRITE_LOCK = threading.Lock()

# Scheduled-task enumeration (Get-ScheduledTask) spawns PowerShell and takes
# ~2s across the ~35 DM-* tasks, so it is deliberately kept OUT of the
# per-load /api/board snapshot. Instead the Board lazy-loads /api/scheduled-tasks
# once after boot (and on manual refresh). A short in-process cache means rapid
# tab-switches / auto-refreshes reuse the last result instead of re-spawning.
_SCHED_LOCK = threading.Lock()
_SCHED_CACHE: dict[str, Any] = {"ts": 0.0, "data": None}
_SCHED_TTL = 60.0  # seconds

# Today's Outlook calendar (My Day tab) is read via a PowerShell/COM spawn that
# costs ~1-2s, so - like the scheduled tasks - it is lazy-loaded via its own
# /api/my-day endpoint and the *meetings* portion is cached in-process. The
# board-derived suggestions (needs-attention / focus) are recomputed from a
# fresh board snapshot on every call so they reflect closes/adds immediately.
_CAL_LOCK = threading.Lock()
_CAL_CACHE: dict[str, Any] = {"ts": 0.0, "date": None, "data": None, "available": False, "error": None}
_CAL_TTL = 120.0  # seconds


def safe_slug(s: str) -> str:
    """Allow only kebab-case slugs for 1:1 paths so we never escape the
    one-on-ones directory."""
    return s if re.fullmatch(r"[a-z0-9][a-z0-9-]*", s or "") else ""


# --- Paths ---------------------------------------------------------------

class Paths:
    def __init__(self, repo_root: Path) -> None:
        self.root = repo_root.resolve()
        self.todos_md = self.root / "reports" / "personal-todos" / "todos.md"
        self.agenda_md = self.root / "reports" / "team-agenda" / "open-discussions.md"
        self.ai_plan_md = self.root / "reports" / "ai-plan" / "ai-plan.md"
        self.one_on_ones_dir = self.root / "reports" / "one-on-ones"
        self.scope_board_md = self.root / "reports" / "directs-scope" / "scope-board.md"
        self.sdk_rotation_md = self.root / "config" / "sdk-rotation.md"
        self.directs_context_json = self.root / "reports" / "directs-scope" / "directs-context.json"
        self.personas_dir = self.root / ".copilot" / "skills" / "team-personas" / "people"
        # Helper scripts
        self.pt_add = self.root / ".copilot" / "skills" / "personal-todos" / "add-item.py"
        self.ta_add = self.root / ".copilot" / "skills" / "team-agenda" / "add-item.py"
        self.on_add = self.root / ".copilot" / "skills" / "one-on-one-agenda" / "add-item.py"
        # ado-item-tracker: curated ADO work-item watchlist. tracked.json is the
        # committed source of truth (ids + notes); cache.json is the gitignored
        # live-fields cache refreshed by the runner. The Board reads both.
        self.ado_tracker_tracked = self.root / "reports" / "ado-tracker" / "tracked.json"
        self.ado_tracker_cache = self.root / "reports" / "ado-tracker" / "cache.json"
        self.ado_tracker_runner = self.root / ".copilot" / "skills" / "run-ado-item-tracker.ps1"


# --- Board snapshot ------------------------------------------------------

def _list_one_on_one_files(paths: Paths) -> list[Path]:
    if not paths.one_on_ones_dir.is_dir():
        return []
    return sorted(p for p in paths.one_on_ones_dir.glob("*.md") if p.is_file())


def _one_on_one_label(slug: str) -> str:
    return " ".join(part.capitalize() for part in slug.split("-"))


def _bootstrap_one_on_one_stubs(paths: Paths, directs: list[dict]) -> int:
    """Create empty `reports/one-on-ones/<slug>.md` files for any direct who
    doesn't have one yet. Idempotent + safe to call on every board snapshot.
    Returns the count of files created.
    """
    if not directs:
        return 0
    paths.one_on_ones_dir.mkdir(parents=True, exist_ok=True)
    created = 0
    for d in directs:
        slug = d.get("slug") or ""
        if not slug:
            continue
        target = paths.one_on_ones_dir / f"{slug}.md"
        if target.exists():
            continue
        label = d.get("name") or _one_on_one_label(slug)
        stub = (
            f"# 1:1 with {label}\n"
            f"\n"
            f"---\n"
            f"\n"
            f"## Open\n"
            f"\n"
            f"_(Empty - add an item via the Board or `one-on-one-agenda/add-item.py`.)_\n"
            f"\n"
            f"---\n"
            f"\n"
            f"## Closed\n"
            f"\n"
            f"_(Empty)_\n"
        )
        try:
            mio.atomic_write(target, stub)
            created += 1
        except OSError:  # pragma: no cover - defensive
            pass
    return created


def _load_directs_context(paths: Paths) -> dict[str, dict[str, Any]]:
    """Best-effort read of reports/directs-scope/directs-context.json,
    populated by .copilot/skills/run-refresh-directs-context.ps1. Returns
    a dict keyed by slug. Empty on missing/invalid file (callers fall
    back to empty per-direct arrays)."""
    if not paths.directs_context_json.exists():
        return {}
    try:
        import json as _json
        data = _json.loads(paths.directs_context_json.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    raw = data.get("directs") or {}
    out: dict[str, dict[str, Any]] = {}
    for slug, ctx in raw.items():
        if not isinstance(ctx, dict):
            continue
        out[slug] = {
            "recent_prs": list(ctx.get("recent_prs") or []),
            "active_work_items": list(ctx.get("active_work_items") or []),
            "persona_highlights": list(ctx.get("persona_highlights") or []),
            "recent_wins": list(ctx.get("recent_wins") or []),
            "personal_notes": str(ctx.get("personal_notes") or ""),
            "upcoming_milestones": list(ctx.get("upcoming_milestones") or []),
            "generated_at": data.get("generated_at", ""),
        }
    return out


def board_snapshot(paths: Paths) -> dict[str, Any]:
    todos: list[dict[str, Any]] = []
    if paths.todos_md.exists():
        todos = mio.parse_todos(paths.todos_md.read_text(encoding="utf-8"))

    agenda: list[dict[str, Any]] = []
    if paths.agenda_md.exists():
        agenda = mio.parse_agenda(paths.agenda_md.read_text(encoding="utf-8"))

    ai_plan: list[dict[str, Any]] = []
    if paths.ai_plan_md.exists():
        ai_plan = mio.parse_ai_plan(paths.ai_plan_md.read_text(encoding="utf-8"))

    # Resolve the canonical set of direct reports (and their scope-board
    # planning context) so we can bootstrap stubs + decorate the partner
    # records with per-direct headers.  Defensive on failure - we still
    # render the board for files that already exist.
    try:
        directs_list = directs_mod.resolve_directs(paths.scope_board_md, paths.personas_dir)
    except Exception:  # pragma: no cover - defensive
        directs_list = []
    directs_by_slug = {d["slug"]: d for d in directs_list}
    _bootstrap_one_on_one_stubs(paths, directs_list)
    context_by_slug = _load_directs_context(paths)

    one_on_ones: list[dict[str, Any]] = []
    for f in _list_one_on_one_files(paths):
        slug = f.stem
        text = f.read_text(encoding="utf-8")
        items = mio.parse_one_on_one(text)
        open_count = sum(1 for i in items if i["status"] == "open")
        personal_notes = mio.parse_personal_notes(text)
        direct = directs_by_slug.get(slug)
        ctx = context_by_slug.get(slug, {})
        record: dict[str, Any] = {
            "slug": slug,
            "label": (direct or {}).get("name") or _one_on_one_label(slug),
            "open_count": open_count,
            "total_count": len(items),
            "items": items,
            "is_direct": direct is not None,
            "smtp": (direct or {}).get("smtp"),
            "scope_now": (direct or {}).get("scope_now", ""),
            "scope_next": (direct or {}).get("scope_next", ""),
            "scope_now_html": (direct or {}).get("scope_now_html", ""),
            "scope_next_html": (direct or {}).get("scope_next_html", ""),
            "recent_prs": ctx.get("recent_prs", []),
            "active_work_items": ctx.get("active_work_items", []),
            "persona_highlights": ctx.get("persona_highlights", []),
            "recent_wins": ctx.get("recent_wins", []),
            "upcoming_milestones": ctx.get("upcoming_milestones", []),
            "personal_notes": personal_notes,
            "context_generated_at": ctx.get("generated_at", ""),
        }
        one_on_ones.append(record)

    scope_board: dict[str, Any] = {"tables": [], "path": "", "exists": False}
    scope_rows = 0
    if paths.scope_board_md.exists():
        try:
            scope_board = scope_board_snapshot(paths)
            scope_rows = sum(len(t.get("rows") or []) for t in scope_board.get("tables") or [])
        except Exception as ex:  # pragma: no cover - defensive
            scope_board = {"tables": [], "path": str(paths.scope_board_md), "exists": True, "error": str(ex)}

    sdk_rotation: dict[str, Any] = {
        "tables": [], "path": "", "exists": False, "order_table_index": None,
    }
    sdk_rows = 0
    if paths.sdk_rotation_md.exists():
        try:
            sdk_rotation = sdk_rotation_snapshot(paths)
            oi = sdk_rotation.get("order_table_index")
            if oi is not None and oi < len(sdk_rotation.get("tables") or []):
                sdk_rows = len(sdk_rotation["tables"][oi].get("rows") or [])
        except Exception as ex:  # pragma: no cover - defensive
            sdk_rotation = {
                "tables": [], "path": str(paths.sdk_rotation_md),
                "exists": True, "order_table_index": None, "error": str(ex),
            }

    try:
        ado_tracker = ado_tracker_snapshot(paths)
    except Exception as ex:  # pragma: no cover - defensive
        ado_tracker = {"items": [], "path": "reports/ado-tracker/tracked.json",
                       "exists": False, "count": 0, "error": str(ex)}

    return {
        "version": VERSION,
        "today": date.today().isoformat(),
        "todos": todos,
        "agenda": agenda,
        "ai_plan": ai_plan,
        "one_on_ones": one_on_ones,
        "scope_board": scope_board,
        "sdk_rotation": sdk_rotation,
        "ado_tracker": ado_tracker,
        "directs": directs_list,
        "counts": {
            "todos_open": sum(1 for i in todos if i["status"] != "done"),
            "agenda_open": sum(1 for i in agenda if i["status"] == "open"),
            "ai_plan_open": sum(1 for i in ai_plan if i["status"] == "open"),
            "one_on_ones_open": sum(p["open_count"] for p in one_on_ones),
            "scope_board_rows": scope_rows,
            "sdk_rotation_rows": sdk_rows,
            "ado_tracker": ado_tracker.get("count", 0),
            "directs": len(directs_list),
        },
    }


# --- Add helpers (shell out to canonical add-item.py) -------------------

def _run_helper(args: list[str]) -> tuple[int, str, str]:
    cp = subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
    )
    return cp.returncode, cp.stdout, cp.stderr


def add_todo(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    title = (payload.get("title") or "").strip()
    if not title:
        return 400, {"error": "title is required"}
    args = [
        sys.executable, str(paths.pt_add),
        "--todos-file", str(paths.todos_md),
        "--title", title,
        "--category", (payload.get("category") or "work").strip() or "work",
        "--priority", (payload.get("priority") or "M").strip() or "M",
        "--due", (payload.get("due") or "-").strip() or "-",
        "--recur", (payload.get("recur") or "none").strip() or "none",
        "--notes", (payload.get("notes") or "").strip(),
    ]
    rc, out, err = _run_helper(args)
    if rc != 0:
        return 500, {"error": "add-item failed", "rc": rc, "stderr": err.strip()}
    line = (out or "").splitlines()[0] if out else ""
    pt_id = line.split("\t", 1)[0] if line else ""
    return 201, {"id": pt_id, "raw": line}


def add_agenda(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    title = (payload.get("title") or "").strip()
    if not title:
        return 400, {"error": "title is required"}
    args = [
        sys.executable, str(paths.ta_add),
        "--agenda-file", str(paths.agenda_md),
        "--title", title,
        "--kind", (payload.get("kind") or "discussion").strip() or "discussion",
        "--opened-by", (payload.get("opened_by") or "Nir").strip() or "Nir",
        "--owner", (payload.get("owner") or "TBD").strip() or "TBD",
        "--summary", (payload.get("summary") or "").strip(),
        "--why-matters", (payload.get("why_matters") or "").strip(),
        "--next-step", (payload.get("next_step") or "").strip(),
        "--notes", (payload.get("notes") or "").strip(),
    ]
    rc, out, err = _run_helper(args)
    if rc != 0:
        return 500, {"error": "add-item failed", "rc": rc, "stderr": err.strip()}
    line = (out or "").splitlines()[0] if out else ""
    ta_id = line.split("\t", 1)[0] if line else ""
    return 201, {"id": ta_id, "raw": line}


def add_ai_plan(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    title = (payload.get("title") or "").strip()
    if not title:
        return 400, {"error": "title is required"}
    args = [
        sys.executable, str(paths.ta_add),
        "--agenda-file", str(paths.ai_plan_md),
        "--id-prefix", "AP",
        "--title", title,
        "--kind", (payload.get("kind") or "discussion").strip() or "discussion",
        "--opened-by", (payload.get("opened_by") or "Nir").strip() or "Nir",
        "--owner", (payload.get("owner") or "TBD").strip() or "TBD",
        "--summary", (payload.get("summary") or "").strip(),
        "--why-matters", (payload.get("why_matters") or "").strip(),
        "--next-step", (payload.get("next_step") or "").strip(),
        "--notes", (payload.get("notes") or "").strip(),
    ]
    rc, out, err = _run_helper(args)
    if rc != 0:
        return 500, {"error": "add-item failed", "rc": rc, "stderr": err.strip()}
    line = (out or "").splitlines()[0] if out else ""
    ap_id = line.split("\t", 1)[0] if line else ""
    return 201, {"id": ap_id, "raw": line}


def add_one_on_one(paths: Paths, slug: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    if not safe_slug(slug):
        return 400, {"error": f"invalid slug: {slug!r}"}
    title = (payload.get("title") or "").strip()
    if not title:
        return 400, {"error": "title is required"}
    agenda_file = paths.one_on_ones_dir / f"{slug}.md"
    args = [
        sys.executable, str(paths.on_add),
        "--agenda-file", str(agenda_file),
        "--person", _one_on_one_label(slug),
        "--title", title,
        "--kind", (payload.get("kind") or "discussion").strip() or "discussion",
        "--opened-by", (payload.get("opened_by") or "Nir").strip() or "Nir",
        "--owner", (payload.get("owner") or "TBD").strip() or "TBD",
        "--summary", (payload.get("summary") or "").strip(),
        "--why-matters", (payload.get("why_matters") or "").strip(),
        "--next-step", (payload.get("next_step") or "").strip(),
        "--notes", (payload.get("notes") or "").strip(),
    ]
    rc, out, err = _run_helper(args)
    if rc != 0:
        return 500, {"error": "add-item failed", "rc": rc, "stderr": err.strip()}
    line = (out or "").splitlines()[0] if out else ""
    on_id = line.split("\t", 1)[0] if line else ""
    return 201, {"id": on_id, "raw": line}


# --- Mutators ------------------------------------------------------------

VALID_PT_OPS = {"close", "snooze", "reopen"}
VALID_TA_OPS = {"close", "reopen", "edit"}
VALID_AP_OPS = {"close", "reopen", "edit"}
VALID_ON_OPS = {"close", "reopen", "edit"}

# Fields the Board may rewrite via action=edit on TA + ON items. Mirrors
# markdown_io._EDITABLE_FIELDS_ON_TA (kept here for an early validation
# pass that doesn't leak python attribute access errors to the client).
EDIT_FIELDS_ON_TA = {"title", "kind", "opened_by", "owner",
                     "summary", "why_matters", "next_step", "notes"}


def scope_board_snapshot(paths: Paths) -> dict[str, Any]:
    if not paths.scope_board_md.exists():
        return {"tables": [], "path": str(paths.scope_board_md), "exists": False}
    text = paths.scope_board_md.read_text(encoding="utf-8")
    parsed = sbio.parse_scope_board(text)
    parsed["path"] = str(
        paths.scope_board_md.relative_to(paths.root)
        if paths.scope_board_md.is_relative_to(paths.root)
        else paths.scope_board_md
    )
    parsed["exists"] = True
    return parsed


def mutate_scope_board(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    if not paths.scope_board_md.exists():
        return 404, {"error": f"scope board file not found: {paths.scope_board_md}"}
    try:
        t = int(payload.get("table"))
        r = int(payload.get("row"))
        c = int(payload.get("col"))
    except (TypeError, ValueError):
        return 400, {"error": "table, row, col must be integers"}
    value = payload.get("value")
    if not isinstance(value, str):
        return 400, {"error": "value must be a string"}
    text = paths.scope_board_md.read_text(encoding="utf-8")
    try:
        new_text = sbio.mutate_scope_board_cell(text, t, r, c, value)
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.scope_board_md, new_text)
    # Re-render the cell so the client can swap the DOM without a refetch.
    normalised = value.replace("\r\n", " ").replace("\n", " ").replace("\t", " ")
    normalised = re.sub(r"\s+", " ", normalised).strip()
    return 200, {
        "table": t,
        "row": r,
        "col": c,
        "raw": normalised,
        "html": sbio.render_cell_html(normalised),
    }


def sdk_rotation_snapshot(paths: Paths) -> dict[str, Any]:
    if not paths.sdk_rotation_md.exists():
        return {
            "tables": [], "path": str(paths.sdk_rotation_md),
            "exists": False, "order_table_index": None,
        }
    text = paths.sdk_rotation_md.read_text(encoding="utf-8")
    parsed = sdkio.parse_sdk_rotation(text)
    parsed["path"] = str(
        paths.sdk_rotation_md.relative_to(paths.root)
        if paths.sdk_rotation_md.is_relative_to(paths.root)
        else paths.sdk_rotation_md
    )
    parsed["exists"] = True
    return parsed


def mutate_sdk_rotation(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """PATCH /api/sdk-rotation  body={table, row, col, value} - single-cell edit
    against config/sdk-rotation.md."""
    if not paths.sdk_rotation_md.exists():
        return 404, {"error": f"sdk-rotation file not found: {paths.sdk_rotation_md}"}
    try:
        t = int(payload.get("table"))
        r = int(payload.get("row"))
        c = int(payload.get("col"))
    except (TypeError, ValueError):
        return 400, {"error": "table, row, col must be integers"}
    value = payload.get("value")
    if not isinstance(value, str):
        return 400, {"error": "value must be a string"}
    text = paths.sdk_rotation_md.read_text(encoding="utf-8")
    try:
        new_text = sdkio.mutate_sdk_rotation_cell(text, t, r, c, value)
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.sdk_rotation_md, new_text)
    normalised = value.replace("\r\n", " ").replace("\n", " ").replace("\t", " ")
    normalised = re.sub(r"\s+", " ", normalised).strip()
    return 200, {
        "table": t,
        "row": r,
        "col": c,
        "raw": normalised,
        "html": sbio.render_cell_html(normalised),
    }


def reorder_sdk_rotation(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """PATCH /api/sdk-rotation/order  body={order: [int, ...]} - permute
    the rows of the `## Current order` table. Auto-renumbers column 0."""
    if not paths.sdk_rotation_md.exists():
        return 404, {"error": f"sdk-rotation file not found: {paths.sdk_rotation_md}"}
    order = payload.get("order")
    if not isinstance(order, list) or not all(isinstance(x, int) for x in order):
        return 400, {"error": "order must be a list of integers"}
    text = paths.sdk_rotation_md.read_text(encoding="utf-8")
    try:
        new_text = sdkio.reorder_sdk_rotation_rows(text, order)
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.sdk_rotation_md, new_text)
    # Return the fresh snapshot so the client renders 1..N without a refetch.
    snapshot = sdk_rotation_snapshot(paths)
    return 200, {"order": order, "snapshot": snapshot}


def mutate_todo(paths: Paths, todo_id: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    op = (payload.get("action") or "").strip().lower()
    if op not in VALID_PT_OPS:
        return 400, {"error": f"action must be one of {sorted(VALID_PT_OPS)}"}
    if not re.fullmatch(r"PT-\d{3}", todo_id or ""):
        return 400, {"error": f"invalid id: {todo_id!r}"}
    text = paths.todos_md.read_text(encoding="utf-8")
    try:
        new_text = mio.mutate_todo(
            text, todo_id, op,
            snoozed_until=(payload.get("snoozed_until") or None),
        )
    except KeyError:
        return 404, {"error": f"{todo_id} not found"}
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.todos_md, new_text)
    return 200, {"id": todo_id, "op": op}


def mutate_agenda_item(paths: Paths, ta_id: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    op = (payload.get("action") or "").strip().lower()
    if op not in VALID_TA_OPS:
        return 400, {"error": f"action must be one of {sorted(VALID_TA_OPS)}"}
    if not re.fullmatch(r"TA-\d{3}", ta_id or ""):
        return 400, {"error": f"invalid id: {ta_id!r}"}
    text = paths.agenda_md.read_text(encoding="utf-8")
    try:
        if op == "edit":
            fields = payload.get("fields") or {}
            if not isinstance(fields, dict) or not fields:
                return 400, {"error": "fields must be a non-empty object"}
            bad = sorted(set(fields.keys()) - EDIT_FIELDS_ON_TA)
            if bad:
                return 400, {"error": f"unknown field(s): {', '.join(bad)}"}
            new_text = mio.mutate_agenda_edit(text, ta_id, fields)
        else:
            new_text = mio.mutate_agenda(text, ta_id, op)
    except KeyError:
        return 404, {"error": f"{ta_id} not found"}
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.agenda_md, new_text)
    return 200, {"id": ta_id, "op": op}


def mutate_ai_plan_item(paths: Paths, ap_id: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    op = (payload.get("action") or "").strip().lower()
    if op not in VALID_AP_OPS:
        return 400, {"error": f"action must be one of {sorted(VALID_AP_OPS)}"}
    if not re.fullmatch(r"AP-\d{3}", ap_id or ""):
        return 400, {"error": f"invalid id: {ap_id!r}"}
    if not paths.ai_plan_md.exists():
        return 404, {"error": "ai-plan file not found"}
    text = paths.ai_plan_md.read_text(encoding="utf-8")
    try:
        if op == "edit":
            fields = payload.get("fields") or {}
            if not isinstance(fields, dict) or not fields:
                return 400, {"error": "fields must be a non-empty object"}
            bad = sorted(set(fields.keys()) - EDIT_FIELDS_ON_TA)
            if bad:
                return 400, {"error": f"unknown field(s): {', '.join(bad)}"}
            new_text = mio.mutate_ai_plan_edit(text, ap_id, fields)
        else:
            new_text = mio.mutate_ai_plan(text, ap_id, op)
    except KeyError:
        return 404, {"error": f"{ap_id} not found"}
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(paths.ai_plan_md, new_text)
    return 200, {"id": ap_id, "op": op}


def mutate_one_on_one_item(paths: Paths, slug: str, on_id: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    if not safe_slug(slug):
        return 400, {"error": f"invalid slug: {slug!r}"}
    op = (payload.get("action") or "").strip().lower()
    if op not in VALID_ON_OPS:
        return 400, {"error": f"action must be one of {sorted(VALID_ON_OPS)}"}
    if not re.fullmatch(r"ON-\d{3}", on_id or ""):
        return 400, {"error": f"invalid id: {on_id!r}"}
    md_path = paths.one_on_ones_dir / f"{slug}.md"
    if not md_path.exists():
        return 404, {"error": f"{slug}.md not found"}
    text = md_path.read_text(encoding="utf-8")
    try:
        if op == "edit":
            fields = payload.get("fields") or {}
            if not isinstance(fields, dict) or not fields:
                return 400, {"error": "fields must be a non-empty object"}
            bad = sorted(set(fields.keys()) - EDIT_FIELDS_ON_TA)
            if bad:
                return 400, {"error": f"unknown field(s): {', '.join(bad)}"}
            new_text = mio.mutate_one_on_one_edit(text, on_id, fields)
        else:
            new_text = mio.mutate_one_on_one(text, on_id, op)
    except KeyError:
        return 404, {"error": f"{on_id} not found"}
    except ValueError as ex:
        return 400, {"error": str(ex)}
    mio.atomic_write(md_path, new_text)
    return 200, {"slug": slug, "id": on_id, "op": op}


def mutate_personal_notes(paths: Paths, slug: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """PATCH /api/one-on-ones/<slug>/personal-notes  body={text:str}
    Rewrites the `## Personal notes` section of the partner's 1:1
    markdown. Empty text clears the section (still keeps the heading).
    """
    if not safe_slug(slug):
        return 400, {"error": f"invalid slug: {slug!r}"}
    new_notes = payload.get("text")
    if new_notes is None:
        return 400, {"error": "text is required"}
    if not isinstance(new_notes, str):
        return 400, {"error": "text must be a string"}
    if len(new_notes) > 8000:
        return 400, {"error": "text too long (max 8000 chars)"}
    md_path = paths.one_on_ones_dir / f"{slug}.md"
    if not md_path.exists():
        return 404, {"error": f"{slug}.md not found"}
    text = md_path.read_text(encoding="utf-8")
    new_text = mio.set_personal_notes(text, new_notes)
    mio.atomic_write(md_path, new_text)
    return 200, {"slug": slug, "personal_notes": mio.parse_personal_notes(new_text)}


def send_one_on_one_summary(paths: Paths, slug: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """POST /api/one-on-ones/<slug>/summary  body={notes?:str, dry_run?:bool}
    Spawns the one-on-one-prep runner in summary mode for that single
    direct. Returns immediately - the runner writes to reports/logs/.
    """
    if not safe_slug(slug):
        return 400, {"error": f"invalid slug: {slug!r}"}
    notes = payload.get("notes") or ""
    if not isinstance(notes, str):
        return 400, {"error": "notes must be a string"}
    if len(notes) > 8000:
        return 400, {"error": "notes too long (max 8000 chars)"}
    dry_run = bool(payload.get("dry_run", False))
    runner = paths.root / ".copilot" / "skills" / "run-one-on-one-prep.ps1"
    if not runner.exists():
        return 500, {"error": f"runner missing: {runner}"}
    # Write notes to a temp file (avoids the cmd-line quoting quirks per
    # the powershell external-arg quoting memory).
    notes_tmp = paths.root / "reports" / "one-on-one-prep" / "tmp"
    notes_tmp.mkdir(parents=True, exist_ok=True)
    stamp = int(__import__('time').time())
    notes_file = notes_tmp / f"summary-{slug}-{stamp}.txt"
    notes_file.write_text(notes, encoding="utf-8")
    args = [
        "pwsh", "-NoProfile", "-File", str(runner),
        "-SummaryMode",
        "-OnlySlug", slug,
        "-SummaryNotesFile", str(notes_file),
    ]
    no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)

    # ---- Dry run: run SYNCHRONOUSLY and return the rendered preview HTML ----
    # A "preview only" button is useless if the preview lands in a log file the
    # user never sees (the original "Dry run does nothing" complaint). The
    # runner already supports -PreviewOut <file>; we wait for it, read the HTML
    # back, and hand it to the browser so the card can render the actual email.
    if dry_run:
        preview_file = notes_tmp / f"preview-{slug}-{stamp}.html"
        run_args = args + ["-PreviewOut", str(preview_file), "-DryRun"]
        sys.stderr.write(f"[board] dry-run preview slug={slug} notes_bytes={len(notes)}\n")
        sys.stderr.flush()
        try:
            proc = subprocess.run(run_args, cwd=str(paths.root),
                                  capture_output=True, text=True,
                                  timeout=150, creationflags=no_window)
        except subprocess.TimeoutExpired:
            return 504, {"error": "preview runner timed out (150s)", "slug": slug}
        except OSError as ex:
            return 500, {"error": f"failed to run preview runner: {ex}"}
        html = ""
        if preview_file.exists():
            try:
                html = preview_file.read_text(encoding="utf-8")
            except OSError:
                html = ""
        if html:
            return 200, {"slug": slug, "dry_run": True, "preview_html": html}
        # No preview produced - surface a hint from the runner output so the
        # UI can show WHY (e.g. an smtp/skip reason) instead of silence.
        tail = ((proc.stderr or "") + (proc.stdout or "")).strip()[-1200:]
        return 200, {
            "slug": slug, "dry_run": True, "preview_html": "",
            "warning": "No preview was produced - the runner skipped or errored. "
                       "Check reports/logs/one-on-one-prep-*.log.",
            "detail": tail,
        }

    # ---- Real send: fire-and-forget so the email goes out asynchronously ----
    # Compose creation flags so the child detaches from the board server's
    # process group AND any job object - otherwise a Ctrl-C or Stop-Process
    # on the board (e.g. during a deploy/restart) can take a freshly-spawned
    # runner down with it before it ever writes its log file.
    #
    # IMPORTANT: use CREATE_NO_WINDOW, NOT DETACHED_PROCESS. DETACHED_PROCESS
    # gives the child NO console at all, and pwsh -File then dies on startup
    # before it can open its log file (verified 2026-06-04: every spawn with
    # DETACHED_PROCESS produced a pid but zero log output, which is exactly
    # the "Dry run does nothing" symptom). CREATE_NO_WINDOW gives the child
    # its own hidden console so pwsh runs normally while staying invisible.
    detached_flags = (
        no_window |
        getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200) |
        getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000)
    )
    sys.stderr.write(
        f"[board] spawn one-on-one-prep summary slug={slug} dry_run={dry_run} "
        f"notes_bytes={len(notes)} pid_about_to_launch=1\n"
    )
    sys.stderr.flush()
    try:
        # Fire and forget - the runner emits to a log file.
        proc = subprocess.Popen(args, cwd=str(paths.root),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=detached_flags)
        sys.stderr.write(f"[board] spawned one-on-one-prep summary pid={proc.pid} slug={slug}\n")
        sys.stderr.flush()
    except OSError as ex:
        return 500, {"error": f"failed to spawn runner: {ex}"}
    return 202, {"slug": slug, "dry_run": dry_run, "notes_file": str(notes_file)}


# --- ADO item tracker ----------------------------------------------------

def ado_tracker_snapshot(paths: Paths) -> dict[str, Any]:
    """Merge the committed tracked set (ids + notes) with the gitignored live
    cache (title/owner/status/url, refreshed by run-ado-item-tracker.ps1) so the
    Board can render the ADO Tracker tab without holding an ADO token itself."""
    tracked: list[dict[str, Any]] = []
    exists = paths.ado_tracker_tracked.exists()
    if exists:
        try:
            data = json.loads(paths.ado_tracker_tracked.read_text(encoding="utf-8"))
            tracked = list(data.get("items") or [])
        except (OSError, ValueError):
            tracked = []

    cache: dict[str, Any] = {}
    generated_at = ""
    if paths.ado_tracker_cache.exists():
        try:
            c = json.loads(paths.ado_tracker_cache.read_text(encoding="utf-8"))
            cache = c.get("items") or {}
            generated_at = c.get("generatedAt", "")
        except (OSError, ValueError):
            cache = {}

    items: list[dict[str, Any]] = []
    for t in tracked:
        wid = t.get("id")
        c = cache.get(str(wid)) or {}
        owner_email = str(c.get("ownerEmail") or "")
        items.append({
            "id": wid,
            "note": str(t.get("note") or ""),
            "added_at": str(t.get("addedAt") or ""),
            "title": str(c.get("title") or ""),
            "type": str(c.get("type") or ""),
            "state": str(c.get("state") or ""),
            "owner": str(c.get("owner") or ""),
            "owner_email": owner_email,
            "url": str(c.get("url") or f"https://your-ado-org.visualstudio.com/One/_workitems/edit/{wid}"),
            "changed_date": str(c.get("changedDate") or ""),
            "can_ping": bool(owner_email and owner_email.lower().endswith("@microsoft.com")),
            "synced": bool(c),
        })

    return {
        "items": items,
        "path": "reports/ado-tracker/tracked.json",
        "exists": exists,
        "generated_at": generated_at,
        "count": len(items),
    }


# --- Scheduled tasks -----------------------------------------------------

# PowerShell that enumerates every DM-* Windows Scheduled Task and emits one
# JSON object per task with a human-readable schedule string. Mirrors the
# enumeration the nirvana-site build.py does, but formats a friendlier
# `schedule` field instead of raw CIM class names.
_SCHED_PS = r"""
$ErrorActionPreference = 'SilentlyContinue'
function Fmt-Interval($iso) {
  if (-not $iso) { return '' }
  if ($iso -match '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$') {
    $parts = @()
    if ($Matches[1]) { $parts += "$($Matches[1])d" }
    if ($Matches[2]) { $parts += "$($Matches[2])h" }
    if ($Matches[3]) { $parts += "$($Matches[3])m" }
    if ($Matches[4]) { $parts += "$($Matches[4])s" }
    if ($parts.Count) { return ($parts -join '') }
  }
  return $iso
}
$dow = @{ 1='Sun'; 2='Mon'; 4='Tue'; 8='Wed'; 16='Thu'; 32='Fri'; 64='Sat' }
$out = Get-ScheduledTask -TaskName 'DM-*' | ForEach-Object {
  $t = $_
  $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
  $sched = @()
  foreach ($tr in $t.Triggers) {
    $kind = ''
    if ($tr.CimClass) { $kind = $tr.CimClass.CimClassName }
    $time = ''
    if ($tr.StartBoundary) { try { $time = ([datetime]$tr.StartBoundary).ToString('HH:mm') } catch {} }
    $d = ''
    switch -Wildcard ($kind) {
      '*DailyTrigger'  { $d = 'Daily'; if ($time) { $d += " @ $time" } }
      '*WeeklyTrigger' {
        $names = @()
        foreach ($k in ($dow.Keys | Sort-Object)) { if ([int]$tr.DaysOfWeek -band $k) { $names += $dow[$k] } }
        if ($names.Count) { $d = ($names -join ',') } else { $d = 'Weekly' }
        if ($tr.WeeksInterval -and [int]$tr.WeeksInterval -gt 1) { $d += " /$($tr.WeeksInterval)wk" }
        if ($time) { $d += " @ $time" }
      }
      '*TimeTrigger'         { $d = 'Once'; if ($time) { $d += " @ $time" } }
      '*LogonTrigger'        { $d = 'At logon' }
      '*BootTrigger'         { $d = 'At startup' }
      '*RegistrationTrigger' { $d = 'On registration' }
      '*EventTrigger'        { $d = 'On event' }
      default { if ($kind) { $d = ($kind -replace '^MSFT_Task', '' -replace 'Trigger$', '') } else { $d = 'trigger' } }
    }
    if ($tr.Repetition -and $tr.Repetition.Interval) {
      $iv = Fmt-Interval $tr.Repetition.Interval
      if ($iv) { $d += " - every $iv" }
    }
    $sched += $d
  }
  $nr = ''
  if ($info.NextRunTime -and $info.NextRunTime.Year -ge 2000) { $nr = $info.NextRunTime.ToString('o') }
  $lr = ''
  if ($info.LastRunTime -and $info.LastRunTime.Year -ge 2000) { $lr = $info.LastRunTime.ToString('o') }
  [PSCustomObject]@{
    name        = "$($t.TaskName)"
    state       = "$($t.State)"
    description = "$($t.Description)"
    schedule    = ($sched -join ' | ')
    next_run    = $nr
    last_run    = $lr
    last_result = [int64]$info.LastTaskResult
  }
}
$out | ConvertTo-Json -Depth 4
"""


def _run_scheduled_tasks_ps() -> tuple[list[dict[str, Any]], str | None]:
    """Enumerate DM-* Windows Scheduled Tasks. Returns (tasks, error)."""
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", _SCHED_PS],
            capture_output=True, text=True, timeout=45,
        )
    except (OSError, subprocess.SubprocessError) as ex:
        return [], f"failed to run PowerShell: {ex}"
    if r.returncode != 0:
        msg = (r.stderr or "").strip() or f"powershell exited {r.returncode}"
        return [], msg[:500]
    out = (r.stdout or "").strip()
    if not out or out == "null":
        return [], None
    try:
        data = json.loads(out)
    except ValueError as ex:
        return [], f"could not parse task JSON: {ex}"
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        return [], None
    data.sort(key=lambda x: str(x.get("name", "")))
    return data, None


def _first_sentence(text: str) -> str:
    """Collapse to a single line and keep just the first sentence. No ellipsis
    and no hard cap: the Board wraps this to ~2 lines and keeps the full text
    in a hover tooltip, so nothing is lost."""
    s = " ".join((text or "").split())
    if not s:
        return ""
    m = re.search(r"\.\s", s)
    if m:
        s = s[: m.start() + 1]
    return s


def _scheduled_task_meta(paths: Paths) -> dict[str, dict[str, str]]:
    """Map each DM-* task name -> {skill, summary, note} by joining
    config/schedules.json (task suffix -> skill) with config/skills.json
    (skill -> one-line summary). Powers the Board's "What it does" column."""
    meta: dict[str, dict[str, str]] = {}
    try:
        prefix = "DM"
        agent_json = paths.root / "config" / "agent.json"
        if agent_json.exists():
            a = json.loads(agent_json.read_text(encoding="utf-8"))
            prefix = str((a.get("tasks") or {}).get("prefix") or "DM")

        summaries: dict[str, str] = {}
        skills_json = paths.root / "config" / "skills.json"
        if skills_json.exists():
            sj = json.loads(skills_json.read_text(encoding="utf-8"))
            for s in (sj.get("skills") or []):
                if s.get("name"):
                    summaries[str(s["name"])] = str(s.get("summary") or "")

        sched_json = paths.root / "config" / "schedules.json"
        if sched_json.exists():
            cj = json.loads(sched_json.read_text(encoding="utf-8"))
            for t in (cj.get("tasks") or []):
                suffix = str(t.get("suffix") or "")
                if not suffix:
                    continue
                skill = str(t.get("skill") or "")
                meta[f"{prefix}-{suffix}"] = {
                    "skill": skill,
                    "summary": summaries.get(skill, ""),
                    "note": str(t.get("note") or ""),
                }
    except (OSError, ValueError):
        return meta
    return meta


def _explain_task(task: dict[str, Any], info: dict[str, str]) -> str:
    """One-line explanation of what a scheduled task does. Prefers the task's
    own Task Scheduler description, then the skill summary, then a config note,
    then a plain 'runs the <skill> skill' fallback."""
    desc = str(task.get("description") or "").strip()
    if desc:
        return _first_sentence(desc)
    if info.get("summary"):
        return _first_sentence(info["summary"])
    if info.get("note"):
        return _first_sentence(info["note"])
    if info.get("skill"):
        return f"Runs the {info['skill']} skill."
    return ""


def scheduled_tasks_snapshot(paths: Paths, force: bool = False) -> dict[str, Any]:
    """DM-* scheduled tasks for the Board's Scheduled tasks tab. Cached for
    _SCHED_TTL seconds; pass force=True (or GET ?refresh=1) to re-enumerate."""
    now = time.time()
    with _SCHED_LOCK:
        cached = _SCHED_CACHE.get("data")
        if cached is not None and not force and (now - _SCHED_CACHE.get("ts", 0.0)) < _SCHED_TTL:
            return cached

    generated_at = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    if sys.platform != "win32":
        result: dict[str, Any] = {
            "tasks": [], "count": 0, "available": False,
            "generated_at": generated_at,
            "note": "Scheduled-task enumeration is only available on Windows.",
        }
    else:
        tasks, error = _run_scheduled_tasks_ps()
        meta = _scheduled_task_meta(paths)
        for t in tasks:
            info = meta.get(str(t.get("name") or ""), {})
            t["explanation"] = _explain_task(t, info)
            if info.get("skill"):
                t["skill"] = info["skill"]
        result = {
            "tasks": tasks,
            "count": len(tasks),
            "available": error is None,
            "generated_at": generated_at,
        }
        if error:
            result["error"] = error

    with _SCHED_LOCK:
        _SCHED_CACHE["data"] = result
        _SCHED_CACHE["ts"] = now
    return result


# --- My Day --------------------------------------------------------------
#
# The My Day tab is the Board's landing view: a summary of today's meetings
# (read live from Outlook via COM), plus two synthesized lists derived from the
# same markdown stores the rest of the Board already reads - "needs attention"
# (overdue/due-today todos, snoozed-past items, 1:1 prep for people Nir is
# meeting today, recently-changed tracked ADO items, reminders firing today)
# and "focus today" (a short, ranked shortlist of what to actually do).
#
# All of the ranking logic lives in compute_my_day() so it is a pure function
# of (board snapshot, meetings, reminders, today) and unit-testable without
# Outlook. Only the calendar read touches COM and it degrades gracefully to an
# empty meeting list off-Windows or when Outlook is unavailable.

# PowerShell that reads *today's* Outlook calendar and emits one JSON object per
# appointment. Mirrors the proven Restrict()/olFolderCalendar pattern used by
# run-reminders.ps1's Resolve-MeetingStart. Date-only DASL boundaries avoid the
# HH/tt ambiguity; recurrences are expanded so daily/weekly series show up.
_CALENDAR_PS = r"""
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
try {
  $app = New-Object -ComObject Outlook.Application
  $ns  = $app.GetNamespace('MAPI')
  $cal = $ns.GetDefaultFolder(9)  # olFolderCalendar
  $start = (Get-Date).Date
  $end   = $start.AddDays(1)
  $items = $cal.Items
  $items.IncludeRecurrences = $true
  $items.Sort('[Start]')
  $fmt = "'{0:MM/dd/yyyy}'"
  $r = ('[Start] < {0} AND [End] > {1}' -f ($fmt -f $end), ($fmt -f $start))
  $restricted = $items.Restrict($r)
  $out = @()
  foreach ($it in $restricted) {
    try {
      $subj = if ($it.Subject) { [string]$it.Subject } else { '(no subject)' }
      $s = [datetime]$it.Start
      $e = [datetime]$it.End
      # Skip anything that doesn't actually intersect today (defensive - the
      # DASL filter is inclusive at the edges for all-day/recurring items).
      if ($e -le $start -or $s -ge $end) { continue }
      $loc = ''
      try { if ($it.Location) { $loc = [string]$it.Location } } catch {}
      $org = ''
      try { if ($it.Organizer) { $org = [string]$it.Organizer } } catch {}
      $allDay = $false
      try { $allDay = [bool]$it.AllDayEvent } catch {}
      $resp = 0
      try { $resp = [int]$it.ResponseStatus } catch {}
      $busy = 2
      try { $busy = [int]$it.BusyStatus } catch {}
      $recur = $false
      try { $recur = [bool]$it.IsRecurring } catch {}
      $online = $false
      try {
        $hay = ($loc + ' ')
        try { if ($it.Body) { $hay += [string]$it.Body } } catch {}
        if ($hay -match 'teams\.microsoft\.com' -or $hay -match 'Microsoft Teams Meeting' -or $hay -match 'zoom\.us') { $online = $true }
      } catch {}
      $out += [PSCustomObject]@{
        subject   = $subj
        start     = $s.ToString('o')
        end       = $e.ToString('o')
        location  = $loc
        organizer = $org
        allDay    = $allDay
        response  = $resp
        busy      = $busy
        recurring = $recur
        online    = $online
      }
    } catch { continue }
  }
  $out = $out | Sort-Object { [datetime]$_.start }
  ConvertTo-Json -InputObject @($out) -Depth 4
} catch {
  Write-Error $_.Exception.Message
  exit 3
}
"""

# Outlook ResponseStatus / BusyStatus enum -> friendly label.
_RESP_LABEL = {0: "", 1: "Organizer", 2: "Tentative", 3: "Accepted", 4: "Declined", 5: "Not responded"}
_BUSY_LABEL = {0: "Free", 1: "Tentative", 2: "Busy", 3: "Out of office", 4: "Working elsewhere"}


def _run_calendar_ps() -> tuple[list[dict[str, Any]], str | None]:
    """Read today's Outlook calendar. Returns (meetings, error). Off-Windows or
    when Outlook/COM is unavailable, returns ([], <reason>)."""
    if sys.platform != "win32":
        return [], "Calendar is only available on Windows (Outlook COM)."
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", _CALENDAR_PS],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45,
        )
    except (OSError, subprocess.SubprocessError) as ex:
        return [], f"failed to run PowerShell: {ex}"
    if r.returncode != 0:
        msg = (r.stderr or "").strip() or f"powershell exited {r.returncode}"
        return [], msg[:500]
    out = (r.stdout or "").strip()
    if not out or out == "null":
        return [], None
    try:
        data = json.loads(out)
    except ValueError as ex:
        return [], f"could not parse calendar JSON: {ex}"
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        return [], None
    return data, None


def _get_meetings_cached(force: bool = False) -> tuple[list[dict[str, Any]], bool, str | None]:
    """Return (meetings, available, error). The raw Outlook read is cached for
    _CAL_TTL seconds (and invalidated when the day rolls over)."""
    now = time.time()
    today = date.today().isoformat()
    with _CAL_LOCK:
        fresh = (
            _CAL_CACHE.get("data") is not None
            and _CAL_CACHE.get("date") == today
            and not force
            and (now - _CAL_CACHE.get("ts", 0.0)) < _CAL_TTL
        )
        if fresh:
            return _CAL_CACHE["data"], _CAL_CACHE.get("available", True), _CAL_CACHE.get("error")

    meetings, error = _run_calendar_ps()
    available = error is None
    with _CAL_LOCK:
        _CAL_CACHE["data"] = meetings
        _CAL_CACHE["date"] = today
        _CAL_CACHE["ts"] = now
        _CAL_CACHE["available"] = available
        _CAL_CACHE["error"] = error
    return meetings, available, error


_DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")


def _parse_ymd(s: str) -> date | None:
    """Lenient YYYY-MM-DD extraction. Returns None for '-', '', or free text
    like 'tomorrow' (those simply don't participate in overdue/due-today math)."""
    if not s:
        return None
    m = _DATE_RE.search(str(s))
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y-%m-%d").date()
    except ValueError:
        return None


def _read_reminders_today(paths: Paths, today: date) -> list[dict[str, Any]]:
    """Best-effort scan of reports/reminders/reminders.md for *pending*
    reminders whose fire day is today (absolute 'Fire at' date == today, or a
    meeting-bound reminder whose 'Meeting date' == today). Exact meeting times
    need Outlook so we only surface the day match as a heads-up."""
    md = paths.root / "reports" / "reminders" / "reminders.md"
    if not md.exists():
        return []
    try:
        text = md.read_text(encoding="utf-8")
    except OSError:
        return []
    out: list[dict[str, Any]] = []
    cur: dict[str, Any] | None = None
    for ln in text.splitlines():
        h = re.match(r"^###\s+(RM-\d{3})\s*-\s*(.+?)\s*$", ln)
        if h:
            if cur:
                out.append(cur)
            cur = {"id": h.group(1), "title": h.group(2), "fields": {}}
            continue
        if re.match(r"^##\s+", ln) and cur:
            out.append(cur)
            cur = None
            continue
        if cur:
            f = re.match(r"^\s*-\s+\*\*([^*]+):\*\*\s*(.*?)\s*$", ln)
            if f:
                cur["fields"][f.group(1).strip().lower()] = f.group(2).strip()
    if cur:
        out.append(cur)

    today_iso = today.isoformat()
    hits: list[dict[str, Any]] = []
    for r in out:
        fields = r["fields"]
        if (fields.get("status") or "").lower() != "pending":
            continue
        kind = (fields.get("kind") or "").lower()
        when_label = ""
        matched = False
        if kind == "absolute":
            d = _parse_ymd(fields.get("fire at", ""))
            if d == today:
                matched = True
                when_label = fields.get("fire at", "")
        elif kind == "meeting":
            d = _parse_ymd(fields.get("meeting date", ""))
            if d == today:
                matched = True
                subj = fields.get("meeting subject match", "")
                off = fields.get("offset min", "")
                when_label = f"~ meeting '{subj}' {off}min" if subj else "today"
        if matched:
            hits.append({"id": r["id"], "title": r["title"], "when": when_label, "kind": kind})
    return hits


def _first_name(label: str) -> str:
    return (label or "").strip().split(" ")[0] if label else ""


def _match_meetings_to_partners(meetings: list[dict[str, Any]], one_on_ones: list[dict[str, Any]]) -> None:
    """Annotate each meeting in-place with is_one_on_one / partner_slug /
    partner_label / partner_open when its subject clearly names a 1:1 partner."""
    partners = [p for p in one_on_ones if (p.get("label") or "").strip()]
    for m in meetings:
        subj = (m.get("subject") or "").lower()
        m["is_one_on_one"] = False
        m["partner_slug"] = ""
        m["partner_label"] = ""
        m["partner_open"] = 0
        if not subj:
            continue
        one_on_one_marker = any(tok in subj for tok in ("1:1", "1x1", "1-1", "one on one", "one-on-one"))
        best = None
        for p in partners:
            label = (p.get("label") or "").strip()
            first = _first_name(label).lower()
            if not first:
                continue
            full_hit = label.lower() in subj
            word_hit = re.search(r"\b" + re.escape(first) + r"\b", subj) is not None
            if full_hit or (word_hit and one_on_one_marker):
                best = p
                if full_hit:
                    break
        if best is not None:
            m["is_one_on_one"] = True
            m["partner_slug"] = best.get("slug", "")
            m["partner_label"] = best.get("label", "")
            m["partner_open"] = int(best.get("open_count") or 0)


def _fmt_time_range(start_iso: str, end_iso: str) -> str:
    def hm(iso: str) -> str:
        try:
            return datetime.fromisoformat(iso).strftime("%H:%M")
        except (ValueError, TypeError):
            return ""
    a, b = hm(start_iso), hm(end_iso)
    if a and b:
        return f"{a}\u2013{b}"
    return a or b or ""


def compute_my_day(
    board: dict[str, Any],
    meetings: list[dict[str, Any]],
    reminders: list[dict[str, Any]],
    today: date,
) -> dict[str, Any]:
    """Pure ranking function. Turns the board snapshot + today's meetings +
    today's reminders into meetings (decorated), a needs_attention list, a focus
    list, and a small stats block. Deterministic and Outlook-free."""
    todos = board.get("todos") or []
    one_on_ones = board.get("one_on_ones") or []
    ado_items = (board.get("ado_tracker") or {}).get("items") or []

    # --- Decorate + filter meetings ---
    for m in meetings:
        m["response_label"] = _RESP_LABEL.get(int(m.get("response") or 0), "")
        m["busy_label"] = _BUSY_LABEL.get(int(m.get("busy") or 2), "")
        m["time_label"] = "All day" if m.get("allDay") else _fmt_time_range(m.get("start", ""), m.get("end", ""))
    # Drop meetings Nir declined - he's not attending those.
    meetings = [m for m in meetings if int(m.get("response") or 0) != 4]
    _match_meetings_to_partners(meetings, one_on_ones)

    timed = [m for m in meetings if not m.get("allDay")]
    first_meeting = timed[0]["time_label"] if timed else ""

    # --- Todo buckets ---
    def is_active(t: dict[str, Any]) -> bool:
        return t.get("status") in ("open", "snoozed")

    overdue: list[dict[str, Any]] = []
    due_today: list[dict[str, Any]] = []
    snoozed_past: list[dict[str, Any]] = []
    high_pri: list[dict[str, Any]] = []
    for t in todos:
        if not is_active(t):
            continue
        due = _parse_ymd(t.get("due", ""))
        snz = _parse_ymd(t.get("snoozed_until", "")) if t.get("status") == "snoozed" else None
        if due and due < today:
            overdue.append(t)
        elif due and due == today:
            due_today.append(t)
        elif snz and snz <= today:
            snoozed_past.append(t)
        elif (t.get("priority") or "").upper() == "H":
            high_pri.append(t)

    def _due_key(t: dict[str, Any]) -> str:
        d = _parse_ymd(t.get("due", ""))
        return d.isoformat() if d else "9999-99-99"

    overdue.sort(key=_due_key)

    # --- Needs attention ---------------------------------------------------
    needs: list[dict[str, Any]] = []
    for t in overdue:
        needs.append({
            "text": f"{t['id']} overdue (due {t.get('due')}): {t.get('title')}",
            "tag": "Overdue", "tone": "danger", "tab": "todos", "ref": t["id"],
        })
    for t in due_today:
        needs.append({
            "text": f"{t['id']} due today: {t.get('title')}",
            "tag": "Due today", "tone": "warning", "tab": "todos", "ref": t["id"],
        })
    for t in snoozed_past:
        needs.append({
            "text": f"{t['id']} snooze elapsed ({t.get('snoozed_until')}): {t.get('title')}",
            "tag": "Snoozed", "tone": "warning", "tab": "todos", "ref": t["id"],
        })
    # 1:1 prep for people Nir is meeting today.
    seen_partner_prep: set[str] = set()
    for m in timed:
        if m.get("is_one_on_one") and m.get("partner_open") and m["partner_slug"] not in seen_partner_prep:
            seen_partner_prep.add(m["partner_slug"])
            n = m["partner_open"]
            needs.append({
                "text": f"1:1 with {m['partner_label']} today \u2014 {n} open item{'s' if n != 1 else ''} to raise",
                "tag": "1:1 prep", "tone": "accent", "tab": "one-on-ones", "ref": m["partner_slug"],
            })
    # Recently-changed tracked ADO items (within 2 days).
    for it in ado_items:
        cd = _parse_ymd(it.get("changed_date", ""))
        if cd and (today - cd).days <= 2:
            title = it.get("title") or f"Work item {it.get('id')}"
            state = it.get("state") or ""
            suffix = f" [{state}]" if state else ""
            needs.append({
                "text": f"ADO {it.get('id')} changed {it.get('changed_date')}: {title}{suffix}",
                "tag": "ADO", "tone": "neutral", "tab": "ado-tracker", "ref": str(it.get("id")),
            })
    # Reminders firing today.
    for r in reminders:
        when = f" ({r['when']})" if r.get("when") else ""
        needs.append({
            "text": f"Reminder {r['id']}: {r['title']}{when}",
            "tag": "Reminder", "tone": "accent", "tab": None, "ref": r["id"],
        })

    # --- Focus today -------------------------------------------------------
    # Ranked shortlist: overdue -> due-today -> 1:1 prep -> high priority.
    focus: list[dict[str, Any]] = []
    focus_ids: set[str] = set()

    def _add_focus(key: str, text: str, tag: str, tone: str, tab: str | None, ref: str) -> None:
        if key in focus_ids:
            return
        focus_ids.add(key)
        focus.append({"text": text, "tag": tag, "tone": tone, "tab": tab, "ref": ref})

    for t in overdue:
        _add_focus(t["id"], f"{t.get('title')} ({t['id']}, overdue)", "Overdue", "danger", "todos", t["id"])
    for t in due_today:
        _add_focus(t["id"], f"{t.get('title')} ({t['id']}, due today)", "Due today", "warning", "todos", t["id"])
    for m in timed:
        if m.get("is_one_on_one") and m.get("partner_open"):
            key = f"prep:{m['partner_slug']}"
            _add_focus(key, f"Prep 1:1 with {m['partner_label']} ({m['partner_open']} open)",
                       "1:1 prep", "accent", "one-on-ones", m["partner_slug"])
    for t in high_pri:
        _add_focus(t["id"], f"{t.get('title')} ({t['id']}, high priority)", "High", "neutral", "todos", t["id"])
    focus = focus[:6]

    stats = {
        "meetings": len(meetings),
        "meetings_timed": len(timed),
        "first_meeting": first_meeting,
        "overdue": len(overdue),
        "due_today": len(due_today),
        "snoozed_past": len(snoozed_past),
        "needs_attention": len(needs),
        "focus": len(focus),
        "reminders": len(reminders),
    }
    return {"meetings": meetings, "needs_attention": needs, "focus": focus, "stats": stats}


def my_day_snapshot(paths: Paths, force: bool = False) -> dict[str, Any]:
    """Assemble the /api/my-day payload: today's (cached) meetings + freshly
    recomputed needs-attention / focus from the current board snapshot."""
    today = date.today()
    meetings, cal_available, cal_error = _get_meetings_cached(force=force)
    try:
        board = board_snapshot(paths)
    except Exception as ex:  # pragma: no cover - defensive
        board = {"todos": [], "one_on_ones": [], "ado_tracker": {"items": []}, "error": str(ex)}
    reminders = _read_reminders_today(paths, today)
    computed = compute_my_day(board, list(meetings), reminders, today)

    generated_at = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    result: dict[str, Any] = {
        "today": today.isoformat(),
        "weekday": today.strftime("%A"),
        "meetings": computed["meetings"],
        "needs_attention": computed["needs_attention"],
        "focus": computed["focus"],
        "reminders": reminders,
        "stats": computed["stats"],
        "calendar_available": cal_available,
        "generated_at": generated_at,
    }
    if cal_error:
        result["calendar_error"] = cal_error
    return result


def ping_ado_owner(paths: Paths, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    """POST /api/ado-tracker/ping  body={id:int}
    Fire-and-forget spawn of run-ado-item-tracker.ps1 -Mode ping -Id <id>, which
    emails the work item's owner (on Nir's behalf). Returns immediately; the
    runner logs to reports/logs/ and refuses unassigned / external owners."""
    wid = payload.get("id")
    try:
        wid_int = int(wid)
    except (TypeError, ValueError):
        return 400, {"error": "id must be an integer"}
    if wid_int <= 0:
        return 400, {"error": "id must be a positive integer"}
    runner = paths.ado_tracker_runner
    if not runner.exists():
        return 500, {"error": f"runner missing: {runner}"}
    args = ["pwsh", "-NoProfile", "-File", str(runner), "-Mode", "ping", "-Id", str(wid_int)]
    no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    detached_flags = (
        no_window |
        getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200) |
        getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000)
    )
    sys.stderr.write(f"[board] spawn ado-tracker ping id={wid_int}\n")
    sys.stderr.flush()
    try:
        proc = subprocess.Popen(args, cwd=str(paths.root),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                creationflags=detached_flags)
        sys.stderr.write(f"[board] spawned ado-tracker ping pid={proc.pid} id={wid_int}\n")
        sys.stderr.flush()
    except OSError as ex:
        return 500, {"error": f"failed to spawn ping runner: {ex}"}
    return 202, {"id": wid_int, "spawned": True}


# --- HTTP handler --------------------------------------------------------

class BoardHandler(BaseHTTPRequestHandler):
    paths: Paths  # set on the class by main()

    server_version = f"nirvana-board/{VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[board] {self.address_string()} - {fmt % args}\n")

    # ---- helpers ----
    def _write_json(self, status: int, body: dict[str, Any]) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _write_static(self, path: Path) -> None:
        if not path.is_file():
            self.send_error(404, "Not Found")
            return
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
            ".ico": "image/x-icon",
            ".json": "application/json; charset=utf-8",
        }.get(path.suffix.lower(), "application/octet-stream")
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict[str, Any] | None:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        try:
            raw = self.rfile.read(length).decode("utf-8")
            if not raw.strip():
                return {}
            return json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            return None

    def _write_explorer(self) -> None:
        """Serve the latest nirvana-site Explorer artifact, or a friendly
        503 page that tells Nir how to rebuild it."""
        artifact = EXPLORER_ARTIFACT
        if artifact.is_file():
            data = artifact.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            # Don't long-cache - the explorer is rebuilt nightly and we want
            # any rebuild to surface on the next page-load.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        msg = (
            "<!doctype html><html><head><meta charset='utf-8'>"
            "<title>Explorer not built yet</title>"
            "<style>body{font:14px/1.5 'Segoe UI',Aptos,system-ui;"
            "max-width:640px;margin:4rem auto;padding:0 1.5rem;color:#1a1f24}"
            "code{background:#f4f1ec;padding:0.1em 0.35em;border-radius:4px}"
            "a{color:#b11f4b}</style></head><body>"
            "<h1>Explorer not built yet</h1>"
            "<p>The Nirvana Board is serving <code>reports/site/nirvana.html</code> "
            "but that file doesn't exist yet. Rebuild it with the "
            "<code>nirvana-site</code> skill:</p>"
            "<pre>python .\\.copilot\\skills\\nirvana-site\\build.py</pre>"
            "<p>or just tell Nirvana <em>&ldquo;rebuild the nirvana site&rdquo;</em>. "
            "Then refresh this page.</p>"
            "<p><a href='/'>&larr; back to the Board</a></p>"
            "</body></html>"
        ).encode("utf-8")
        self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(msg)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(msg)

    # ---- routing ----
    def _route(self, method: str, path: str) -> None:
        # Strip query string defensively.
        p = urlparse(path).path
        if method == "GET":
            if p in ("/", "/index.html"):
                self._write_static(STATIC_DIR / "index.html")
                return
            if p == "/api/health":
                self._write_json(200, {"ok": True, "version": VERSION})
                return
            if p == "/api/board":
                self._write_json(200, board_snapshot(self.paths))
                return
            if p == "/api/scope-board":
                self._write_json(200, scope_board_snapshot(self.paths))
                return
            if p == "/api/sdk-rotation":
                self._write_json(200, sdk_rotation_snapshot(self.paths))
                return
            if p == "/api/ado-tracker":
                self._write_json(200, ado_tracker_snapshot(self.paths))
                return
            if p == "/api/scheduled-tasks":
                q = parse_qs(urlparse(path).query)
                force = (q.get("refresh", ["0"])[0]).lower() not in ("0", "", "false", "no")
                self._write_json(200, scheduled_tasks_snapshot(self.paths, force=force))
                return
            if p == "/api/my-day":
                q = parse_qs(urlparse(path).query)
                force = (q.get("refresh", ["0"])[0]).lower() not in ("0", "", "false", "no")
                self._write_json(200, my_day_snapshot(self.paths, force=force))
                return
            # Explorer artifact (single-file HTML built by the nirvana-site skill).
            # Path is fixed to reports/site/nirvana.html so the same bytes Nir
            # gets via `open the nirvana site` are served here under /explorer.
            if p in ("/explorer", "/explorer/", "/explorer.html"):
                self._write_explorer()
                return
            # Static files under /static/*
            if p.startswith("/static/"):
                rel = p[len("/static/"):]
                if ".." in rel or rel.startswith("/"):
                    self.send_error(403)
                    return
                self._write_static(STATIC_DIR / rel)
                return
            self.send_error(404, "Not Found")
            return

        if method == "POST":
            payload = self._read_json()
            if payload is None:
                self._write_json(400, {"error": "invalid JSON body"})
                return
            with WRITE_LOCK:
                if p == "/api/todos":
                    status, body = add_todo(self.paths, payload)
                    self._write_json(status, body)
                    return
                if p == "/api/agenda":
                    status, body = add_agenda(self.paths, payload)
                    self._write_json(status, body)
                    return
                if p == "/api/ai-plan":
                    status, body = add_ai_plan(self.paths, payload)
                    self._write_json(status, body)
                    return
                if p == "/api/ado-tracker/ping":
                    status, body = ping_ado_owner(self.paths, payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/one-on-ones/([^/]+)", p)
                if m:
                    status, body = add_one_on_one(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/one-on-ones/([^/]+)/summary", p)
                if m:
                    status, body = send_one_on_one_summary(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
            self.send_error(404, "Not Found")
            return

        if method == "PATCH":
            payload = self._read_json()
            if payload is None:
                self._write_json(400, {"error": "invalid JSON body"})
                return
            with WRITE_LOCK:
                if p == "/api/scope-board":
                    status, body = mutate_scope_board(self.paths, payload)
                    self._write_json(status, body)
                    return
                if p == "/api/sdk-rotation":
                    status, body = mutate_sdk_rotation(self.paths, payload)
                    self._write_json(status, body)
                    return
                if p == "/api/sdk-rotation/order":
                    status, body = reorder_sdk_rotation(self.paths, payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/todos/(PT-\d{3})", p)
                if m:
                    status, body = mutate_todo(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/agenda/(TA-\d{3})", p)
                if m:
                    status, body = mutate_agenda_item(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/ai-plan/(AP-\d{3})", p)
                if m:
                    status, body = mutate_ai_plan_item(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/one-on-ones/([^/]+)/personal-notes", p)
                if m:
                    status, body = mutate_personal_notes(self.paths, m.group(1), payload)
                    self._write_json(status, body)
                    return
                m = re.fullmatch(r"/api/one-on-ones/([^/]+)/(ON-\d{3})", p)
                if m:
                    status, body = mutate_one_on_one_item(self.paths, m.group(1), m.group(2), payload)
                    self._write_json(status, body)
                    return
            self.send_error(404, "Not Found")
            return

        self.send_error(405, "Method Not Allowed")

    # ---- HTTP method dispatch ----
    def do_GET(self) -> None:  # noqa: N802
        self._route("GET", self.path)

    def do_POST(self) -> None:  # noqa: N802
        self._route("POST", self.path)

    def do_PATCH(self) -> None:  # noqa: N802
        self._route("PATCH", self.path)


# --- main ----------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5180)
    p.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    args = p.parse_args(argv)

    paths = Paths(args.repo_root)
    if not paths.todos_md.exists():
        sys.stderr.write(f"warning: todos file missing: {paths.todos_md}\n")
    if not paths.agenda_md.exists():
        sys.stderr.write(f"warning: agenda file missing: {paths.agenda_md}\n")

    BoardHandler.paths = paths

    server = ThreadingHTTPServer((args.host, args.port), BoardHandler)
    sys.stderr.write(
        f"nirvana-board v{VERSION} listening on http://{args.host}:{args.port}\n"
        f"  repo root: {paths.root}\n"
        f"  todos: {paths.todos_md.relative_to(paths.root) if paths.todos_md.is_relative_to(paths.root) else paths.todos_md}\n"
        f"  agenda: {paths.agenda_md.relative_to(paths.root) if paths.agenda_md.is_relative_to(paths.root) else paths.agenda_md}\n"
        f"  one-on-ones: {paths.one_on_ones_dir.relative_to(paths.root) if paths.one_on_ones_dir.is_relative_to(paths.root) else paths.one_on_ones_dir}\n"
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("nirvana-board: shutting down\n")
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

