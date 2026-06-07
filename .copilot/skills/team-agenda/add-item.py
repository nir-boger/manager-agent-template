#!/usr/bin/env python3
"""Atomically append a new TA-NNN row to reports/team-agenda/open-discussions.md.

Single source of truth for `team-agenda` add-item mode. Mirrors the shape of
`personal-todos/add-item.py` (PT-NNN) and `one-on-one-agenda/add-item.py`
(ON-NNN) so the three skills stay maintained by the same pattern.

Outputs one TSV line to stdout on success:

    TA-NNN<TAB>title<TAB>kind
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path

HEADING_ID_RE = re.compile(r"^###\s+TA-(\d{3})\b", flags=re.MULTILINE)
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


def next_id(text: str, prefix: str = "TA") -> str:
    heading_re = re.compile(rf"^###\s+{re.escape(prefix)}-(\d{{3}})\b", flags=re.MULTILINE)
    nums = [int(n) for n in heading_re.findall(text)]
    n = max(nums, default=0) + 1
    if n > 999:
        sys.exit(f"{prefix}-NNN counter exhausted (>999).")
    return f"{prefix}-{n:03d}"


def normalize_kind(raw: str) -> str:
    s = (raw or "").strip().lower().replace("_", "-")
    if s.startswith("follow") or s == "fu":
        return "follow-up"
    return "discussion"


def display_kind(norm: str) -> str:
    return "Follow-up" if norm == "follow-up" else "Discussion"


def build_section(ta_id: str, args: argparse.Namespace, kind_norm: str) -> str:
    kind = display_kind(kind_norm)
    lines = [
        f"### {ta_id} \u2014 {args.title.strip()}",
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


def strip_open_empty_state(text: str) -> str:
    return OPEN_EMPTY_STATE_RE.sub(r"\1", text, count=1)


def insert_into_open(text: str, section: str) -> str:
    """Insert `section` at the end of the `## Open` block (just before the
    `---` separator preceding `## Closed`). Mirrors the PT/ON helpers."""
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
    p.add_argument("--id-prefix", default="TA",
                   help="Item id prefix (e.g. TA for team-agenda, AP for the AI Plan board).")
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

    prefix = (args.id_prefix or "TA").strip().upper()
    if not re.fullmatch(r"[A-Z]{2,4}", prefix):
        sys.exit(f"--id-prefix must be 2-4 letters; got {args.id_prefix!r}.")

    kind_norm = normalize_kind(args.kind)
    if kind_norm not in VALID_KINDS:
        sys.exit(f"--kind must normalize to one of {sorted(VALID_KINDS)}; got {args.kind!r}.")

    agenda: Path = args.agenda_file
    if not agenda.exists():
        sys.exit(f"agenda file does not exist: {agenda}")

    text = agenda.read_text(encoding="utf-8")
    text = strip_open_empty_state(text)
    ta_id = next_id(text, prefix)
    section = build_section(ta_id, args, kind_norm)

    if args.dry_run:
        sys.stdout.write(section)
        sys.stderr.write(f"[dry-run] would assign {ta_id} in {agenda}; not writing.\n")
        return 0

    new_text = insert_into_open(text, section)
    atomic_write(agenda, new_text)

    sys.stdout.write(f"{ta_id}\t{args.title.strip()}\t{kind_norm}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
