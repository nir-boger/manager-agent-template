"""Parse + mutate the three Nirvana board markdown sources.

This module is the read+write half of the `nirvana-board` skill. It must
preserve the file shapes that the existing skills depend on:

- `reports/personal-todos/todos.md`            (PT-NNN, build-daily.py reader)
- `reports/team-agenda/open-discussions.md`    (TA-NNN, team-agenda/render.ps1)
- `reports/one-on-ones/<slug>.md`              (ON-NNN, one per partner)

Adds are NOT done here -- they go through the canonical `add-item.py`
scripts so the proven counter / shape logic is reused. This module owns:

  - parse_todos(text)           -> list[dict]
  - parse_agenda(text)          -> list[dict]
  - parse_one_on_one(text)      -> list[dict]
  - mutate_todo(text, id, op)   -> new text
  - mutate_agenda(text, id, op) -> new text
  - mutate_one_on_one(text, id, op) -> new text
  - atomic_write(path, text)    -> None

Mutations:
  - close   (todos / agenda / 1:1):  flip Status to Done|Closed, add a
    Done-on|Closed-on line, move the section under ## Done|## Closed.
  - snooze  (todos only):            set Snoozed-until to a date.
  - reopen  (todos only):            move back from ## Done to ## Open,
    flip Status to Open, strip the Done-on line.

ASCII-only (no smart quotes, em-dashes only via U+2014 -- matches the
heading character the existing add-item.py writers use).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

# --- Regexes --------------------------------------------------------------

PT_HEADING = re.compile(r"^###\s+(PT-\d{3})\s+\u2014\s+(.+?)\s*$", re.MULTILINE)
TA_HEADING = re.compile(r"^###\s+(TA-\d{3})\s+\u2014\s+(.+?)\s*$", re.MULTILINE)
ON_HEADING = re.compile(r"^###\s+(ON-\d{3})\s+\u2014\s+(.+?)\s*$", re.MULTILINE)
AP_HEADING = re.compile(r"^###\s+(AP-\d{3})\s+\u2014\s+(.+?)\s*$", re.MULTILINE)

H2_OPEN = re.compile(r"^##\s+Open\b", re.MULTILINE)
H2_DONE = re.compile(r"^##\s+Done\b", re.MULTILINE)
H2_CLOSED = re.compile(r"^##\s+Closed\b", re.MULTILINE)

# A field line under a section, e.g. "- **Status:** Open"
FIELD_RE = re.compile(r"^-\s+\*\*([^:*]+?):\*\*\s*(.*?)\s*$", re.MULTILINE)

# Fields that may legitimately carry several display lines. On disk the value
# is stored with REAL line breaks: the `- **Field:** first` line is followed by
# raw continuation lines (no bullet) until the next field / heading / blank line.
# `<br>` is never written. Every line-based reader (the PowerShell agenda parsers,
# build-daily.py, ...) folds those continuation lines back into the value, and
# every HTML surface converts the newlines to `<br>` at render time only.
MULTILINE_FIELDS = {"summary", "why it matters", "next step", "notes"}

# A `<br>`, `<br/>` or `<br />` soft break (case-insensitive). Kept only to
# migrate any legacy value that still carries `<br>` from the old scheme: it is
# decoded to a real newline on read and never re-written.
_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)

# The leading "- **Field:**" marker of a field line (single line match).
_FIELD_HEAD_RE = re.compile(r"^-\s+\*\*([^:*]+?):\*\*\s*(.*?)\s*$")


def encode_multiline(value: Any) -> str:
    """Normalize a possibly multi-line value to REAL newlines (never `<br>`).

    Line endings are normalised to `\n`, any legacy `<br>` is decoded to a
    newline, each line is right-trimmed, and leading / trailing blank lines are
    dropped. An all-blank input yields "". The result is written to disk as a
    field line plus continuation lines.
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


# --- Helpers --------------------------------------------------------------

def _split_sections(text: str, heading_re: re.Pattern[str]) -> list[tuple[str, str, int, int]]:
    """Return a list of (id, title, start_offset, end_offset) for each `### ID`
    section found in text. End offset is the start of the next `### ` heading
    (or `## ` heading, whichever comes first), exclusive.
    """
    matches = list(heading_re.finditer(text))
    if not matches:
        return []
    next_block = re.compile(r"^(?:##\s|###\s)", re.MULTILINE)
    out: list[tuple[str, str, int, int]] = []
    for i, m in enumerate(matches):
        start = m.start()
        # Search for the next ## or ### heading after the END of this heading line.
        # The current heading is itself a ### so we look strictly past it.
        search_from = m.end()
        nxt = next_block.search(text, search_from)
        end = nxt.start() if nxt else len(text)
        out.append((m.group(1), m.group(2).strip(), start, end))
    return out


def _parse_fields(block: str) -> dict[str, str]:
    """Parse the `- **Field:** value` lines in a section block.

    Multi-line fields are read back with real newlines from either storage form:
      - new form  : a single line carrying `<br>` soft breaks, or
      - legacy form: a `- **Field:** first` line followed by raw continuation
        lines (no bullet) until the next field / heading / blank line.
    Single-line fields are returned verbatim (stripped).
    """
    fields: dict[str, str] = {}
    current_key: str | None = None
    parts: list[str] = []

    def _flush() -> None:
        nonlocal current_key, parts
        if current_key is not None:
            joined = "\n".join(parts)
            if current_key in MULTILINE_FIELDS:
                joined = _BR_RE.sub("\n", joined)
            fields[current_key] = joined.strip()
        current_key = None
        parts = []

    for line in block.splitlines():
        m = _FIELD_HEAD_RE.match(line)
        if m:
            _flush()
            current_key = m.group(1).strip().lower()
            parts = [m.group(2).strip()]
            continue
        stripped = line.strip()
        # Continuation lines attach to multi-line fields (raw wrapped lines, no
        # bullet). A heading or `---` rule terminates the value instead.
        if (current_key in MULTILINE_FIELDS and stripped
                and not stripped.startswith("#")
                and not stripped.startswith("---")):
            parts.append(stripped)
        else:
            _flush()
    _flush()
    return fields


def _section_lives_in(text: str, sec_start: int, h2_pattern: re.Pattern[str]) -> bool:
    """True iff sec_start sits after the first match of h2_pattern AND before
    the next other ## heading. Used to decide whether a section is under
    ## Open vs ## Done/Closed."""
    m = h2_pattern.search(text)
    if not m:
        return False
    if sec_start < m.end():
        return False
    # find the next ## heading after this one
    next_h2 = re.compile(r"^##\s", re.MULTILINE).search(text, m.end())
    next_start = next_h2.start() if next_h2 else len(text)
    return sec_start < next_start


def _atomic_write_inner(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(path)


def atomic_write(path: Path, text: str) -> None:
    """Public alias so callers don't have to know the helper name."""
    _atomic_write_inner(path, text)


# --- Parsers --------------------------------------------------------------

def parse_todos(text: str) -> list[dict[str, Any]]:
    """Return list of PT-NNN dicts. Each dict carries id, title, status
    (open|done|snoozed), category, priority, due, recur, snoozed_until,
    notes (raw), and is_overdue (bool, computed from due field against
    today's date).
    """
    out: list[dict[str, Any]] = []
    today = date.today().isoformat()
    for pt_id, title, s, e in _split_sections(text, PT_HEADING):
        block = text[s:e]
        fields = _parse_fields(block)
        status_raw = fields.get("status", "").lower()
        # Open and Done are the canonical values; "snoozed" is implied when
        # Snoozed until != "-".
        snoozed_until = fields.get("snoozed until", "-")
        is_open = status_raw == "open"
        is_done = status_raw == "done"
        status = "done" if is_done else ("snoozed" if (is_open and snoozed_until not in ("", "-")) else "open")
        due = fields.get("due", "-")
        is_overdue = bool(is_open and due not in ("", "-") and due < today)
        out.append({
            "id": pt_id,
            "title": title,
            "status": status,
            "category": fields.get("category", ""),
            "priority": fields.get("priority", ""),
            "created": fields.get("created", ""),
            "due": due,
            "recur": fields.get("recur", "none"),
            "snoozed_until": snoozed_until,
            "done_on": fields.get("done on", ""),
            "notes": fields.get("notes", ""),
            "is_overdue": is_overdue,
        })
    return out


def parse_agenda(text: str) -> list[dict[str, Any]]:
    """Return list of TA-NNN dicts."""
    out: list[dict[str, Any]] = []
    for ta_id, title, s, e in _split_sections(text, TA_HEADING):
        block = text[s:e]
        fields = _parse_fields(block)
        status_raw = fields.get("status", "").lower()
        out.append({
            "id": ta_id,
            "title": title,
            "status": "closed" if status_raw == "closed" else "open",
            "kind": fields.get("kind", ""),
            "opened_by": fields.get("opened by", ""),
            "opened_on": fields.get("opened on", ""),
            "owner": fields.get("owner", ""),
            "summary": fields.get("summary", ""),
            "why_matters": fields.get("why it matters", ""),
            "next_step": fields.get("next step", ""),
            "closed_on": fields.get("closed on", ""),
            "notes": fields.get("notes", ""),
        })
    return out


def parse_ai_plan(text: str) -> list[dict[str, Any]]:
    """Return list of AP-NNN dicts. Same shape as parse_agenda (the AI Plan
    board reuses the team-agenda section format with an AP- id prefix)."""
    out: list[dict[str, Any]] = []
    for ap_id, title, s, e in _split_sections(text, AP_HEADING):
        block = text[s:e]
        fields = _parse_fields(block)
        status_raw = fields.get("status", "").lower()
        out.append({
            "id": ap_id,
            "title": title,
            "status": "closed" if status_raw == "closed" else "open",
            "kind": fields.get("kind", ""),
            "opened_by": fields.get("opened by", ""),
            "opened_on": fields.get("opened on", ""),
            "owner": fields.get("owner", ""),
            "summary": fields.get("summary", ""),
            "why_matters": fields.get("why it matters", ""),
            "next_step": fields.get("next step", ""),
            "closed_on": fields.get("closed on", ""),
            "notes": fields.get("notes", ""),
        })
    return out


def parse_one_on_one(text: str) -> list[dict[str, Any]]:
    """Return list of ON-NNN dicts for a single partner file."""
    out: list[dict[str, Any]] = []
    for on_id, title, s, e in _split_sections(text, ON_HEADING):
        block = text[s:e]
        fields = _parse_fields(block)
        status_raw = fields.get("status", "").lower()
        out.append({
            "id": on_id,
            "title": title,
            "status": "closed" if status_raw == "closed" else "open",
            "kind": fields.get("kind", ""),
            "opened_by": fields.get("opened by", ""),
            "opened_on": fields.get("opened on", ""),
            "owner": fields.get("owner", ""),
            "summary": fields.get("summary", ""),
            "why_matters": fields.get("why it matters", ""),
            "next_step": fields.get("next step", ""),
            "closed_on": fields.get("closed on", ""),
            "notes": fields.get("notes", ""),
        })
    return out


# --- Mutators -------------------------------------------------------------

@dataclass(frozen=True)
class MutateResult:
    text: str
    section_moved: bool
    field_changes: dict[str, str]


def _is_continuation_line(line: str) -> bool:
    """True if `line` is a continuation line of a multi-line field value, i.e.
    not a new field line, not a heading, not a `---` rule, and not blank.
    """
    stripped = line.strip()
    if stripped == "":
        return False
    if stripped.startswith("#") or stripped.startswith("---"):
        return False
    if _FIELD_HEAD_RE.match(line):
        return False
    return True


def _field_block_extent(lines: list[str], head_idx: int) -> int:
    """Given the index of a `- **Field:**` head line, return the index one past
    its continuation lines (the head line plus any raw wrapped lines that belong
    to the same multi-line value).
    """
    j = head_idx + 1
    while j < len(lines) and _is_continuation_line(lines[j]):
        j += 1
    return j


def _value_to_lines(field_name: str, value: str) -> list[str]:
    """Render `- **Field:** ...` as one head line plus continuation lines for
    any embedded newlines in `value`."""
    parts = value.split("\n")
    head = f"- **{field_name}:** {parts[0]}"
    return [head] + parts[1:]


def _replace_field(block: str, field_name: str, new_value: str) -> tuple[str, bool]:
    """Replace the value of the `- **Field:** ...` block, including any existing
    continuation lines. `new_value` may contain real newlines, which are written
    as continuation lines. Returns (new_block, replaced_bool); if the field is
    absent the block is returned unchanged and replaced=False.
    """
    head_re = re.compile(rf"^-\s+\*\*{re.escape(field_name)}:\*\*")
    trailing_nl = block.endswith("\n")
    lines = block.splitlines()
    for i, ln in enumerate(lines):
        if head_re.match(ln):
            j = _field_block_extent(lines, i)
            lines[i:j] = _value_to_lines(field_name, new_value)
            out = "\n".join(lines)
            return (out + "\n" if trailing_nl else out), True
    return block, False


def _insert_field_after(block: str, after_field: str, field_name: str, value: str) -> str:
    """Insert a `- **<field_name>:** <value>` block right after the
    `- **<after_field>:**` block (past its continuation lines). `value` may
    contain real newlines. If `after_field` is missing, append after the last
    field block.
    """
    trailing_nl = block.endswith("\n")
    lines = block.splitlines()
    new_lines = _value_to_lines(field_name, value)
    after_re = re.compile(rf"^-\s+\*\*{re.escape(after_field)}:\*\*")
    for i, ln in enumerate(lines):
        if after_re.match(ln):
            j = _field_block_extent(lines, i)
            lines[j:j] = new_lines
            out = "\n".join(lines)
            return out + "\n" if trailing_nl else out
    # Fallback: append after the last field head (and its continuation lines).
    last_field = -1
    for i, ln in enumerate(lines):
        if FIELD_RE.match(ln):
            last_field = i
    if last_field >= 0:
        j = _field_block_extent(lines, last_field)
        lines[j:j] = new_lines
        out = "\n".join(lines)
        return out + "\n" if trailing_nl else out
    return block + "\n".join(new_lines) + "\n"


def _drop_field(block: str, field_name: str) -> str:
    """Remove the `- **Field:** ...` block including any continuation lines."""
    head_re = re.compile(rf"^-\s+\*\*{re.escape(field_name)}:\*\*")
    trailing_nl = block.endswith("\n")
    lines = block.splitlines()
    for i, ln in enumerate(lines):
        if head_re.match(ln):
            j = _field_block_extent(lines, i)
            del lines[i:j]
            out = "\n".join(lines)
            return out + "\n" if trailing_nl else out
    return block


def _strip_empty_state(text: str, h2_pattern: re.Pattern[str]) -> str:
    """Remove the '_(Empty - ...)_' placeholder right under the named ## heading,
    so a real section can land cleanly. Returns text unchanged if no
    placeholder is present.
    """
    m = h2_pattern.search(text)
    if not m:
        return text
    after = m.end()
    nxt = re.compile(r"^##\s", re.MULTILINE).search(text, after)
    block_end = nxt.start() if nxt else len(text)
    sub = text[after:block_end]
    sub2 = re.sub(r"(\n\n)_\([Ee]mpty[^)]*\)_\s*\n", r"\1", sub, count=1)
    if sub2 == sub:
        return text
    return text[:after] + sub2 + text[block_end:]


def _move_section(
    text: str,
    section_start: int,
    section_end: int,
    target_h2: re.Pattern[str],
) -> str:
    """Cut [section_start:section_end) and append it under the section
    headed by target_h2. Returns the new text.

    Preserves a single blank line between sections and strips the
    `_(Empty ...)_` placeholder if present under the target heading.
    """
    section = text[section_start:section_end].rstrip() + "\n"
    pre = text[:section_start].rstrip()
    post = text[section_end:].lstrip("\n")
    # Re-knit without the section.
    knitted = pre + "\n\n" + post if post else pre + "\n"
    if not knitted.endswith("\n"):
        knitted += "\n"
    # Strip empty-state placeholder under the target.
    knitted = _strip_empty_state(knitted, target_h2)
    m = target_h2.search(knitted)
    if not m:
        # No target heading -- append at end with a heading we don't have:
        # safer to just return knitted unchanged (caller should have ensured
        # the file shape is healthy before calling).
        return knitted
    insert_at = m.end()
    # Ensure exactly one blank line between target heading and the section.
    head = knitted[:insert_at].rstrip() + "\n\n"
    tail = knitted[insert_at:].lstrip("\n")
    # Insert section right after the heading.
    return head + section.rstrip() + "\n\n" + tail


def _find_section(text: str, heading_re: re.Pattern[str], item_id: str) -> tuple[int, int]:
    for tid, _title, s, e in _split_sections(text, heading_re):
        if tid == item_id:
            return s, e
    raise KeyError(item_id)


# Todos -------------------------------------------------------------------

def mutate_todo(text: str, todo_id: str, op: str, *, today: str | None = None,
                snoozed_until: str | None = None) -> str:
    """Apply op to PT-<id> in `text`. Returns the new text.

    op:
      - "close"  : flip Status -> Done, drop Snoozed until, add Done on,
                   move section to ## Done.
      - "snooze" : set Snoozed until = snoozed_until (YYYY-MM-DD or "-").
                   Section stays under ## Open (status remains Open).
      - "reopen" : move back to ## Open, flip Status -> Open, drop Done on.
    """
    today = today or date.today().isoformat()
    s, e = _find_section(text, PT_HEADING, todo_id)
    block = text[s:e].rstrip() + "\n"

    if op == "close":
        block, _ = _replace_field(block, "Status", "Done")
        block, _ = _replace_field(block, "Snoozed until", "-")
        # Add Done on (replace if present, else insert after Recur).
        block2, replaced = _replace_field(block, "Done on", today)
        if not replaced:
            block2 = _insert_field_after(block, "Recur", "Done on", today)
        block = block2
        # Drop Snoozed until line for a tidy Done section (matches existing format).
        block = _drop_field(block, "Snoozed until")
        new_text = text[:s] + block.rstrip() + "\n" + text[e:]
        # Move it to ## Done.
        s2, e2 = _find_section(new_text, PT_HEADING, todo_id)
        return _move_section(new_text, s2, e2, H2_DONE)

    if op == "snooze":
        new_val = (snoozed_until or "-").strip() or "-"
        block, _ = _replace_field(block, "Snoozed until", new_val)
        return text[:s] + block.rstrip() + "\n" + text[e:]

    if op == "reopen":
        block, _ = _replace_field(block, "Status", "Open")
        block = _drop_field(block, "Done on")
        # Make sure Snoozed until is present.
        _, has_snooze = _replace_field(block, "Snoozed until", "-")
        if not has_snooze:
            block = _insert_field_after(block, "Recur", "Snoozed until", "-")
        new_text = text[:s] + block.rstrip() + "\n" + text[e:]
        s2, e2 = _find_section(new_text, PT_HEADING, todo_id)
        return _move_section(new_text, s2, e2, H2_OPEN)

    raise ValueError(f"unknown op: {op!r}")


# Agenda + 1:1 (same shape) ----------------------------------------------

def _mutate_closed_style(text: str, heading_re: re.Pattern[str], item_id: str,
                          op: str, today: str) -> str:
    """Shared close/reopen logic for agenda (TA) and one-on-one (ON) items."""
    s, e = _find_section(text, heading_re, item_id)
    block = text[s:e].rstrip() + "\n"

    if op == "close":
        block, _ = _replace_field(block, "Status", "Closed")
        block2, replaced = _replace_field(block, "Closed on", today)
        if not replaced:
            block2 = _insert_field_after(block, "Status", "Closed on", today)
        block = block2
        new_text = text[:s] + block.rstrip() + "\n" + text[e:]
        s2, e2 = _find_section(new_text, heading_re, item_id)
        return _move_section(new_text, s2, e2, H2_CLOSED)

    if op == "reopen":
        block, _ = _replace_field(block, "Status", "Open")
        block = _drop_field(block, "Closed on")
        new_text = text[:s] + block.rstrip() + "\n" + text[e:]
        s2, e2 = _find_section(new_text, heading_re, item_id)
        return _move_section(new_text, s2, e2, H2_OPEN)

    raise ValueError(f"unknown op: {op!r}")


def mutate_agenda(text: str, ta_id: str, op: str, *, today: str | None = None) -> str:
    today = today or date.today().isoformat()
    return _mutate_closed_style(text, TA_HEADING, ta_id, op, today)


def mutate_ai_plan(text: str, ap_id: str, op: str, *, today: str | None = None) -> str:
    today = today or date.today().isoformat()
    return _mutate_closed_style(text, AP_HEADING, ap_id, op, today)


def mutate_one_on_one(text: str, on_id: str, op: str, *, today: str | None = None) -> str:
    today = today or date.today().isoformat()
    return _mutate_closed_style(text, ON_HEADING, on_id, op, today)


# Field-level edit (mirror of add-item.py shapes, minus the auto-managed
# status/opened-on/closed-on fields which are owned by close/reopen).
_EDITABLE_FIELDS_ON_TA = {
    "title": None,           # special - lives in the H3 heading
    "kind": "Kind",
    "opened_by": "Opened by",
    "owner": "Owner",
    "summary": "Summary",
    "why_matters": "Why it matters",
    "next_step": "Next step",
    "notes": "Notes",
}


def _mutate_edit_closed_style(text: str, heading_re: re.Pattern[str], id_prefix: str,
                              item_id: str, fields: dict[str, str]) -> str:
    """Field-level edit for the TA / ON shapes. Unknown fields raise
    ValueError. Empty string clears the field (drops the line). Title is
    rewritten in the H3 heading line itself.
    """
    unknown = [k for k in fields.keys() if k not in _EDITABLE_FIELDS_ON_TA]
    if unknown:
        raise ValueError(f"unknown editable field(s): {', '.join(sorted(unknown))}")
    s, e = _find_section(text, heading_re, item_id)
    block = text[s:e].rstrip() + "\n"

    # Update H3 title if requested.
    if "title" in fields:
        new_title = (fields["title"] or "").strip()
        if not new_title:
            raise ValueError("title cannot be empty")
        if "\n" in new_title or "\r" in new_title:
            raise ValueError("title cannot contain newlines")
        head_re = re.compile(
            rf"^(###\s+){re.escape(item_id)}(\s+\u2014\s+).+?\s*$",
            re.MULTILINE,
        )
        block, n = head_re.subn(rf"\g<1>{item_id}\g<2>{new_title}", block, count=1)
        if n == 0:  # pragma: no cover - defensive
            raise ValueError(f"could not locate heading for {item_id}")

    # Update / clear non-title fields. Order matters only for new-field
    # insertion stability; use the canonical add-item order so freshly
    # inserted fields land where readers expect them.
    field_order = ["Kind", "Opened by", "Opened on", "Owner",
                   "Summary", "Why it matters", "Next step",
                   "Closed on", "Status", "Notes"]
    for key, raw in fields.items():
        if key == "title":
            continue
        field_label = _EDITABLE_FIELDS_ON_TA[key]
        new_value = "" if raw is None else str(raw)
        if field_label.lower() in MULTILINE_FIELDS:
            # Store real line breaks: a head line plus continuation lines.
            new_value = encode_multiline(new_value)
        else:
            # Single-line field: collapse newlines / tabs to spaces.
            new_value = new_value.replace("\r\n", " ").replace("\n", " ").replace("\t", " ").strip()
        if new_value == "":
            block = _drop_field(block, field_label)
            continue
        new_block, replaced = _replace_field(block, field_label, new_value)
        if replaced:
            block = new_block
            continue
        # Field missing - insert after the closest preceding field that
        # exists, falling back to "Title" (which puts it right under the H3).
        anchors = [f for f in field_order[:field_order.index(field_label)] if f]
        for anchor in reversed(anchors):
            pat = re.compile(rf"(?m)^-\s+\*\*{re.escape(anchor)}:\*\*")
            if pat.search(block):
                block = _insert_field_after(block, anchor, field_label, new_value)
                break
        else:
            block = _insert_field_after(block, "Status", field_label, new_value)

    # Splice block back, preserving the blank-line separator that existed
    # between the original section and whatever comes after it.
    trailing = re.match(r"\s*", text[e:e+8]).group(0) if e < len(text) else ""
    if e < len(text) and "\n\n" not in (text[s:e][-3:] + trailing):
        sep = "\n\n"
    elif e == len(text):
        sep = "\n"
    else:
        sep = "\n\n"
    return text[:s] + block.rstrip() + sep + text[e:].lstrip("\n")


def mutate_agenda_edit(text: str, ta_id: str, fields: dict[str, str]) -> str:
    return _mutate_edit_closed_style(text, TA_HEADING, "TA", ta_id, fields)


def mutate_ai_plan_edit(text: str, ap_id: str, fields: dict[str, str]) -> str:
    return _mutate_edit_closed_style(text, AP_HEADING, "AP", ap_id, fields)


def mutate_one_on_one_edit(text: str, on_id: str, fields: dict[str, str]) -> str:
    return _mutate_edit_closed_style(text, ON_HEADING, "ON", on_id, fields)


# --- Personal notes (free-form text section in a 1:1 file) ---------------
#
# Lives under `## Personal notes` between the file's title and the
# `---` divider that separates the title block from `## Open`. Stored as
# plain markdown so Nir can also edit it directly in any editor.
#
#   # 1:1 with Teammate4
#
#   ## Personal notes
#
#   Burned out from EG. Wants to work with new folks on the team.
#   Mention this in the next 1:1.
#
#   ---
#
#   ## Open
#   ...
#
# parse_personal_notes returns the raw text (stripped). set_personal_notes
# rewrites the section in place; if the section is missing it is inserted
# right after the title (between the `# 1:1 with X` line and the next
# `---`/`## ` heading).

PERSONAL_NOTES_HEADING_RE = re.compile(r"^##\s+Personal notes\s*$", re.MULTILINE)


def parse_personal_notes(text: str) -> str:
    """Return the free-text Personal notes block for a 1:1 file, stripped.
    Returns '' if the section is missing or empty."""
    m = PERSONAL_NOTES_HEADING_RE.search(text)
    if not m:
        return ""
    body_start = m.end()
    # End at the next ## heading or a `---` divider on its own line.
    end_pat = re.compile(r"^(?:##\s|---\s*$)", re.MULTILINE)
    em = end_pat.search(text, body_start)
    body = text[body_start:em.start()] if em else text[body_start:]
    return body.strip()


def set_personal_notes(text: str, new_notes: str) -> str:
    """Rewrite the Personal notes section. Inserts it right after the
    title (before the first `---` divider) if missing.

    Trailing/leading whitespace in new_notes is normalized; empty notes
    are allowed and produce an empty section."""
    body = (new_notes or "").strip()
    block = "## Personal notes\n\n" + (body + "\n\n" if body else "")
    m = PERSONAL_NOTES_HEADING_RE.search(text)
    if m:
        # Replace existing section in place.
        body_start = m.end()
        end_pat = re.compile(r"^(?:##\s|---\s*$)", re.MULTILINE)
        em = end_pat.search(text, body_start)
        sec_end = em.start() if em else len(text)
        return text[:m.start()] + block + text[sec_end:].lstrip("\n")
    # Insert right after the title line (`# 1:1 with X`).  Tolerate a
    # leading UTF-8 BOM and arbitrary leading whitespace before the `#`.
    title_re = re.compile(r"^[\ufeff\s]*#\s.*?$", re.MULTILINE)
    tm = title_re.search(text)
    if tm:
        insert_at = tm.end()
        # Skip any blank line that follows the title so the inserted
        # block sits cleanly without piling up newlines.
        after = text[insert_at:]
        skip = 0
        while skip < len(after) and after[skip] in "\r\n":
            skip += 1
        head = text[:insert_at + skip]
        tail = text[insert_at + skip:]
        if head and not head.endswith("\n"):
            head += "\n"
        return head + "\n" + block + tail
    # No title found - prepend.
    return block + text


# --- Small demo (run via `python markdown_io.py`) ------------------------

if __name__ == "__main__":  # pragma: no cover - manual smoke
    import sys
    if len(sys.argv) < 3:
        print("Usage: python markdown_io.py {todos|agenda|on} <path-to-md>")
        sys.exit(2)
    mode = sys.argv[1]
    p = Path(sys.argv[2])
    text = p.read_text(encoding="utf-8")
    if mode == "todos":
        items = parse_todos(text)
    elif mode == "agenda":
        items = parse_agenda(text)
    elif mode == "on":
        items = parse_one_on_one(text)
    else:
        print(f"unknown mode: {mode}")
        sys.exit(2)
    import json as _json
    print(_json.dumps(items, indent=2))

