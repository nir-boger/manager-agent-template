#!/usr/bin/env python3
"""Atomically append a new PT-NNN row to reports/personal-todos/todos.md.

Single source of truth for add-item mode. Both the chat path (personal-todos)
and the Nirvana Agent route (nirvana-agent-todos) MUST call this script
instead of hand-rolling Markdown. Prevents the 2026-05-12 ID-write bug where
inline PowerShell silently failed to interpolate the PT-NNN counter, producing
a heading like `###  -- Test from my mobile` that the daily builder regex
then dropped.

Outputs one TSV line to stdout on success:
    PT-NNN<TAB>title<TAB>category<TAB>priority<TAB>due
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

HEADING_ID_RE = re.compile(r"^###\s+PT-(\d{3})\b", flags=re.MULTILINE)
OPEN_HEADER_RE = re.compile(r"^##\s+Open\b", flags=re.MULTILINE)
DONE_HEADER_RE = re.compile(r"^##\s+Done\b", flags=re.MULTILINE)

VALID_CATEGORIES = {"work", "personal"}
VALID_PRIORITIES = {"H", "M", "L"}

_BR_RE = re.compile(r"<br\s*/?>", flags=re.IGNORECASE)


def encode_multiline(value: str) -> str:
    """Normalize a possibly multi-line value to REAL newlines (never `<br>`).
    The Notes value is written as the field head line plus continuation lines;
    build-daily.py and every other line-based reader fold them back. Trims
    leading / trailing blank lines.
    """
    if value is None:
        return ""
    norm = _BR_RE.sub("\n", str(value).replace("\r\n", "\n").replace("\r", "\n"))
    segs = [seg.rstrip() for seg in norm.split("\n")]
    while segs and segs[0].strip() == "":
        segs.pop(0)
    while segs and segs[-1].strip() == "":
        segs.pop()
    return "\n".join(segs)


def next_id(text: str) -> str:
    """Compute the next PT-NNN id by scanning across both ## Open and ## Done."""
    nums = [int(n) for n in HEADING_ID_RE.findall(text)]
    n = max(nums, default=0) + 1
    if n > 999:
        sys.exit("PT-NNN counter exhausted (>999). Time to roll over the format.")
    return f"PT-{n:03d}"


def parse_due(s: str | None, today: date) -> str:
    """Convert natural-language due into ISO date. Returns '-' if unparseable/empty."""
    if not s or s.strip() in ("", "-"):
        return "-"
    raw = s.strip()
    # ISO direct
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date().isoformat()
    except ValueError:
        pass
    low = raw.lower()
    if low == "today":
        return today.isoformat()
    if low in ("tomorrow", "tom"):
        return (today + timedelta(days=1)).isoformat()
    m = re.match(r"in\s+(\d+)\s+days?$", low)
    if m:
        return (today + timedelta(days=int(m.group(1)))).isoformat()
    if low in ("in a week", "next week"):
        return (today + timedelta(days=7)).isoformat()
    if low in ("eow", "end of week"):
        # Sun-Thu work week => nearest upcoming Sunday (weekday() == 6)
        delta = (6 - today.weekday()) % 7
        if delta == 0:
            delta = 7
        return (today + timedelta(days=delta)).isoformat()
    if low in ("eom", "end of month"):
        if today.month == 12:
            nxt = date(today.year + 1, 1, 1)
        else:
            nxt = date(today.year, today.month + 1, 1)
        return (nxt - timedelta(days=1)).isoformat()
    weekdays = {"mon": 0, "tue": 1, "wed": 2, "thu": 3,
                "fri": 4, "sat": 5, "sun": 6}
    m = re.match(r"(next|by|on)?\s*(mon|tue|wed|thu|fri|sat|sun)\w*$", low)
    if m:
        prefix, day = m.group(1), m.group(2)
        target = weekdays[day]
        delta = (target - today.weekday()) % 7
        if delta == 0 or prefix == "next":
            delta = delta or 7
        return (today + timedelta(days=delta)).isoformat()
    return "-"


def build_section(pt_id: str, title: str, category: str, priority: str,
                  created: str, due: str, recur: str, snoozed_until: str,
                  notes: str) -> str:
    """Emit a strict, parser-compatible markdown section. Uses em-dash (U+2014)
    in the heading to match HEADING_RE in build-daily.py."""
    return (
        f"### {pt_id} \u2014 {title}\n\n"
        f"- **Status:** Open\n"
        f"- **Category:** {category}\n"
        f"- **Priority:** {priority}\n"
        f"- **Created:** {created}\n"
        f"- **Due:** {due}\n"
        f"- **Recur:** {recur}\n"
        f"- **Snoozed until:** {snoozed_until}\n"
        f"- **Notes:** {notes}\n"
    )


def insert_into_open(text: str, section: str) -> str:
    """Insert section at the end of ## Open (just before the '---' separator
    that precedes ## Done). Defensive about whitespace, idempotent shape."""
    if not text.endswith("\n"):
        text += "\n"
    m_open = OPEN_HEADER_RE.search(text)
    m_done = DONE_HEADER_RE.search(text)
    if not m_open or not m_done or m_done.start() < m_open.end():
        sys.exit("File shape: cannot find ## Open followed by ## Done.")
    pre = text[:m_done.start()].rstrip()
    had_sep = pre.endswith("---")
    if had_sep:
        pre = pre[:-3].rstrip()
    suffix = text[m_done.start():]
    sep_block = "---\n\n" if had_sep else ""
    return f"{pre}\n\n{section.rstrip()}\n\n{sep_block}{suffix}"


def atomic_write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--todos-file", required=True, type=Path)
    p.add_argument("--title", required=True)
    p.add_argument("--category", default="personal")
    p.add_argument("--priority", default="M")
    p.add_argument("--due", default="-")
    p.add_argument("--recur", default="none")
    p.add_argument("--snoozed-until", default="-")
    p.add_argument("--notes", default="")
    p.add_argument("--today", default=date.today().isoformat())
    p.add_argument("--dry-run", action="store_true",
                   help="Print the section that would be written; don't touch the file.")
    args = p.parse_args(argv)

    if not args.title.strip():
        sys.exit("--title is required and must be non-empty.")

    category = args.category.strip().lower()
    if category not in VALID_CATEGORIES:
        sys.exit(f"--category must be one of {sorted(VALID_CATEGORIES)}; got {category!r}.")

    priority = args.priority.strip().upper()[:1] or "M"
    if priority not in VALID_PRIORITIES:
        sys.exit(f"--priority must be one of {sorted(VALID_PRIORITIES)}; got {args.priority!r}.")

    try:
        today = datetime.strptime(args.today, "%Y-%m-%d").date()
    except ValueError:
        sys.exit(f"--today must be YYYY-MM-DD; got {args.today!r}.")

    todos_path: Path = args.todos_file
    if not todos_path.exists():
        sys.exit(f"todos file does not exist: {todos_path}")

    text = todos_path.read_text(encoding="utf-8")
    pt_id = next_id(text)
    due = parse_due(args.due, today)
    notes = encode_multiline(args.notes) or "-"
    recur = (args.recur or "none").strip().lower() or "none"
    snoozed_until = (args.snoozed_until or "-").strip() or "-"

    section = build_section(
        pt_id=pt_id, title=args.title.strip(), category=category,
        priority=priority, created=today.isoformat(), due=due,
        recur=recur, snoozed_until=snoozed_until, notes=notes,
    )

    if args.dry_run:
        sys.stdout.write(section)
        sys.stderr.write(f"[dry-run] would assign {pt_id}; not writing.\n")
        return 0

    new_text = insert_into_open(text, section)
    atomic_write(todos_path, new_text)

    sys.stdout.write(f"{pt_id}\t{args.title.strip()}\t{category}\t{priority}\tdue={due}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
