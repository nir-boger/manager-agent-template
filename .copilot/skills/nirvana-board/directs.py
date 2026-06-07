"""Resolve the list of Nir's direct reports from the scope-board + personas.

Source of truth for the direct-report set is the FIRST COLUMN of the
``## Open`` table in ``reports/directs-scope/scope-board.md``.

For each direct we:
  * extract the display name from the markdown cell (bold-stripped),
  * derive a kebab-case slug,
  * look up the canonical SMTP address in the matching
    ``.copilot/skills/team-personas/people/<slug>.md`` persona file
    (first ``@microsoft.com`` found in the top ~2500 chars - tolerates the
    several wordings the persona files have evolved through),
  * pull this direct's row from the scope-board (Now + Next scope) so the
    Board's per-direct 1:1 view can render the planning context above the
    open items.

The resolver is intentionally pure (no I/O outside the paths it is given)
and returns plain dicts so serve.py can JSON-serialize it directly.

Public API:
  - ``resolve_directs(scope_md_path, personas_dir)`` -> list[dict]
      Each entry:
          {
            "name":      "Display Name",
            "slug":      "display-name",
            "smtp":      "someone@example.com" | None,
            "scope_now": "raw markdown cell text",
            "scope_next":"raw markdown cell text",
            "scope_now_html":  "<rendered html with bold/italic/code>",
            "scope_next_html": "<rendered html with bold/italic/code>",
          }
  - ``slugify(name)`` -> the same slug we expect in personas/people and
    in reports/one-on-ones/<slug>.md.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# Reuse the scope-board parser so we never duplicate the GFM table logic.
from scope_board_io import parse_scope_board  # noqa: E402

_EMAIL_RE = re.compile(r"([A-Za-z0-9][\w\.\-]*@microsoft\.com)")
_BOLD_STRIP = re.compile(r"^\*\*(.+?)\*\*$")


def slugify(name: str) -> str:
    """Convert a display name to the kebab-case slug used everywhere else.

    Examples
    --------
    >>> slugify("Teammate1")
    'Teammate1-Teammate1'
    >>> slugify("Teammate9")
    'ran-ben-Teammate9'
    """
    s = (name or "").strip().lower()
    # Replace any run of whitespace / punctuation with a single hyphen.
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def _strip_display_name(cell_raw: str) -> str:
    s = (cell_raw or "").strip()
    m = _BOLD_STRIP.match(s)
    if m:
        s = m.group(1)
    return s.strip()


def _extract_smtp(persona_path: Path) -> str | None:
    if not persona_path.exists():
        return None
    try:
        body = persona_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    head = body[:2500]
    m = _EMAIL_RE.search(head)
    return m.group(1) if m else None


def _load_context_smtps(context_json_path: Path) -> dict[str, str]:
    """Load slug -> authoritative SMTP from directs-context.json.

    directs-context.json carries GAL-resolved addresses and is the reliable
    source. The persona-file heuristic in ``_extract_smtp`` is not: it yields
    ``None`` for most directs and can capture the wrong address from prose
    (e.g. Nir's own email), which is a mis-send risk. Defensive on every axis
    - a missing/unreadable/malformed file just yields an empty map.
    """
    try:
        data = json.loads(context_json_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return {}
    directs = data.get("directs")
    if not isinstance(directs, dict):
        return {}
    out: dict[str, str] = {}
    for slug, ctx in directs.items():
        if not isinstance(ctx, dict):
            continue
        smtp = ctx.get("smtp")
        if isinstance(smtp, str) and smtp.strip():
            out[str(slug).strip().lower()] = smtp.strip()
    return out


def resolve_directs(scope_md_path: Path | str,
                    personas_dir: Path | str,
                    context_json_path: Path | str | None = None) -> list[dict]:
    """Resolve the list of directs + their planning context + their smtp.

    Defensive on every axis: a missing scope-board returns []; a missing
    persona file produces ``smtp=None``; a malformed table row is skipped.

    The authoritative SMTP comes from ``directs-context.json`` (GAL-resolved).
    When ``context_json_path`` is not given it defaults to
    ``<scope_md_path dir>/directs-context.json``. The context address OVERRIDES
    the unreliable persona-derived address whenever present; the persona value
    is only a fallback for slugs absent from the context.
    """
    scope_md_path = Path(scope_md_path)
    personas_dir = Path(personas_dir)
    if context_json_path is None:
        context_json_path = scope_md_path.parent / "directs-context.json"
    context_smtps = _load_context_smtps(Path(context_json_path))
    if not scope_md_path.exists():
        return []
    try:
        text = scope_md_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    parsed = parse_scope_board(text)
    if parsed.get("error"):
        return []
    out: list[dict] = []
    seen: set[str] = set()
    for table in parsed.get("tables", []):
        cols = [c.lower() for c in (table.get("columns") or [])]
        # We only consume the Open table - "Closed / promoted to ADO" has
        # been intentionally removed from scope-board.md (2026-05-25).
        if "now" not in cols or "next scope" not in cols:
            continue
        for row in table.get("rows") or []:
            cells = row.get("cells") or []
            if len(cells) < 3:
                continue
            name = _strip_display_name(cells[0].get("raw") or "")
            if not name:
                continue
            slug = slugify(name)
            if slug in seen:
                continue
            seen.add(slug)
            persona = personas_dir / f"{slug}.md"
            # Authoritative context smtp wins; persona heuristic is a fallback.
            smtp = context_smtps.get(slug) or _extract_smtp(persona)
            out.append({
                "name":            name,
                "slug":            slug,
                "smtp":            smtp,
                "scope_now":       (cells[1].get("raw") or "").strip(),
                "scope_next":      (cells[2].get("raw") or "").strip(),
                "scope_now_html":  cells[1].get("html") or "",
                "scope_next_html": cells[2].get("html") or "",
            })
    return out


if __name__ == "__main__":  # pragma: no cover - manual smoke
    import json as _json
    import sys

    repo = Path(__file__).resolve().parents[3]
    scope_md = repo / "reports" / "directs-scope" / "scope-board.md"
    personas = repo / ".copilot" / "skills" / "team-personas" / "people"
    result = resolve_directs(scope_md, personas)
    _json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")

