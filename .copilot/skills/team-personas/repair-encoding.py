"""One-time repair for persona files (team-personas/people/*.md).

Two failure modes have accumulated and broken the Nirvana site's sidebar:

1. **Double-encoded UTF-8 mojibake** in the body of every file -- typographic
   chars (em-dash, en-dash, ellipsis) were written through PS5.1's
   cp1252-default console code path and got re-encoded as UTF-8. The bytes
   we see in the files now are the cp1252 interpretation of the original
   UTF-8 bytes, re-encoded as UTF-8. Idempotent fix: byte-level replace the
   3 specific patterns we observed in our 15 persona files.

2. **Drifted H1 titles** -- the documented template at
   `team-personas/SKILL.md:106` says the H1 should be
       `# <Display Name> (<alias>)`
   But Cowork raw drops use 4+ different wordings ("Working-Style Persona:
   X", "X -- Persona", "X -- Working-Style Persona", "X -- Working
   Persona"), and the importer never normalized. After mojibake corrupted
   the em-dashes, the site's `clean_persona_name` regex stopped matching
   the trailing `-- Persona` suffix, so the wrappers leaked into the
   sidebar.

This script reads each `people/*.md`, applies the byte-level mojibake fix,
re-writes the first H1 to the canonical form, and writes back as proper
UTF-8 (with BOM, matching PS5.1's `Set-Content -Encoding UTF8` so the
importer pipeline doesn't churn the encoding on the next round).

Idempotent: rerunning the script on already-clean files is a no-op (the
mojibake byte patterns don't appear in clean UTF-8, and the canonical H1
matches itself).

Usage:
    python .copilot/skills/team-personas/repair-encoding.py
        [--dry-run]    -- print what would change, write nothing
        [--no-bom]     -- write without BOM (default: with BOM to match PS5.1)
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
PEOPLE_DIR = REPO / ".copilot" / "skills" / "team-personas" / "people"

# ---------- Mojibake repair ----------------------------------------------------
#
# Each entry: (mojibake_bytes, canonical_bytes).
# Mojibake = UTF-8 bytes of the cp1252 decoding of the char's original UTF-8.
# Derivation worked example for em-dash (U+2014, UTF-8 = E2 80 94):
#   E2 -> cp1252 'a-circumflex' (U+00E2) -> UTF-8 C3 A2
#   80 -> cp1252 'euro'         (U+20AC) -> UTF-8 E2 82 AC
#   94 -> cp1252 'right-dquote' (U+201D) -> UTF-8 E2 80 9D
# concatenated mojibake = C3 A2 E2 82 AC E2 80 9D.
#
# Observed in current persona files (counted across all 15 files):
#   c3a2 e282ac e2809d -> em-dash       (251 hits)
#   c3a2 e282ac e2809c -> en-dash       ( 80 hits)
#   c3a2 e282ac c2a6   -> ellipsis      (  9 hits)
# Other typographic chars (curly quotes, bullet) included defensively even
# though zero current matches -- belt-and-suspenders against future imports.
MOJIBAKE_FIXES: list[tuple[bytes, bytes]] = [
    (b"\xc3\xa2\xe2\x82\xac\xe2\x80\x9d", "\u2014".encode("utf-8")),  # em-dash
    (b"\xc3\xa2\xe2\x82\xac\xe2\x80\x9c", "\u2013".encode("utf-8")),  # en-dash
    (b"\xc3\xa2\xe2\x82\xac\xc2\xa6",     "\u2026".encode("utf-8")),  # ellipsis
    (b"\xc3\xa2\xe2\x82\xac\xcb\x9c",     "\u2018".encode("utf-8")),  # left single
    (b"\xc3\xa2\xe2\x82\xac\xe2\x84\xa2", "\u2019".encode("utf-8")),  # right single
    (b"\xc3\xa2\xe2\x82\xac\xc5\x93",     "\u201c".encode("utf-8")),  # left double
    (b"\xc3\xa2\xe2\x82\xac\xc2\xa2",     "\u2022".encode("utf-8")),  # bullet
]


def fix_mojibake(data: bytes) -> tuple[bytes, dict[str, int]]:
    counts: dict[str, int] = {}
    for moji, good in MOJIBAKE_FIXES:
        n = data.count(moji)
        if n:
            counts[moji.hex()] = n
            data = data.replace(moji, good)
    return data, counts


# ---------- H1 canonicalization -----------------------------------------------

def alias_to_display(alias: str) -> str:
    """Teammate1-Teammate1 -> 'Teammate1'. Mirrors persona-mining.ps1
    Convert-AliasToDisplayName."""
    parts = [p for p in alias.split("-") if p]
    return " ".join(p[:1].upper() + p[1:].lower() for p in parts)


def canonical_h1(alias: str) -> str:
    return f"# {alias_to_display(alias)} ({alias})"


def rewrite_h1(text: str, alias: str) -> tuple[str, bool]:
    """Replace the first H1 line with the canonical form. If no H1 exists,
    prepend one. Returns (new_text, changed)."""
    canonical = canonical_h1(alias)
    # Find first `# <stuff>` line (single `#`, not `##`+).
    m = re.search(r"^# (?!#)(.*?)$", text, flags=re.M)
    if m:
        if m.group(0) == canonical:
            return text, False
        new = text[: m.start()] + canonical + text[m.end():]
        return new, True
    # No H1 -- prepend one with a blank line.
    return f"{canonical}\n\n{text}", True


# ---------- File walk ----------------------------------------------------------

UTF8_BOM = b"\xef\xbb\xbf"


def repair_file(path: pathlib.Path, *, dry_run: bool, write_bom: bool) -> dict:
    alias = path.stem
    raw = path.read_bytes()
    had_bom = raw.startswith(UTF8_BOM)
    payload = raw[len(UTF8_BOM):] if had_bom else raw

    fixed_bytes, moji_counts = fix_mojibake(payload)

    text = fixed_bytes.decode("utf-8", errors="replace")
    new_text, h1_changed = rewrite_h1(text, alias)

    out_bytes = new_text.encode("utf-8")
    if write_bom:
        out_bytes = UTF8_BOM + out_bytes

    changed = out_bytes != raw
    if changed and not dry_run:
        # Atomic write: tmp -> rename.
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_bytes(out_bytes)
        tmp.replace(path)

    return {
        "alias": alias,
        "moji_fixed": sum(moji_counts.values()),
        "moji_breakdown": moji_counts,
        "h1_changed": h1_changed,
        "had_bom": had_bom,
        "wrote_bom": write_bom and changed,
        "changed": changed,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Repair persona files (mojibake + H1 normalization).")
    ap.add_argument("--dry-run", action="store_true", help="Show what would change; write nothing.")
    ap.add_argument("--no-bom", action="store_true", help="Write UTF-8 without BOM (default: with BOM).")
    args = ap.parse_args()

    if not PEOPLE_DIR.exists():
        print(f"PEOPLE_DIR not found: {PEOPLE_DIR}", file=sys.stderr)
        return 2

    results = []
    for f in sorted(PEOPLE_DIR.glob("*.md")):
        results.append(repair_file(f, dry_run=args.dry_run, write_bom=not args.no_bom))

    total_files = len(results)
    changed = sum(1 for r in results if r["changed"])
    total_moji = sum(r["moji_fixed"] for r in results)
    h1_changes = sum(1 for r in results if r["h1_changed"])

    print(f"\nRepair summary ({'DRY-RUN' if args.dry_run else 'WRITTEN'}):")
    print(f"  files scanned:     {total_files}")
    print(f"  files changed:     {changed}")
    print(f"  mojibake fixed:    {total_moji} byte triplets")
    print(f"  H1 normalized:     {h1_changes} files")
    print()
    for r in results:
        flags = []
        if r["h1_changed"]: flags.append("H1")
        if r["moji_fixed"]: flags.append(f"moji={r['moji_fixed']}")
        if not flags: flags.append("clean")
        print(f"  {r['alias']:25} | {', '.join(flags)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

