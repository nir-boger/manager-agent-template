#!/usr/bin/env python3
"""Atomically append a new RM-NNN row to reports/reminders/reminders.md.

Single source of truth for add mode. Avoids the ID-write bug class
(silent interpolation failures) by computing RM-NNN here and writing
via .tmp -> rename.

Outputs one TSV line to stdout on success:
    RM-NNN<TAB>title<TAB>kind<TAB>when
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date, datetime
from pathlib import Path

HEADING_ID_RE = re.compile(r"^###\s+RM-(\d{3})\b", flags=re.MULTILINE)
PENDING_HEADER_RE   = re.compile(r"^##\s+Pending\b",   flags=re.MULTILINE)
FIRED_HEADER_RE     = re.compile(r"^##\s+Fired\b",     flags=re.MULTILINE)
CANCELLED_HEADER_RE = re.compile(r"^##\s+Cancelled\b", flags=re.MULTILINE)

VALID_KINDS    = {"meeting", "absolute"}
VALID_CHANNELS = {"email"}  # v1


def next_id(text: str) -> str:
    nums = [int(n) for n in HEADING_ID_RE.findall(text)]
    n = max(nums, default=0) + 1
    if n > 999:
        sys.exit("RM-NNN counter exhausted (>999).")
    return f"RM-{n:03d}"


def render_section(rm: str, args: argparse.Namespace, today: str) -> str:
    lines = [f"### {rm} - {args.title.strip()}", ""]
    lines.append(f"- **Status:** pending")
    lines.append(f"- **Kind:** {args.kind}")
    lines.append(f"- **Created:** {today}")
    lines.append(f"- **Channel:** {args.channel}")
    if args.kind == "meeting":
        lines.append(f"- **Meeting subject match:** {args.meeting_subject.strip()}")
        lines.append(f"- **Meeting date:** {args.meeting_date}")
        lines.append(f"- **Offset min:** {args.offset_min}")
    else:
        lines.append(f"- **Fire at:** {args.fire_at}")
    if args.notes and args.notes.strip():
        lines.append(f"- **Notes:** {args.notes.strip()}")
    lines.append("")
    return "\n".join(lines) + "\n"


def insert_under_pending(text: str, section: str) -> str:
    """Insert the new section immediately after the '## Pending' line and any
    empty-state placeholder, before any existing ### RM-* sections.
    """
    if not PENDING_HEADER_RE.search(text):
        return (
            "# Reminders (RM-NNN)\n\n"
            "Reminder source of truth. Hand-readable. Runner polls every 5 min.\n\n"
            "---\n\n"
            "## Pending\n\n"
            f"{section}---\n\n## Fired\n\n_(Empty - reminders move here after firing.)_\n\n"
            "---\n\n## Cancelled\n\n_(Empty - reminders move here after explicit cancel.)_\n"
        )
    m = PENDING_HEADER_RE.search(text)
    head_end = text.find("\n", m.end())
    after = text[head_end + 1 :]
    after_lines = after.split("\n", 2)
    if after_lines and re.match(r"\s*_\(Empty.*?\)_\s*$", after_lines[0]):
        rest = "\n".join(after_lines[1:]) if len(after_lines) > 1 else ""
        return text[: head_end + 1] + "\n" + section + rest
    return text[: head_end + 1] + "\n" + section + after


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--reminders-file", required=True, type=Path)
    p.add_argument("--title", required=True)
    p.add_argument("--kind", choices=sorted(VALID_KINDS), required=True)
    p.add_argument("--channel", choices=sorted(VALID_CHANNELS), default="email")
    p.add_argument("--meeting-subject")
    p.add_argument("--meeting-date")
    p.add_argument("--offset-min", type=int)
    p.add_argument("--fire-at")
    p.add_argument("--notes", default="")
    p.add_argument("--today", default=date.today().isoformat())
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if args.kind == "meeting":
        if not args.meeting_subject or not args.meeting_date or args.offset_min is None:
            sys.exit("--kind=meeting requires --meeting-subject, --meeting-date, --offset-min")
        try:
            datetime.strptime(args.meeting_date, "%Y-%m-%d")
        except ValueError:
            sys.exit(f"--meeting-date must be YYYY-MM-DD, got: {args.meeting_date}")
    else:
        if not args.fire_at:
            sys.exit("--kind=absolute requires --fire-at (ISO 8601 with tz, e.g. 2026-05-22T09:00:00+03:00)")
        try:
            datetime.fromisoformat(args.fire_at)
        except ValueError:
            sys.exit(f"--fire-at must be ISO 8601, got: {args.fire_at}")

    text = ""
    if args.reminders_file.exists():
        text = args.reminders_file.read_text(encoding="utf-8")

    rm = next_id(text)
    section = render_section(rm, args, args.today)
    new_text = insert_under_pending(text, section)

    if args.dry_run:
        sys.stdout.write(new_text)
        return 0

    args.reminders_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = args.reminders_file.with_suffix(args.reminders_file.suffix + ".tmp")
    tmp.write_text(new_text, encoding="utf-8")
    tmp.replace(args.reminders_file)

    when = args.fire_at if args.kind == "absolute" else f"{args.offset_min}m around '{args.meeting_subject}' @ {args.meeting_date}"
    sys.stdout.write(f"{rm}\t{args.title}\t{args.kind}\t{when}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
