#!/usr/bin/env python3
"""Personal Todos daily email builder.

Parses reports/personal-todos/todos.md, sorts Open items into the configured
sections (Today / Overdue / This week / Snoozed), scans the configured
auto-suggest sources (inbox-watch, team-milestones),
renders an Outlook-safe HTML email body, and writes a state snapshot for
the reply-accept flow.

CLI:
    python build-daily.py
        --todos-file reports/personal-todos/todos.md
        --config     config/personal-todos.yaml
        --reports-root reports
        --state-dir  .copilot/skills/personal-todos/state
        --out-html   <path>
        [--today YYYY-MM-DD]            # override today (testing)
        [--no-suggest]                  # skip the suggest scan
        [--no-stats]                    # skip the weekly stats footer

Emits a one-line JSON summary on stdout for the PowerShell runner:
    {"today_count": 3, "overdue_count": 1, "open_count": 11,
     "weekly_done": 5, "weekly_added": 2, "suggest_count": 4,
     "out_html": "<abs path>", "out_snapshot": "<abs path>"}
"""
from __future__ import annotations
import argparse
import html
import json
import os
import re
import sys
from dataclasses import dataclass, asdict, field
from datetime import date, datetime, timedelta
from pathlib import Path


# ---------- model ----------

PRI_RANK = {"H": 0, "M": 1, "L": 2}
ALLOWED_CATS = {"work", "personal"}


@dataclass
class Todo:
    id: str                       # "PT-007"
    title: str
    section: str                  # "open" | "done"
    status: str                   # "Open" | "Snoozed" | "Done" | "Dropped"
    category: str = ""
    priority: str = "M"
    created: str = ""
    due: str = ""                 # "" or "YYYY-MM-DD"
    recur: str = "none"
    snoozed_until: str = ""       # "" or "YYYY-MM-DD"
    snoozed_reason: str = ""
    done_on: str = ""
    notes: str = ""

    @property
    def due_date(self) -> date | None:
        return _parse_iso(self.due)

    @property
    def created_date(self) -> date | None:
        return _parse_iso(self.created)

    @property
    def done_date(self) -> date | None:
        return _parse_iso(self.done_on)


def _parse_iso(s: str) -> date | None:
    if not s or s.strip() in ("-", ""):
        return None
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%d").date()
    except ValueError:
        return None


# ---------- parser ----------

HEADING_RE = re.compile(r"^###\s+(PT-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$")
FIELD_RE = re.compile(r"^\s*-\s*\*\*(?P<key>[^:*]+):\*\*\s*(?P<value>.+?)\s*$")
SNOOZE_REASON_RE = re.compile(r'^(?P<date>\S+)\s+"(?P<reason>[^"]+)"\s*$')


def parse_todos(path: Path) -> list[Todo]:
    if not path.exists():
        return []
    items: list[Todo] = []
    section = "preamble"
    current: Todo | None = None
    last_key: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^##\s+Open\b", raw):
            if current:
                items.append(current); current = None
            section = "open"; last_key = None; continue
        if re.match(r"^##\s+Done\b", raw):
            if current:
                items.append(current); current = None
            section = "done"; last_key = None; continue
        m = HEADING_RE.match(raw)
        if m:
            if current:
                items.append(current)
            current = Todo(id=m.group(1), title=m.group(2),
                           section=section, status="Open")
            last_key = None
            continue
        if current is None:
            continue
        fm = FIELD_RE.match(raw)
        if not fm:
            # Continuation line of the multi-line Notes field (raw wrapped line).
            stripped = raw.strip()
            if (last_key == "notes" and stripped
                    and not stripped.startswith("#")
                    and not stripped.startswith("---")):
                current.notes = (current.notes + "\n" + stripped) if current.notes else stripped
            else:
                last_key = None
            continue
        key = fm.group("key").strip().lower()
        val = fm.group("value").strip()
        last_key = key
        if key == "status":
            current.status = val
        elif key == "category":
            current.category = val.lower()
        elif key == "priority":
            current.priority = val.upper()[:1] if val else "M"
        elif key == "created":
            current.created = val
        elif key == "due":
            current.due = "" if val in ("-", "") else val
        elif key == "recur":
            current.recur = val.lower() or "none"
        elif key == "snoozed until":
            sm = SNOOZE_REASON_RE.match(val)
            if sm:
                current.snoozed_until = sm.group("date")
                current.snoozed_reason = sm.group("reason")
            elif val and val != "-":
                current.snoozed_until = val
        elif key == "notes":
            current.notes = val
        elif key == "done on":
            current.done_on = val
    if current:
        items.append(current)
    return items


# ---------- config ----------

def _load_yaml_simple(path: Path) -> dict:
    """Tiny YAML reader — only handles the shape used in personal-todos.yaml.

    Supports: top-level string keys, scalar values, list-of-scalars (- item).
    Strips comments. NOT a general YAML parser; keeps build dependencies thin.
    """
    if not path.exists():
        return {}
    data: dict = {}
    current_key: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        # Strip inline comments (only when '#' is preceded by space or at start).
        stripped = line.lstrip()
        if stripped.startswith("#") or not stripped:
            continue
        if line.startswith(" ") or line.startswith("\t"):
            if current_key is None:
                continue
            if stripped.startswith("- "):
                val = stripped[2:].strip()
                if val.startswith("#"):
                    continue
                # strip trailing inline comment
                val = re.split(r"\s+#", val, maxsplit=1)[0].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                if isinstance(data.get(current_key), list):
                    data[current_key].append(val)
                else:
                    data[current_key] = [val]
            else:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", stripped)
                if m and isinstance(data.get(current_key), dict):
                    sub_k = m.group(1).strip()
                    sub_v = m.group(2).strip()
                    sub_v = re.split(r"\s+#", sub_v, maxsplit=1)[0].strip()
                    if sub_v.startswith('"') and sub_v.endswith('"'):
                        sub_v = sub_v[1:-1]
                    data[current_key][sub_k] = sub_v
            continue
        # Top-level "key: value"
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        k = m.group(1).strip()
        v = m.group(2).strip()
        v = re.split(r"\s+#", v, maxsplit=1)[0].strip()
        current_key = k
        if v == "" or v == "[]":
            data[k] = [] if v == "[]" else {}
        else:
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            data[k] = v
            current_key = None  # scalar, no nesting follows
    return data


# ---------- classification ----------

def classify(items: list[Todo], today: date) -> dict:
    open_items = [t for t in items if t.section == "open"
                  and t.status in ("Open", "Snoozed")]
    # Auto-wake: snoozed items whose date is <= today flip back to Open in render.
    for t in open_items:
        if t.status == "Snoozed":
            su = _parse_iso(t.snoozed_until)
            if su and su <= today:
                t.status = "Open"
                t.snoozed_until = ""
                t.snoozed_reason = ""

    visible = [t for t in open_items if t.status == "Open"]
    snoozed = [t for t in open_items if t.status == "Snoozed"]

    overdue = [t for t in visible if t.due_date and t.due_date < today]
    due_today = [t for t in visible if t.due_date == today]
    this_week_end = today + timedelta(days=7)
    this_week = [t for t in visible
                 if t.due_date and today < t.due_date <= this_week_end]
    later = [t for t in visible
             if t.due_date and t.due_date > this_week_end]
    no_due = [t for t in visible if not t.due_date]

    def sort_key(t: Todo):
        return (PRI_RANK.get(t.priority, 1),
                t.due_date or date(9999, 12, 31),
                t.id)

    overdue.sort(key=lambda t: (t.due_date or today, PRI_RANK.get(t.priority, 1)))
    due_today.sort(key=sort_key)
    this_week.sort(key=lambda t: (t.due_date or today, PRI_RANK.get(t.priority, 1)))
    later.sort(key=lambda t: (t.due_date or today, PRI_RANK.get(t.priority, 1)))
    no_due.sort(key=sort_key)
    snoozed.sort(key=lambda t: (_parse_iso(t.snoozed_until) or today, t.id))

    today_focus = (overdue + due_today + no_due)[:3]
    return {
        "today_focus": today_focus,
        "overdue": overdue,
        "due_today": due_today,
        "this_week": this_week,
        "later": later,
        "no_due": no_due,
        "snoozed": snoozed,
        "visible_open": visible,
        "all_open": open_items,
    }


def weekly_stats(items: list[Todo], today: date) -> dict:
    iso_year, iso_week, _ = today.isocalendar()
    done_this_week = 0
    added_this_week = 0
    for t in items:
        cd = t.created_date
        if cd:
            ciso = cd.isocalendar()
            if ciso[0] == iso_year and ciso[1] == iso_week:
                added_this_week += 1
        dd = t.done_date
        if dd:
            diso = dd.isocalendar()
            if diso[0] == iso_year and diso[1] == iso_week:
                done_this_week += 1
    # "Open" in the stats footer matches the header: visible (non-snoozed) items
    # in the ## Open section. Snoozed items get their own collapsed section.
    open_count = len([t for t in items if t.section == "open"
                      and t.status == "Open"])
    return {
        "done": done_this_week,
        "added": added_this_week,
        "open": open_count,
    }


# ---------- auto-suggest ----------

@dataclass
class Suggestion:
    title: str
    category: str
    priority: str
    source_label: str
    due: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _latest_md_in(folder: Path) -> Path | None:
    if not folder.exists() or not folder.is_dir():
        return None
    md_files = sorted(folder.glob("*.md"))
    return md_files[-1] if md_files else None


def _scan_inbox_watch(reports_root: Path, max_items: int) -> list[Suggestion]:
    """Pull deferred-to-Nir items from the most recent inbox-watch report.

    Supports two on-disk shapes:
      1. Section-style: a ``## Deferred to Nir`` / ``## Needs your input``
         header followed by ``- bullet`` items.
      2. Flat-log: per-line ``- HH:MM from=... status=deferred ... subject="..."``
         entries. Common in newer reports.
    """
    folder = reports_root / "inbox-watch"
    latest = _latest_md_in(folder)
    if not latest:
        return []
    out: list[Suggestion] = []
    in_deferred = False
    text = latest.read_text(encoding="utf-8", errors="replace")
    for raw in text.splitlines():
        line = raw.rstrip()
        low = line.lower()

        # --- shape 2: flat log line ---
        if line.startswith("- ") and "status=deferred" in low:
            m = re.search(r'subject="([^"]+)"', line, re.IGNORECASE)
            if m:
                subj = m.group(1).strip()
                subj = re.sub(r"^(?:re|fw|fwd):\s*", "", subj, flags=re.IGNORECASE)
                subj = re.sub(r"^\[Nirvana\]\s*[\-\u2014]?\s*", "", subj)
                if 5 <= len(subj) <= 110:
                    title = f"Reply to: {subj}"
                    out.append(Suggestion(
                        title=title,
                        category="work",
                        priority="M",
                        source_label=f"inbox-watch {latest.stem}",
                    ))
            if len(out) >= max_items:
                break
            continue

        # --- shape 1: section-style ---
        if line.startswith("## "):
            in_deferred = ("defer" in low and "nir" in low) or "needs your input" in low
            continue
        if not in_deferred:
            continue
        if line.startswith("- ") and len(line) > 4:
            title = line[2:].strip()
            title = re.sub(r"\*\*", "", title)
            title = re.split(r"\s+\(from\s|\s+\u2014\s|\s+--\s|\s+\|\s", title, maxsplit=1)[0]
            title = title.strip().rstrip(".")
            if 5 <= len(title) <= 110:
                out.append(Suggestion(
                    title=title,
                    category="personal",
                    priority="M",
                    source_label=f"inbox-watch {latest.stem}",
                ))
        if len(out) >= max_items:
            break
    return out


def _scan_team_milestones(reports_root: Path, max_items: int, today: date) -> list[Suggestion]:
    folder = reports_root / "team-milestones"
    if not folder.exists():
        return []
    latest = _latest_md_in(folder)
    if not latest:
        return []
    out: list[Suggestion] = []
    text = latest.read_text(encoding="utf-8", errors="replace")
    date_in_window = today + timedelta(days=7)
    for raw in text.splitlines():
        # rough: "<name> — birthday YYYY-MM-DD" or "anniversary"
        m = re.search(r"([A-Z][A-Za-z'’\- ]+?)\s+[\u2014\-]\s+(birthday|anniversary|hired)\b.*?(\d{4}-\d{2}-\d{2}|\d{2}/\d{2})",
                      raw, re.IGNORECASE)
        if not m:
            continue
        name = m.group(1).strip().rstrip(",")
        kind = m.group(2).lower()
        date_str = m.group(3)
        d = None
        if re.match(r"\d{4}-\d{2}-\d{2}", date_str):
            d = _parse_iso(date_str)
        else:
            # MM/DD — assume current year
            try:
                mm, dd = date_str.split("/")
                d = date(today.year, int(mm), int(dd))
                if d < today:
                    d = date(today.year + 1, int(mm), int(dd))
            except Exception:
                d = None
        if d is None or not (today <= d <= date_in_window):
            continue
        verb = "Wish" if kind == "birthday" else "Acknowledge"
        title = f"{verb} {name} for {kind} on {d.isoformat()}"
        out.append(Suggestion(
            title=title,
            category="personal",
            priority="M",
            due=d.isoformat(),
            source_label=f"team-milestones {kind}",
        ))
        if len(out) >= max_items:
            break
    return out


def auto_suggest(reports_root: Path, max_total: int, today: date,
                 existing_titles: set[str]) -> list[Suggestion]:
    """Round-robin across the three sources up to max_total suggestions.

    Skips any candidate whose title is already present (case-insensitive substring)
    in the existing Open todos.
    """
    sources = [
        _scan_inbox_watch(reports_root, max_total),
        _scan_team_milestones(reports_root, max_total, today),
    ]
    out: list[Suggestion] = []
    existing_lc = {t.lower() for t in existing_titles}
    i = 0
    while len(out) < max_total and any(sources):
        src = sources[i % len(sources)]
        if src:
            cand = src.pop(0)
            lc = cand.title.lower()
            if not any(lc in e or e in lc for e in existing_lc):
                out.append(cand)
                existing_lc.add(lc)
        i += 1
        # Safety: bail when all empty
        if i > max_total * 4 + 8:
            break
    return out


# ---------- HTML rendering ----------

def _esc(s: str) -> str:
    return html.escape(s or "", quote=False)


def _pri_badge(pri: str) -> str:
    color = {"H": "#d32f2f", "M": "#1976d2", "L": "#757575"}.get(pri, "#1976d2")
    label = {"H": "High", "M": "Med", "L": "Low"}.get(pri, "Med")
    return (f'<span style="display:inline-block;padding:1px 7px;border-radius:10px;'
            f'background:{color};color:#fff;font-size:11px;font-weight:600;'
            f'margin-right:6px;">{label}</span>')


def _cat_chip(cat: str) -> str:
    return (f'<span style="display:inline-block;padding:1px 7px;border-radius:10px;'
            f'background:#eee;color:#555;font-size:11px;margin-right:6px;">{_esc(cat or "—")}</span>')


def _due_phrase(t: Todo, today: date) -> str:
    if not t.due_date:
        return "no due date"
    delta = (t.due_date - today).days
    if delta < 0:
        return f"{-delta}d late"
    if delta == 0:
        return "due today"
    if delta == 1:
        return "due tomorrow"
    return f"due in {delta}d"


def _row_card(t: Todo, today: date) -> str:
    title = _esc(t.title)
    due = _due_phrase(t, today)
    pri = _pri_badge(t.priority)
    cat = _cat_chip(t.category)
    return (f'<tr><td style="padding:8px 10px;border-bottom:1px solid #eee;font-family:Segoe UI,Arial,sans-serif;color:#222;">'
            f'<span style="color:#888;font-family:Consolas,monospace;font-size:12px;margin-right:8px;">{t.id}</span>'
            f'<strong style="font-size:14px;">{title}</strong><br>'
            f'<span style="font-size:12px;color:#666;margin-top:4px;display:inline-block;">{pri}{cat}<span style="color:#888;">{due}</span></span>'
            f'</td></tr>')


def _section_header(emoji: str, title: str, color: str = "#222") -> str:
    return (f'<h2 style="margin:22px 0 8px 0;padding:0;font-size:1.05em;color:{color};'
            f'font-family:Segoe UI,Arial,sans-serif;">{emoji} {title}</h2>')


def _bucket_table(rows_html: str) -> str:
    if not rows_html:
        return ""
    return (f'<table cellpadding="0" cellspacing="0" border="0" '
            f'style="border-collapse:collapse;width:100%;margin:6px 0 8px 0;">'
            f'{rows_html}</table>')


def render(buckets: dict, suggestions: list[Suggestion], stats: dict,
           today: date, sections: list[str], render_suggest: bool,
           render_stats: bool) -> str:
    out: list[str] = []
    # Header line
    today_label = today.strftime("%a · %Y-%m-%d")
    overdue_n = len(buckets["overdue"])
    today_n = len(buckets["due_today"])
    open_n = len(buckets["visible_open"])
    header_bits = [f'<span style="color:#888;font-size:13px;">{today_label}</span>']
    if overdue_n:
        header_bits.append(f'<span style="color:#d32f2f;font-weight:600;font-size:13px;margin-left:10px;">🔥 {overdue_n} overdue</span>')
    if today_n:
        header_bits.append(f'<span style="color:#1976d2;font-weight:600;font-size:13px;margin-left:10px;">🎯 {today_n} due today</span>')
    out.append(f'<p style="margin:0 0 6px 0;font-family:Segoe UI,Arial,sans-serif;">{ " · ".join(header_bits) }</p>')
    out.append(f'<p style="margin:0 0 12px 0;color:#666;font-size:13px;font-family:Segoe UI,Arial,sans-serif;">{open_n} open total. Pick one. Or two. Or eight.</p>')

    for sec in sections:
        sec = sec.strip().lower()
        if sec == "today":
            tf = buckets["today_focus"]
            if not tf:
                out.append(_section_header("🎯", "Today's focus", "#1976d2"))
                out.append('<p style="margin:0 0 14px 0;color:#888;font-size:13px;">Nothing flagged. Choose your own adventure.</p>')
            else:
                out.append(_section_header("🎯", "Today's focus", "#1976d2"))
                rows = "".join(_row_card(t, today) for t in tf)
                out.append(_bucket_table(rows))
        elif sec == "overdue":
            if buckets["overdue"]:
                out.append(_section_header("🔥", "Overdue", "#d32f2f"))
                rows = "".join(_row_card(t, today) for t in buckets["overdue"])
                out.append(f'<div style="border-left:4px solid #d32f2f;background:#ffebee;padding:6px 10px;border-radius:4px;">{_bucket_table(rows)}</div>')
        elif sec == "this_week":
            if buckets["this_week"]:
                out.append(_section_header("📅", "This week"))
                # group by day
                from collections import OrderedDict
                groups: "OrderedDict[date, list[Todo]]" = OrderedDict()
                for t in buckets["this_week"]:
                    groups.setdefault(t.due_date, []).append(t)
                for d, ts in groups.items():
                    out.append(f'<p style="margin:10px 0 4px 0;font-size:12px;color:#666;font-weight:600;text-transform:uppercase;letter-spacing:0.4px;">{d.strftime("%a %d %b")}</p>')
                    rows = "".join(_row_card(t, today) for t in ts)
                    out.append(_bucket_table(rows))
        elif sec == "later":
            # Open items with due > today+7d. Includes no_due items NOT shown
            # in Today's focus, so nothing on the list ever vanishes from the email.
            later_rows = list(buckets["later"])
            shown_ids = {t.id for t in buckets["today_focus"]}
            later_rows += [t for t in buckets["no_due"] if t.id not in shown_ids]
            if later_rows:
                out.append(_section_header("🗓", "Later"))
                rows = "".join(_row_card(t, today) for t in later_rows)
                out.append(_bucket_table(rows))
        elif sec == "suggest" and render_suggest and suggestions:
            out.append(_section_header("💡", "Nirvana suggests"))
            out.append('<table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;width:100%;margin:6px 0 8px 0;">')
            for i, s in enumerate(suggestions, start=1):
                due_part = f' · due {s.due}' if s.due else ''
                out.append(
                    f'<tr><td style="padding:6px 10px;border-bottom:1px solid #eee;font-family:Segoe UI,Arial,sans-serif;color:#222;">'
                    f'<span style="display:inline-block;width:22px;color:#1976d2;font-weight:600;">{i}.</span>'
                    f'<strong>{_esc(s.title)}</strong> '
                    f'<span style="color:#888;font-size:12px;">({_esc(s.category)} · {_esc(s.priority)}{due_part}) · source: {_esc(s.source_label)}</span>'
                    f'</td></tr>'
                )
            out.append('</table>')
            out.append('<p style="margin:0 0 14px 0;color:#666;font-size:12px;font-style:italic;">'
                       'Reply <code>PT accept 1,3</code> or drop a 🖥 Nirvana Agent task '
                       '<code>PT accept 1,3</code> to add them.</p>')
        elif sec == "snoozed" and buckets["snoozed"]:
            out.append('<details style="margin:14px 0;"><summary style="cursor:pointer;font-weight:600;color:#666;font-size:13px;font-family:Segoe UI,Arial,sans-serif;">💤 Snoozed / waiting ({} items)</summary>'.format(len(buckets["snoozed"])))
            for t in buckets["snoozed"]:
                reason = f' — <em>{_esc(t.snoozed_reason)}</em>' if t.snoozed_reason else ''
                out.append(
                    f'<p style="margin:4px 0 0 12px;font-size:13px;color:#555;font-family:Segoe UI,Arial,sans-serif;">'
                    f'<span style="color:#888;font-family:Consolas,monospace;font-size:11px;margin-right:8px;">{t.id}</span>'
                    f'{_esc(t.title)} · until {_esc(t.snoozed_until or "?")}{reason}</p>'
                )
            out.append('</details>')
        elif sec == "stats" and render_stats:
            out.append('<p style="margin:18px 0 4px 0;padding:8px 12px;background:#f5f5f5;border-radius:4px;color:#444;font-size:13px;font-family:Segoe UI,Arial,sans-serif;">'
                       f'📊 <strong>This week:</strong> {stats["done"]} done · {stats["open"]} open · {stats["added"]} added</p>')

    return "".join(out)


# ---------- main ----------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--todos-file", required=True)
    ap.add_argument("--config",     required=True)
    ap.add_argument("--reports-root", required=True)
    ap.add_argument("--state-dir",  required=True)
    ap.add_argument("--out-html",   required=True)
    ap.add_argument("--today",      default=None)
    ap.add_argument("--no-suggest", action="store_true")
    ap.add_argument("--no-stats",   action="store_true")
    args = ap.parse_args()

    today = (datetime.strptime(args.today, "%Y-%m-%d").date()
             if args.today else date.today())

    todos_path = Path(args.todos_file)
    items = parse_todos(todos_path)

    cfg = _load_yaml_simple(Path(args.config))
    sections = cfg.get("sections") or ["today", "overdue", "this_week", "suggest", "snoozed", "stats"]
    suggest_count = int(cfg.get("suggest_count") or 5)

    buckets = classify(items, today)
    stats = weekly_stats(items, today)

    suggestions: list[Suggestion] = []
    if not args.no_suggest:
        existing = {t.title for t in buckets["all_open"]}
        # Also include recently-done titles to avoid re-suggesting
        existing.update(t.title for t in items if t.section == "done")
        suggestions = auto_suggest(
            Path(args.reports_root), suggest_count, today, existing
        )

    body_html = render(
        buckets, suggestions, stats, today, sections,
        render_suggest=not args.no_suggest,
        render_stats=not args.no_stats,
    )

    out_html = Path(args.out_html)
    out_html.parent.mkdir(parents=True, exist_ok=True)
    out_html.write_text(body_html, encoding="utf-8")

    # State snapshot for reply-accept lookups.
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    snapshot = {
        "today": today.isoformat(),
        "suggestions": [s.to_dict() for s in suggestions],
        "today_focus": [t.id for t in buckets["today_focus"]],
        "overdue": [t.id for t in buckets["overdue"]],
    }
    snap_path = state_dir / "last-suggest.json"
    snap_path.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")

    summary = {
        "today_count": len(buckets["due_today"]),
        "overdue_count": len(buckets["overdue"]),
        "open_count": len(buckets["visible_open"]),
        "snoozed_count": len(buckets["snoozed"]),
        "weekly_done": stats["done"],
        "weekly_added": stats["added"],
        "suggest_count": len(suggestions),
        "out_html": str(out_html.resolve()),
        "out_snapshot": str(snap_path.resolve()),
    }
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
