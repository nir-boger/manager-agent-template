"""Parser + mutator for the directs scope board markdown file.

The file at `reports/directs-scope/scope-board.md` is a free-form
markdown doc with one or more GitHub-flavored markdown tables under H2
headings (e.g. ## Open, ## Closed / promoted to ADO). This module
indexes every table cell by (table_index, row_index, col_index) so the
Nirvana Board can perform precise single-cell edits on Nir's behalf
without touching the surrounding prose.

Public API:
    parse_scope_board(text)                                   -> dict
    mutate_scope_board_cell(text, t, r, c, new_value)         -> str
    render_cell_html(raw)                                     -> str

`render_cell_html` is a thin wrapper around the `markdown` package's
inline rendering (matches what nirvana-site/build.py produces). If the
package is unavailable, it falls back to HTML-escaped raw text so the
board still works in stdlib-only mode.

ASCII-only (no smart quotes / em-dashes).
"""
from __future__ import annotations

import html as _html
import re
from typing import Any

try:
    import markdown as _md  # type: ignore[import-untyped]
    _HAS_MD = True
except Exception:  # pragma: no cover - optional dep
    _md = None  # type: ignore[assignment]
    _HAS_MD = False


# --- Regexes -------------------------------------------------------------

# A GFM table separator row: `|---|---|` (optionally with `:` for alignment,
# optionally without leading/trailing pipes). One dash is enough per cell;
# convention in this repo is `---`.
_SEP_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$")

# A line that looks like a table line: starts with optional ws then `|`.
_TABLE_LINE = re.compile(r"^\s*\|")

# H2 heading: matches `## Foo`.
_H2_RE = re.compile(r"^##\s+(.+?)\s*$")


# --- Internal helpers ----------------------------------------------------

def _split_table_row(line: str) -> list[str]:
    """Split a markdown table row into raw cell strings.

    Handles escaped pipes (`\\|`) and strips outer/inner whitespace per
    cell. Leading/trailing `|` are optional in GFM but expected here.
    """
    sentinel = "\x00PIPE\x00"
    s = line.strip()
    s = s.replace(r"\|", sentinel)
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    parts = s.split("|")
    return [p.replace(sentinel, "|").strip() for p in parts]


def _join_table_row(cells: list[str]) -> str:
    """Render cells back into a `| a | b | c |` row.

    Escapes any bare `|` in the cell value (preserving already-escaped
    `\\|` as-is) and collapses embedded whitespace so a row stays on
    one physical line.
    """
    out: list[str] = []
    for c in cells:
        # Protect already-escaped pipes first.
        sentinel = "\x00PIPE\x00"
        c2 = c.replace(r"\|", sentinel)
        c2 = c2.replace("|", r"\|")
        c2 = c2.replace(sentinel, r"\|")
        # Collapse any embedded newlines/tabs/runs of whitespace.
        c2 = c2.replace("\r\n", " ").replace("\n", " ").replace("\t", " ")
        c2 = re.sub(r"\s+", " ", c2).strip()
        out.append(c2)
    return "| " + " | ".join(out) + " |"


def _find_tables(lines: list[str]) -> list[dict[str, Any]]:
    """Return every GFM table found in `lines`.

    Each entry: {heading, header_idx, sep_idx, row_indices}. `heading`
    is the nearest preceding H2 (or "" if none); the indices reference
    line positions in the original `lines` array.
    """
    tables: list[dict[str, Any]] = []
    n = len(lines)
    i = 0
    last_h2 = ""
    while i < n:
        m = _H2_RE.match(lines[i])
        if m:
            last_h2 = m.group(1).strip()
            i += 1
            continue
        if (
            _TABLE_LINE.match(lines[i])
            and i + 1 < n
            and _SEP_RE.match(lines[i + 1])
        ):
            header_idx = i
            sep_idx = i + 1
            row_indices: list[int] = []
            j = i + 2
            while j < n and _TABLE_LINE.match(lines[j]):
                row_indices.append(j)
                j += 1
            tables.append({
                "heading": last_h2,
                "header_idx": header_idx,
                "sep_idx": sep_idx,
                "row_indices": row_indices,
            })
            i = j
            continue
        i += 1
    return tables


# --- Public API ----------------------------------------------------------

def render_cell_html(raw: str) -> str:
    """Render inline markdown for a single table cell as HTML.

    Uses the `markdown` package when available (matches the rendering
    nirvana-site/build.py produces). Strips the outer `<p>...</p>`
    wrapper since cells are inline. Falls back to HTML-escaped raw
    text if `markdown` is not installed.
    """
    if not raw:
        return ""
    if not _HAS_MD:
        return _html.escape(raw, quote=False)
    try:
        html = _md.markdown(
            raw,
            extensions=["tables", "attr_list"],
            output_format="html5",
        )
    except Exception:  # pragma: no cover - defensive
        return _html.escape(raw, quote=False)
    # Strip the wrapping <p> tag(s) for inline contexts.
    s = html.strip()
    if s.startswith("<p>") and s.endswith("</p>") and s.count("<p>") == 1:
        s = s[3:-4]
    return s


def parse_scope_board(text: str) -> dict[str, Any]:
    """Parse the scope board markdown into a structured form.

    Return shape:
        {
          "tables": [
            {
              "heading":  "Open",
              "columns":  ["Direct", "Now", "Next scope"],
              "rows": [
                {"cells": [{"raw": "**Teammate2**", "html": "<strong>Teammate2</strong>"}, ...]},
                ...
              ]
            },
            ...
          ]
        }
    """
    lines = text.splitlines()
    out_tables: list[dict[str, Any]] = []
    for tbl in _find_tables(lines):
        columns = _split_table_row(lines[tbl["header_idx"]])
        rows: list[dict[str, Any]] = []
        for ri in tbl["row_indices"]:
            cells = _split_table_row(lines[ri])
            while len(cells) < len(columns):
                cells.append("")
            cells = cells[: len(columns)]
            rows.append({
                "cells": [
                    {"raw": c, "html": render_cell_html(c)}
                    for c in cells
                ],
            })
        out_tables.append({
            "heading": tbl["heading"],
            "columns": columns,
            "rows": rows,
        })
    return {"tables": out_tables}


def mutate_scope_board_cell(
    text: str,
    table_index: int,
    row_index: int,
    col_index: int,
    new_value: str,
) -> str:
    """Replace one cell in the scope board markdown. Returns the new text.

    Raises ValueError for out-of-range indices or a non-string value.
    Embedded newlines / tabs in `new_value` are collapsed to single
    spaces so the row stays on one physical line.
    """
    if not isinstance(new_value, str):
        raise ValueError("new_value must be a string")
    # Normalise embedded whitespace; we never want a cell to break onto a
    # new physical line (would corrupt the GFM table shape).
    new_value = new_value.replace("\r\n", " ").replace("\n", " ").replace("\t", " ")
    new_value = re.sub(r"\s+", " ", new_value).strip()

    keep_lines = text.splitlines(keepends=True)
    bare_lines = text.splitlines()
    tbls = _find_tables(bare_lines)
    if table_index < 0 or table_index >= len(tbls):
        raise ValueError(
            f"table_index out of range: {table_index} (have {len(tbls)} table(s))"
        )
    tbl = tbls[table_index]
    if row_index < 0 or row_index >= len(tbl["row_indices"]):
        raise ValueError(
            f"row_index out of range: {row_index} (have {len(tbl['row_indices'])} row(s))"
        )
    row_line_idx = tbl["row_indices"][row_index]
    columns = _split_table_row(bare_lines[tbl["header_idx"]])
    if col_index < 0 or col_index >= len(columns):
        raise ValueError(
            f"col_index out of range: {col_index} (have {len(columns)} column(s))"
        )
    cells = _split_table_row(bare_lines[row_line_idx])
    while len(cells) < len(columns):
        cells.append("")
    cells = cells[: len(columns)]
    cells[col_index] = new_value

    new_row_line = _join_table_row(cells)

    original = keep_lines[row_line_idx]
    if original.endswith("\r\n"):
        eol = "\r\n"
    elif original.endswith("\n"):
        eol = "\n"
    else:
        eol = ""
    keep_lines[row_line_idx] = new_row_line + eol
    return "".join(keep_lines)


# --- Small demo (run via `python scope_board_io.py <path>`) -------------

if __name__ == "__main__":  # pragma: no cover - manual smoke
    import json
    import sys
    from pathlib import Path

    if len(sys.argv) < 2:
        print("Usage: python scope_board_io.py <path-to-scope-board.md>")
        sys.exit(2)
    p = Path(sys.argv[1])
    txt = p.read_text(encoding="utf-8")
    parsed = parse_scope_board(txt)
    print(json.dumps(parsed, indent=2))

