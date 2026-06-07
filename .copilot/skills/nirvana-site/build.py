"""Build the Nirvana Explorer single-file HTML site.

Usage:
  python .copilot/skills/nirvana-site/build.py

Output:
  reports/site/nirvana.html
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import markdown
except ImportError:
    print("ERROR: Python 'markdown' package not installed. Run: pip install markdown", file=sys.stderr)
    sys.exit(1)

# Locate repo root: this file lives at <repo>/.copilot/skills/nirvana-site/build.py
HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
OUT_DIR = REPO / "reports" / "site"
OUT_FILE = OUT_DIR / "nirvana.html"
TEMPLATE = HERE.parent / "template.html"

MD_EXTS = ["fenced_code", "tables", "sane_lists", "attr_list", "nl2br"]

# Mapping of skill slug -> (output_subdir under reports/, log_prefix under reports/logs/)
# When skill name doesn't match the reports folder name (e.g. email-team -> reports/email).
SKILL_OUTPUTS = {
    "sprint-create": ("sprint-create", "sprint-create"),
    "sprint-report-daily": ("daily", "daily-summary-import"),
    "pbi-assign-tasks": ("pbi-assign", "pbi-assign"),
    "email-team": ("email", "send-email-from-todo"),
    "post-to-teams": ("teams", None),
    "genz-ask": (None, None),
    "inbox-watch": ("inbox-watch", "inbox-watch"),
    "whatsapp": ("whatsapp", None),
    "kusto-codebase": (None, None),
    "team-personas": (None, "personas-import"),
    "dri-weekly-pulse": ("dri-pulse", "dri-weekly-pulse"),
    "semester-plan-report": ("semester-plan", "semester-plan-report"),
    "nirvana-agent-todos": ("agent-todos", "nirvana-agent-todos"),
    "team-milestones": (None, "team-milestones"),
    "team-agenda": ("team-agenda", "team-agenda-reminder"),
    "one-on-one-agenda": ("one-on-ones", "one-on-one-prep"),
    "reminders": ("reminders", "reminders"),
    "personal-todos": ("personal-todos", "personal-todos"),
    "personal-todos-import": (None, "personal-todos-import"),
    "pilates": ("pilates", None),
    "spouse-or-partner-template": (None, None),
    "pilates-forwarder": ("pilates", None),
}


def parse_powershell_params(ps1_path: Path) -> list[dict]:
    """Best-effort extraction of param(...) block from a .ps1 file."""
    if not ps1_path or not ps1_path.exists():
        return []
    try:
        text = ps1_path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return []
    # Strip comment lines first
    lines = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") and not s.startswith("#region"):
            lines.append("")
        else:
            lines.append(line)
    text = "\n".join(lines)
    m = re.search(r"\bparam\s*\(", text, re.IGNORECASE)
    if not m:
        return []
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    if depth != 0:
        return []
    block = text[start:i-1]
    params = []
    # Split by top-level commas (track bracket/paren depth)
    pieces, buf, pd, bd = [], [], 0, 0
    for c in block:
        if c == "(":
            pd += 1
        elif c == ")":
            pd -= 1
        elif c == "[":
            bd += 1
        elif c == "]":
            bd -= 1
        if c == "," and pd == 0 and bd == 0:
            pieces.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    if buf:
        pieces.append("".join(buf))
    for piece in pieces:
        p = piece.strip()
        if not p:
            continue
        # Extract attributes like [Parameter(...)] and [Type]
        attrs = re.findall(r"\[([^\]]+)\]", p)
        rest = re.sub(r"\[[^\]]+\]", "", p).strip()
        nm = re.search(r"\$(\w+)", rest)
        if not nm:
            continue
        name = nm.group(1)
        default = ""
        eq = re.search(r"\$" + re.escape(name) + r"\s*=\s*(.+?)\s*$", rest, re.DOTALL)
        if eq:
            default = eq.group(1).strip()
        type_hint = ""
        # Heuristic: the last [Foo] before $Name (excluding Parameter/CmdletBinding) is the type
        for a in attrs:
            a_clean = a.strip()
            if a_clean.lower().startswith("parameter") or a_clean.lower().startswith("cmdletbinding") or a_clean.lower().startswith("alias") or a_clean.lower().startswith("validateset"):
                continue
            type_hint = a_clean
        is_switch = type_hint.lower() == "switch"
        is_mandatory = any("mandatory" in a.lower() and "true" in a.lower() for a in attrs)
        params.append({
            "name": name,
            "type": type_hint,
            "default": default,
            "switch": is_switch,
            "mandatory": is_mandatory,
        })
    return params


TEXT_EXTS = {
    ".md", ".txt", ".log", ".json", ".ps1", ".py", ".kql",
    ".csv", ".tsv", ".yaml", ".yml", ".xml", ".config", ".ini", ".cfg",
}
MAX_PREVIEW_BYTES = 60 * 1024  # 60 KB cap per file


def embed_preview(file_path: Path) -> dict:
    ext = file_path.suffix.lower()
    if ext == ".html":
        return {"preview_kind": "skip", "preview_text": "", "preview_html": "", "preview_truncated": False}
    if ext not in TEXT_EXTS:
        return {"preview_kind": "binary", "preview_text": "", "preview_html": "", "preview_truncated": False}
    try:
        raw = file_path.read_bytes()
    except OSError as e:
        return {"preview_kind": "error", "preview_text": f"(read error: {e})", "preview_html": "", "preview_truncated": False}
    truncated = False
    if len(raw) > MAX_PREVIEW_BYTES:
        raw = raw[:MAX_PREVIEW_BYTES]
        truncated = True
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")
    html = render_md(text) if ext == ".md" else ""
    return {
        "preview_kind": "markdown" if ext == ".md" else "text",
        "preview_text": text,
        "preview_html": html,
        "preview_truncated": truncated,
    }


def list_recent(folder: Path, limit: int = 6) -> list[dict]:
    if not folder or not folder.exists():
        return []
    out = []
    try:
        for f in folder.iterdir():
            if not f.is_file():
                continue
            try:
                st = f.stat()
            except OSError:
                continue
            entry = {
                "name": f.name,
                "path": f.relative_to(REPO).as_posix(),
                "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
                "mtime_epoch": st.st_mtime,
            }
            entry.update(embed_preview(f))
            out.append(entry)
    except OSError:
        return []
    out.sort(key=lambda x: x["mtime_epoch"], reverse=True)
    return out[:limit]


def list_recent_logs(log_prefix: str, limit: int = 6) -> list[dict]:
    if not log_prefix:
        return []
    logs_dir = REPO / "reports" / "logs"
    if not logs_dir.exists():
        return []
    out = []
    pat_lower = log_prefix.lower()
    for f in logs_dir.iterdir():
        if not f.is_file():
            continue
        name_lower = f.name.lower()
        if not (name_lower == pat_lower + ".log" or name_lower.startswith(pat_lower + "-") or name_lower.startswith(pat_lower + ".")):
            continue
        try:
            st = f.stat()
        except OSError:
            continue
        entry = {
            "name": f.name,
            "path": f.relative_to(REPO).as_posix(),
            "size": st.st_size,
            "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
            "mtime_epoch": st.st_mtime,
        }
        entry.update(embed_preview(f))
        out.append(entry)
    out.sort(key=lambda x: x["mtime_epoch"], reverse=True)
    return out[:limit]


# ---- Activity feed ----
ACTIVITY_BUCKETS = [
    # (bucket label, glob roots, route-hint function)
    ("Skill",         [".copilot/skills"], "skill"),
    ("Persona",       [".copilot/skills/team-personas/people"], "person"),
    ("Workspace",     ["reports/directs-scope", "reports/team-agenda", "reports/ai-plan", "reports/personal-todos", "reports/reminders"], "workspace"),
    ("Convention",   [".copilot/skills/_shared", "config"], "convention"),
    ("Top-level",     ["."], "toplevel"),
]
ACTIVITY_SKIP_DIRS = {
    ".git", "__pycache__", "node_modules", ".venv",
    "state", "logs", "site", "one-on-ones", "inbox-watch",
    "pr-review-queue", "dri-pulse", "semester-plan", "agent-todos",
    "daily", "estimation", "one-shots", "inputs", "pilates",
    "whatsapp", "teams", "email", "connect-buddy", "tmp",
    "test-fixtures",
}
ACTIVITY_SKIP_EXTS = {".log", ".lock", ".tmp", ".cache", ".xml"}
ACTIVITY_TRACK_EXTS = {".md", ".ps1", ".py", ".json", ".txt", ".html", ".yaml", ".yml", ".vbs"}


def collect_activity(days: int = 7, limit: int = 25) -> list[dict]:
    cutoff = datetime.now().timestamp() - days * 86400
    seen = set()
    items = []

    def bucket_for(path: Path) -> tuple[str, str]:
        rel = path.relative_to(REPO).as_posix()
        if rel.startswith(".copilot/skills/team-personas/people/"):
            return ("Persona", "person")
        if rel.startswith(".copilot/skills/"):
            return ("Skill", "skill")
        if rel.startswith("reports/"):
            return ("Workspace", "workspace")
        if rel.startswith("config/") or rel == "AGENTS.md":
            return ("Convention", "convention")
        return ("Top-level", "toplevel")

    def route_for(path: Path) -> str:
        rel = path.relative_to(REPO).as_posix()
        if rel.startswith(".copilot/skills/team-personas/people/"):
            return "people/" + path.stem
        # SKILL.md inside a skill folder -> route to that skill
        if rel.endswith("/SKILL.md") and rel.startswith(".copilot/skills/"):
            parts = rel.split("/")
            return "skills/" + parts[2]
        # Runner ps1 -> skill route by best-effort
        if rel.startswith(".copilot/skills/run-") and rel.endswith(".ps1"):
            slug = path.stem.replace("run-", "")
            return "skills/" + slug
        # Workspace artifacts that map to known routes
        wsmap = {
            "reports/directs-scope/scope-board.md": "workspace/scope-board",
            "reports/team-agenda/open-discussions.md": "workspace/team-agenda",
            "reports/ai-plan/ai-plan.md": "workspace/ai-plan",
            "reports/personal-todos/todos.md": "workspace/personal-todos",
            "reports/reminders/reminders.md": "workspace/reminders",
            ".copilot/skills/team-personas/ownership-snapshot.md": "workspace/ownership-snapshot",
        }
        if rel in wsmap:
            return wsmap[rel]
        return ""

    def walk(start: Path):
        if not start.exists():
            return
        for child in start.iterdir():
            name = child.name
            # Skip dot-prefixed dirs/files except the well-known ones
            if name.startswith(".") and name not in (".gitignore", ".copilot"):
                continue
            if child.is_dir():
                if name in ACTIVITY_SKIP_DIRS:
                    continue
                walk(child)
                continue
            if not child.is_file():
                continue
            ext = child.suffix.lower()
            if ext in ACTIVITY_SKIP_EXTS:
                continue
            if ext and ext not in ACTIVITY_TRACK_EXTS:
                continue
            try:
                st = child.stat()
            except OSError:
                continue
            if st.st_mtime < cutoff:
                continue
            rp = child.relative_to(REPO).as_posix()
            if rp in seen:
                continue
            seen.add(rp)
            bucket, kind = bucket_for(child)
            items.append({
                "path": rp,
                "bucket": bucket,
                "kind": kind,
                "route": route_for(child),
                "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
                "mtime_epoch": st.st_mtime,
            })

    walk(REPO)
    items.sort(key=lambda x: x["mtime_epoch"], reverse=True)
    items = items[:limit]
    # Embed preview content for clickable rows that don't have a route
    for it in items:
        if not it["route"]:
            it.update(embed_preview(REPO / it["path"]))
    return items


def render_md(text: str) -> str:
    if not text:
        return ""
    return markdown.markdown(text, extensions=MD_EXTS, output_format="html5")


def read_text(rel: str | Path) -> str:
    p = Path(rel)
    if not p.is_absolute():
        p = REPO / p
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


def md_file(rel: str | Path) -> str:
    return render_md(read_text(rel))


def strip_first_h1(raw: str) -> tuple[str, str]:
    """Return (title, body) — title is first H1, body is the rest."""
    m = re.search(r"^#\s+(.+?)\s*$", raw, flags=re.MULTILINE)
    if not m:
        return ("", raw)
    title = m.group(1).strip()
    body = raw[: m.start()] + raw[m.end():]
    return (title, body)


def load_skills() -> list[dict]:
    raw = json.loads((REPO / "config" / "skills.json").read_text(encoding="utf-8"))
    out = []
    for s in raw["skills"]:
        path = REPO / s["path"] / "SKILL.md"
        md_raw = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
        slug = s["name"]
        # Resolve outputs folder + log prefix
        folder_name, log_prefix = SKILL_OUTPUTS.get(slug, (slug, slug))
        out_folder = REPO / "reports" / folder_name if folder_name else None
        recent_files = list_recent(out_folder) if out_folder else []
        recent_logs = list_recent_logs(log_prefix) if log_prefix else []
        # Params from entrypoint
        params = []
        ep_rel = s.get("entrypoint_path")
        ep_abs = REPO / ep_rel if ep_rel else None
        if ep_abs and ep_abs.exists():
            params = parse_powershell_params(ep_abs)
        # Rules docs (DM review rules, etc.) -- any *.md under <skill_path>/rules/
        rules_docs = []
        rules_dir = REPO / s["path"] / "rules"
        if rules_dir.is_dir():
            for rf in sorted(rules_dir.glob("*.md")):
                try:
                    rtext = rf.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                rtitle, rbody = strip_first_h1(rtext)
                rules_docs.append({
                    "path": rf.relative_to(REPO).as_posix(),
                    "name": rf.name,
                    "title": rtitle or rf.stem,
                    "html": render_md(rbody if rtitle else rtext),
                    "raw_len": len(rtext),
                })
        out.append({
            "name": s["name"],
            "slug": slug,
            "category": s.get("category", "misc"),
            "role": s.get("role", "misc"),
            "surface": s.get("surface", ""),
            "path": s["path"],
            "entrypoint_path": ep_rel or "",
            "triggers": s.get("triggers", []),
            "show_in_agents": s.get("show_in_agents", True),
            "ship_in_snapshot": s.get("ship_in_snapshot", False),
            "status": s.get("status", ""),
            "status_note": s.get("status_note", ""),
            "summary": s.get("summary", ""),
            "html": render_md(md_raw),
            "raw_len": len(md_raw),
            "params": params,
            "outputs_folder": (out_folder.relative_to(REPO).as_posix() if (out_folder and out_folder.exists()) else ""),
            "recent_files": recent_files,
            "recent_logs": recent_logs,
            "rules_docs": rules_docs,
        })
    return out


def clean_persona_name(raw: str, slug: str) -> str:
    """Normalize persona display name for the sidebar. The documented template
    in team-personas/SKILL.md:106 is `# <Display Name> (<alias>)`, and the
    importer pipeline now enforces it on every write (Set-CanonicalPersonaH1
    in persona-mining.ps1). This function is the site's belt-and-suspenders
    guard against drift: strips the documented `(<alias>)` parenthetical plus
    legacy wrappers ("Working-Style Persona:", "— Persona") that lived in
    older drops. Also tolerates the double-encoded em-dash mojibake (`â€"`
    byte sequence) so a partially-repaired file still renders cleanly."""
    name = (raw or "").strip()
    # Mojibake em-dash: `â€"` (U+00E2 U+20AC U+201D) is what an em-dash
    # becomes when UTF-8 is decoded as cp1252 then re-encoded as UTF-8.
    moji_emdash = "\u00e2\u20ac\u201d"
    moji_endash = "\u00e2\u20ac\u201c"
    dash_class = r"[\u2014\u2013\-]+|" + re.escape(moji_emdash) + r"|" + re.escape(moji_endash)
    # Leading: "Working-Style Persona:", "Persona:", "Working Persona -", ...
    name = re.sub(
        r"^(?:Working[\-\s]Style\s+|Working\s+)?Persona\s*(?:[:\u2014\-]|" + re.escape(moji_emdash) + r"|" + re.escape(moji_endash) + r")\s*",
        "",
        name,
        flags=re.IGNORECASE,
    )
    # Trailing: " — Persona", " — Working-Style Persona", " - Working Persona", mojibake variants.
    name = re.sub(
        r"\s*(?:" + dash_class + r")\s*(?:Working[\-\s]Style\s+|Working\s+)?Persona\s*$",
        "",
        name,
        flags=re.IGNORECASE,
    )
    # Trailing "(<alias>)" parenthetical (current canonical form per SKILL.md:106).
    name = re.sub(r"\s*\(\s*" + re.escape(slug) + r"\s*\)\s*$", "", name, flags=re.IGNORECASE)
    name = name.strip()
    if not name:
        return slug.replace("-", " ").title()
    return name


def load_personas() -> list[dict]:
    people_dir = REPO / ".copilot" / "skills" / "team-personas" / "people"
    out = []
    if not people_dir.exists():
        return out
    for f in sorted(people_dir.glob("*.md")):
        raw = f.read_text(encoding="utf-8", errors="replace")
        title, _ = strip_first_h1(raw)
        out.append({
            "slug": f.stem,
            "name": clean_persona_name(title, f.stem),
            "html": render_md(raw),
            "is_nirvana": f.stem == "nirvana",
        })
    return out


def load_workspace() -> dict:
    items = {
        "scope-board": ("Directs Scope Board", "reports/directs-scope/scope-board.md"),
        "team-agenda": ("Team Agenda", "reports/team-agenda/open-discussions.md"),
        "ai-plan": ("AI Plan", "reports/ai-plan/ai-plan.md"),
        "personal-todos": ("Personal Todos", "reports/personal-todos/todos.md"),
        "reminders": ("Reminders", "reports/reminders/reminders.md"),
        "sdk-rotation": ("SDK rotation", "config/sdk-rotation.md"),
        "ownership-snapshot": ("Ownership Snapshot", ".copilot/skills/team-personas/ownership-snapshot.md"),
    }
    out = {}
    for slug, (label, rel) in items.items():
        out[slug] = {"label": label, "path": rel, "html": md_file(rel)}
    # one-on-ones (individual files)
    one_dir = REPO / "reports" / "one-on-ones"
    one_list = []
    if one_dir.exists():
        for f in sorted(one_dir.glob("*.md")):
            one_list.append({
                "slug": f.stem,
                "label": f.stem.replace("-", " ").title(),
                "path": f.relative_to(REPO).as_posix(),
                "html": render_md(f.read_text(encoding="utf-8", errors="replace")),
            })
    out["one-on-ones"] = one_list
    return out


def load_conventions() -> dict:
    return {
        "voice": {"label": "Voice", "html": md_file("config/voice.md")},
        "joke-playbook": {"label": "Joke playbook", "html": md_file(".copilot/skills/_shared/joke-playbook.md")},
        "signature": {"label": "Signature", "html": md_file(".copilot/skills/_shared/signature.md")},
        "whatsapp-profiles": {"label": "WhatsApp profiles", "html": md_file("config/whatsapp-profiles.md")},
        "agents-md": {"label": "AGENTS.md", "html": md_file("AGENTS.md")},
    }


def load_scheduled_tasks() -> list[dict]:
    if sys.platform != "win32":
        return []
    ps = r"""
$ErrorActionPreference = 'SilentlyContinue'
Get-ScheduledTask -TaskName 'DM-*' | ForEach-Object {
  $t = $_
  $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
  $action = ($t.Actions | Select-Object -First 1)
  $args = ''
  if ($action -and $action.PSObject.Properties['Arguments']) { $args = $action.Arguments }
  $exec = ''
  if ($action -and $action.PSObject.Properties['Execute']) { $exec = $action.Execute }
  $trigDesc = @()
  foreach ($tr in $t.Triggers) {
    $kind = $tr.CimClass.CimClassName
    $at = $tr.StartBoundary
    $rep = ''
    if ($tr.Repetition -and $tr.Repetition.Interval) { $rep = " repeat=$($tr.Repetition.Interval)" }
    $trigDesc += "$kind @ $at$rep"
  }
  [PSCustomObject]@{
    Name        = $t.TaskName
    State       = "$($t.State)"
    Description = $t.Description
    Execute     = $exec
    Arguments   = $args
    NextRun     = if ($info.NextRunTime) { $info.NextRunTime.ToString('o') } else { '' }
    LastRun     = if ($info.LastRunTime) { $info.LastRunTime.ToString('o') } else { '' }
    LastResult  = $info.LastTaskResult
    Triggers    = ($trigDesc -join ' | ')
  }
} | ConvertTo-Json -Depth 4
"""
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
            capture_output=True, text=True, timeout=60,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return []
        data = json.loads(r.stdout)
        if isinstance(data, dict):
            data = [data]
        # Sort by name
        data.sort(key=lambda x: x.get("Name", ""))
        return data
    except Exception as e:
        print(f"warn: could not enumerate scheduled tasks: {e}", file=sys.stderr)
        return []


CATEGORY_ORDER = [
    ("sprint-pbis", "Sprint & PBIs"),
    ("comms", "Comms"),
    ("codebase-people", "Codebase & people"),
    ("reviews-dri", "Reviews & DRI"),
    ("cadence-memory", "Cadence & memory"),
    ("private-work-tools", "Private work tools"),
    ("personal-life", "Personal life"),
    ("hidden", "Hidden / internal"),
    ("misc", "Misc"),
]


# Higher-level role-agents. Each tuple is (id, label, blurb). The Nirvana
# Explorer groups skills by role; `role` per skill comes from config/skills.json.
ROLE_ORDER = [
    ("chief-of-staff", "Chief of Staff", "Cadence, memory & personal throughput \u2014 todos, reminders, agendas, milestones, the site itself."),
    ("sprint-delivery", "Sprint & Delivery", "ADO planning & status \u2014 sprints, PBIs, the semester plan."),
    ("reliability-dri", "Reliability / DRI", "Incidents, PR reviews & telemetry \u2014 what's on fire and why."),
    ("code-knowledge", "Code & Knowledge", "Codebase, code changes & people knowledge."),
    ("comms-agent", "Comms", "Inbound & outbound messaging \u2014 email, Teams, WhatsApp, inbox triage."),
    ("personal-life", "Personal Life", "Off-work helpers."),
    ("misc", "Misc", ""),
]


def build() -> Path:
    skills = load_skills()
    personas = load_personas()
    workspace = load_workspace()
    conventions = load_conventions()
    tasks = load_scheduled_tasks()

    # Stats
    stats = {
        "skills_total": len(skills),
        "skills_visible": sum(1 for s in skills if s["show_in_agents"]),
        "directs": sum(1 for p in personas if not p["is_nirvana"]),
        "personas_total": len(personas),
        "scheduled_tasks": len(tasks),
        "built_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "repo_root": str(REPO),
    }

    data = {
        "stats": stats,
        "skills": skills,
        "personas": personas,
        "workspace": workspace,
        "conventions": conventions,
        "scheduled_tasks": tasks,
        "category_order": CATEGORY_ORDER,
        "role_order": ROLE_ORDER,
        "activity": collect_activity(days=7, limit=25),
    }

    template_text = TEMPLATE.read_text(encoding="utf-8")
    payload = json.dumps(data, ensure_ascii=False)
    # Escape any </ sequences so embedded log content can't terminate the
    # surrounding <script> tag. "<\/" is legal JSON (slash escape).
    payload = payload.replace("</", "<\\/")
    # Use a safe replace token
    html = template_text.replace("/*__NIRVANA_DATA__*/", payload)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text(html, encoding="utf-8")
    return OUT_FILE


if __name__ == "__main__":
    out = build()
    size = out.stat().st_size
    print(f"Wrote {out} ({size/1024:.1f} KB)")

