"""Parser + mutators for `config/sdk-rotation.md`.

The file holds Nir's SDK task round-robin order: a free-form markdown doc
with bullet rules and exactly one GitHub-flavored markdown table under
the `## Current order` heading. This module reuses `scope_board_io`'s
generic GFM table primitives and adds two domain-specific bits:

  - Locate the `Current order` table (heading-based) so the client knows
    which table index is the rotation.
  - Row permutation that auto-renumbers column 0 (the `#` position
    column) to `1..N` after the reorder.

Cell editing on any table in the file goes through
`scope_board_io.mutate_scope_board_cell` directly - it doesn't care which
file the text comes from. We expose a thin alias so callers can stay
on this module's API.

Public API:
    parse_sdk_rotation(text)                                -> dict
    mutate_sdk_rotation_cell(text, t, r, c, new_value)      -> str
    reorder_sdk_rotation_rows(text, new_order)              -> str

ASCII-only (no smart quotes / em-dashes).
"""
from __future__ import annotations

import re
from typing import Any

import scope_board_io as sbio

_ORDER_HEADING_RE = re.compile(r"^current\s+order$", re.IGNORECASE)


def _find_order_table_index(tables: list[dict[str, Any]]) -> int | None:
    for i, t in enumerate(tables or []):
        heading = (t.get("heading") or "").strip()
        if _ORDER_HEADING_RE.match(heading):
            return i
    return None


def parse_sdk_rotation(text: str) -> dict[str, Any]:
    """Return `scope_board_io.parse_scope_board(text)` with one extra key:
    `order_table_index` pointing at the `## Current order` table (or
    `None` when the file shape is unexpected).
    """
    parsed = sbio.parse_scope_board(text)
    parsed["order_table_index"] = _find_order_table_index(parsed.get("tables") or [])
    return parsed


def mutate_sdk_rotation_cell(
    text: str,
    table_index: int,
    row_index: int,
    col_index: int,
    new_value: str,
) -> str:
    """Edit a single cell. Pure delegation to `scope_board_io` - kept
    on this module so callers don't reach across modules for what is
    semantically a `sdk-rotation` operation."""
    return sbio.mutate_scope_board_cell(
        text, table_index, row_index, col_index, new_value
    )


def reorder_sdk_rotation_rows(text: str, new_order: list[int]) -> str:
    """Permute the data rows of the `## Current order` table by
    `new_order` (a list of zero-based original row indices). After the
    permutation, column 0 (the `#` position column) is auto-renumbered
    to `str(i + 1)` for `i` in `0..N-1` so positions stay 1-indexed
    and contiguous.

    Returns the new markdown text. Raises `ValueError` if:
      - there is no `Current order` table,
      - `new_order` is not a list of integers of the right length,
      - `new_order` is not a permutation of `[0..N-1]`.

    Idempotent when `new_order == list(range(N))` AND column 0 already
    holds `1..N` (a no-op write that still touches the file - callers
    can short-circuit if they want to avoid the disk hit).
    """
    parsed = parse_sdk_rotation(text)
    oi = parsed.get("order_table_index")
    if oi is None:
        raise ValueError("no 'Current order' table found in sdk-rotation.md")

    tables_parsed = parsed.get("tables") or []
    if oi >= len(tables_parsed):
        raise ValueError("order_table_index out of range")  # defensive
    rows_parsed = tables_parsed[oi].get("rows") or []
    n = len(rows_parsed)

    if not isinstance(new_order, list):
        raise ValueError("new_order must be a list of integers")
    if not all(isinstance(x, int) for x in new_order):
        raise ValueError("new_order must be a list of integers")
    if len(new_order) != n:
        raise ValueError(
            f"new_order must have exactly {n} entries (got {len(new_order)})"
        )
    if sorted(new_order) != list(range(n)):
        raise ValueError(
            f"new_order must be a permutation of 0..{n - 1}"
        )

    if n == 0:
        return text  # nothing to do

    # Re-locate the table in the line array so we can rewrite row lines
    # in place. `scope_board_io._find_tables` is the same primitive
    # `parse_scope_board` used above, so the layout is guaranteed to
    # match unless the text was mutated concurrently (in which case we
    # bail).
    bare_lines = text.splitlines()
    tables_layout = sbio._find_tables(bare_lines)  # noqa: SLF001 (intentional)
    if oi >= len(tables_layout):
        raise ValueError("table layout changed mid-parse")  # defensive
    row_line_indices = tables_layout[oi]["row_indices"]
    if len(row_line_indices) != n:
        raise ValueError("table row count changed mid-parse")  # defensive

    # Snapshot raw cells per original row BEFORE any rewrite, so the
    # permutation reads from a stable source.
    raw_rows: list[list[str]] = [
        sbio._split_table_row(bare_lines[ri])  # noqa: SLF001
        for ri in row_line_indices
    ]

    keep_lines = text.splitlines(keepends=True)
    for new_i, orig_i in enumerate(new_order):
        cells = list(raw_rows[orig_i])
        if cells:
            cells[0] = str(new_i + 1)
        new_row_line = sbio._join_table_row(cells)  # noqa: SLF001
        original = keep_lines[row_line_indices[new_i]]
        if original.endswith("\r\n"):
            eol = "\r\n"
        elif original.endswith("\n"):
            eol = "\n"
        else:
            eol = ""
        keep_lines[row_line_indices[new_i]] = new_row_line + eol
    return "".join(keep_lines)
