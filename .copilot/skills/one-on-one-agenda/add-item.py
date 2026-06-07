#!/usr/bin/env python3
"""Atomically append a new ON-NNN row to a per-person 1:1 agenda markdown file.

Single source of truth for the `one-on-one-agenda` skill's add mode. Never
hand-roll the markdown — this helper ensures heading shape, ID counter, and
field shape stay parser-clean. Same lesson as `personal-todos` (the 2026-05-12
silent ID-write incident).

Outputs one TSV line to stdout on success:
    ON-NNN<TAB>title<TAB>kind
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path

HEADING_ID_RE = re.compile(r"^###\s+ON-(\d{3})\b", flags=re.MULTILINE)
OPEN_HEADER_RE = re.compile(r"^##\s+Open\b", flags=re.MULTILINE)
CLOSED_HEADER_RE = re.compile(r"^##\s+Closed\b", flags=re.MULTILINE)
OPEN_EMPTY_STATE_RE = re.compile(
    r"(^##\s+Open\s*\n\n)_\(Empty[^)]*\)_\s*\n",
    flags=re.MULTILINE,
)

VALID_KINDS = {"discussion", "follow-up"}

_BR_RE = re.compile(r"<br\s*/?>", flags=re.IGNORECASE)


def encode_multiline(value: str) -> str:
    """Normalize a possibly multi-line value to REAL newlines (never `<br>`),
    mirroring nirvana-board markdown_io.encode_multiline. The value is written
    as the field head line plus continuation lines; every line-based reader
    folds them back. Trims leading / trailing blank lines; all-blank -> "".
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
    nums = [int(n) for n in HEADING_ID_RE.findall(text)]
    n = max(nums, default=0) + 1
    if n > 999:
        sys.exit("ON-NNN counter exhausted (>999) for this file.")
    return f"ON-{n:03d}"


def normalize_kind(raw: str) -> str:
    s = (raw or "").strip().lower().replace("_", "-")
    if s.startswith("follow") or s == "fu":
        return "follow-up"
    return "discussion"


def display_kind(norm: str) -> str:
    return "Follow-up" if norm == "follow-up" else "Discussion"


def build_section(on_id: str, args: argparse.Namespace, kind_norm: str) -> str:
    kind = display_kind(kind_norm)
    lines = [
        f"### {on_id} \u2014 {args.title.strip()}",
        "",
        "- **Status:** Open",
        f"- **Kind:** {kind}",
        f"- **Opened by:** {(args.opened_by or 'Nir').strip() or 'Nir'}",
        f"- **Opened on:** {args.opened_on}",
        f"- **Owner:** {(args.owner or 'TBD').strip() or 'TBD'}",
        f"- **Summary:** {encode_multiline(args.summary) or '-'}",
        f"- **Why it matters:** {encode_multiline(args.why_matters) or '-'}",
        f"- **Next step:** {encode_multiline(args.next_step) or '-'}",
    ]
    notes_enc = encode_multiline(args.notes)
    if notes_enc:
        lines.append(f"- **Notes:** {notes_enc}")
    lines.append("")
    return "\n".join(lines) + "\n"


def init_file(person_label: str) -> str:
    return (
        f"# 1:1 agenda - {person_label}\n\n"
        f"Open talking points Nir wants to raise at the next 1:1 with {person_label}.\n\n"
        "**How to add:** ask Nirvana — the `one-on-one-agenda` skill writes here via `add-item.py`. "
        "IDs auto-increment per file (`ON-NNN`).\n"
        "**How to close:** flip `Status` to `Closed`, add `Closed on` date, move the section to `## Closed`.\n\n"
        "---\n\n"
        "## Open\n\n"
        "_(Empty — open talking points will be inserted here.)_\n\n"
        "---\n\n"
        "## Closed\n\n"
        "_(Empty — closed items will be moved here for history.)_\n"
    )


def strip_open_empty_state(text: str) -> str:
    """Remove the '_(Empty - ...)_' placeholder under '## Open' so the first
    real item lands cleanly. Leaves the file untouched when no placeholder is
    present.
    """
    return OPEN_EMPTY_STATE_RE.sub(r"\1", text, count=1)


def insert_into_open(text: str, section: str) -> str:
    """Insert `section` at the end of the `## Open` block (just before the
    `---` separator preceding `## Closed`). Mirrors `personal-todos`'
    insert_into_open logic.
    """
    if not text.endswith("\n"):
        text += "\n"
    m_open = OPEN_HEADER_RE.search(text)
    m_closed = CLOSED_HEADER_RE.search(text)
    if not m_open or not m_closed or m_closed.start() < m_open.end():
        sys.exit("File shape: cannot find `## Open` followed by `## Closed`.")
    pre = text[: m_closed.start()].rstrip()
    had_sep = pre.endswith("---")
    if had_sep:
        pre = pre[:-3].rstrip()
    suffix = text[m_closed.start():]
    sep_block = "---\n\n" if had_sep else ""
    return f"{pre}\n\n{section.rstrip()}\n\n{sep_block}{suffix}"


def atomic_write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--agenda-file", required=True, type=Path)
    p.add_argument("--person", default="",
                   help="Display label for the person (used when initializing a new file).")
    p.add_argument("--title", required=True)
    p.add_argument("--kind", default="discussion",
                   help="discussion | follow-up (anything starting with 'follow' or 'fu' -> follow-up).")
    p.add_argument("--opened-by", default="Nir")
    p.add_argument("--opened-on", default=date.today().isoformat())
    p.add_argument("--owner", default="TBD")
    p.add_argument("--summary", default="")
    p.add_argument("--why-matters", default="")
    p.add_argument("--next-step", default="")
    p.add_argument("--notes", default="")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the rendered section to stdout; don't write the file.")
    args = p.parse_args(argv)

    if not args.title.strip():
        sys.exit("--title is required and must be non-empty.")

    kind_norm = normalize_kind(args.kind)
    if kind_norm not in VALID_KINDS:
        sys.exit(f"--kind must normalize to one of {sorted(VALID_KINDS)}; got {args.kind!r}.")

    agenda: Path = args.agenda_file
    agenda.parent.mkdir(parents=True, exist_ok=True)

    if not agenda.exists():
        person_label = (args.person or "").strip() or agenda.stem.replace("-", " ").title()
        text = init_file(person_label)
        if not args.dry_run:
            atomic_write(agenda, text)
    else:
        text = agenda.read_text(encoding="utf-8")

    text = strip_open_empty_state(text)

    on_id = next_id(text)
    section = build_section(on_id, args, kind_norm)

    if args.dry_run:
        sys.stdout.write(section)
        sys.stderr.write(f"[dry-run] would assign {on_id} in {agenda}; not writing.\n")
        return 0

    new_text = insert_into_open(text, section)
    atomic_write(agenda, new_text)

    sys.stdout.write(f"{on_id}\t{args.title.strip()}\t{kind_norm}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
