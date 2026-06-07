#!/usr/bin/env python3
"""Atomically append a new RK-NNN risk to reports/risks/register.md.

Single source of truth for `risk-watch` add-item mode. Mirrors the shape of
`team-agenda/add-item.py` (TA-NNN) and `personal-todos/add-item.py` (PT-NNN)
so the tracker skills stay maintained by the same pattern.

`Status` is the lifecycle field (always Open on add). `Risk` is the RAG level
(Red / Amber / Green). Outputs one TSV line to stdout on success:

    RK-NNN<TAB>title<TAB>rag
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path

OPEN_HEADER_RE = re.compile(r"^##\s+Open\b", flags=re.MULTILINE)
CLOSED_HEADER_RE = re.compile(r"^##\s+Closed\b", flags=re.MULTILINE)
OPEN_EMPTY_STATE_RE = re.compile(
    r"(^##\s+Open\s*\n\n)_\(Empty[^)]*\)_\s*\n",
    flags=re.MULTILINE,
)

VALID_RAGS = {"red", "amber", "green"}

_BR_RE = re.compile(r"<br\s*/?>", flags=re.IGNORECASE)


def encode_multiline(value: str) -> str:
    """Normalize a possibly multi-line value to REAL newlines (never `<br>`).
    Trims leading / trailing blank lines; all-blank -> "".
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


def next_id(text: str, prefix: str = "RK") -> str:
    heading_re = re.compile(rf"^###\s+{re.escape(prefix)}-(\d{{3}})\b", flags=re.MULTILINE)
    nums = [int(n) for n in heading_re.findall(text)]
    n = max(nums, default=0) + 1
    if n > 999:
        sys.exit(f"{prefix}-NNN counter exhausted (>999).")
    return f"{prefix}-{n:03d}"


def normalize_rag(raw: str) -> str:
    s = (raw or "").strip().lower()
    if s in ("r", "red"):
        return "red"
    if s in ("a", "amber", "y", "yellow"):
        return "amber"
    if s in ("g", "green"):
        return "green"
    return s


def display_rag(norm: str) -> str:
    return {"red": "Red", "amber": "Amber", "green": "Green"}.get(norm, "Amber")


def build_section(rk_id: str, args: argparse.Namespace, rag_norm: str) -> str:
    rag = display_rag(rag_norm)
    lines = [
        f"### {rk_id} \u2014 {args.title.strip()}",
        "",
        "- **Status:** Open",
        f"- **Risk:** {rag}",
        f"- **Area:** {(args.area or 'TBD').strip() or 'TBD'}",
        f"- **Owner:** {(args.owner or 'TBD').strip() or 'TBD'}",
        f"- **Opened on:** {args.opened_on}",
        f"- **Why at risk:** {encode_multiline(args.why) or '-'}",
        f"- **Mitigation:** {encode_multiline(args.mitigation) or '-'}",
        f"- **Next checkpoint:** {(args.checkpoint or '-').strip() or '-'}",
        f"- **Linked ADO:** {(args.linked_ado or '-').strip() or '-'}",
        f"- **Notes:** {encode_multiline(args.notes) or '-'}",
        "",
    ]
    return "\n".join(lines) + "\n"


def strip_open_empty_state(text: str) -> str:
    return OPEN_EMPTY_STATE_RE.sub(r"\1", text, count=1)


def insert_into_open(text: str, section: str) -> str:
    """Insert `section` at the end of the `## Open` block (just before the
    `---` separator preceding `## Closed`). Mirrors the TA/PT helpers."""
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
    p.add_argument("--register-file", required=True, type=Path)
    p.add_argument("--id-prefix", default="RK",
                   help="Item id prefix (default RK).")
    p.add_argument("--title", required=True)
    p.add_argument("--rag", default="amber",
                   help="red | amber | green (r/a/g, yellow->amber accepted).")
    p.add_argument("--area", default="TBD")
    p.add_argument("--owner", default="TBD")
    p.add_argument("--opened-on", default=date.today().isoformat())
    p.add_argument("--why", default="")
    p.add_argument("--mitigation", default="")
    p.add_argument("--checkpoint", default="-",
                   help="Next checkpoint date (YYYY-MM-DD) or '-'.")
    p.add_argument("--linked-ado", default="-")
    p.add_argument("--notes", default="")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the rendered section to stdout; don't write the file.")
    args = p.parse_args(argv)

    if not args.title.strip():
        sys.exit("--title is required and must be non-empty.")

    prefix = (args.id_prefix or "RK").strip().upper()
    if not re.fullmatch(r"[A-Z]{2,4}", prefix):
        sys.exit(f"--id-prefix must be 2-4 letters; got {args.id_prefix!r}.")

    rag_norm = normalize_rag(args.rag)
    if rag_norm not in VALID_RAGS:
        sys.exit(f"--rag must normalize to one of {sorted(VALID_RAGS)}; got {args.rag!r}.")

    register: Path = args.register_file
    if not register.exists():
        sys.exit(f"register file does not exist: {register}")

    text = register.read_text(encoding="utf-8")
    text = strip_open_empty_state(text)
    rk_id = next_id(text, prefix)
    section = build_section(rk_id, args, rag_norm)

    if args.dry_run:
        sys.stdout.write(section)
        sys.stderr.write(f"[dry-run] would assign {rk_id} in {register}; not writing.\n")
        return 0

    new_text = insert_into_open(text, section)
    atomic_write(register, new_text)

    sys.stdout.write(f"{rk_id}\t{args.title.strip()}\t{rag_norm}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
