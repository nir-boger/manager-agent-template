"""Build the DM Semester Plan progress dashboard (single-file HTML).

v3 (2026-05-17): answers A Peer's two asks
- Capacity & Pace section: 212.75 PW budget vs 216 PW commit, person-weeks
  delivered/in-flight vs elapsed-time target. Per-Feature pace chip on
  Active features.
- "What changed since last refresh" panel: snapshot diff against the
  newest prior state/snapshots/YYYY-MM-DD.json. Empty on first run after
  deployment, meaningful from the next run onward.
- Snapshots state/all-items.json -> state/snapshots/YYYY-MM-DD.json at
  end of build so the next run has a baseline.

v2 (2026-05-14):
- Feature + PBI level only (Tasks/Bugs no longer surfaced)
- Adds Semester Pulse intro: Apr 1 -> Sep 30 window, time-elapsed vs PBI-done

Reads (all relative to this script's folder):
  nir-sheet.json            -- snapshot of the 'Nir' sheet from Your Manager's planning xlsx
  feature-ids.json          -- 27 Features above cutline with per-Feature pweeks
  state/link-tree.json      -- WIQL recursive hierarchy result (refreshed each run)
  state/all-items.json      -- ADO work items batch fetch (refreshed each run)
  state/snapshots/*.json    -- prior run snapshots (used for the diff panel)

Writes:
  state/dashboard.html      -- self-contained Clawpilot-themed dashboard
                               (override with env SEMESTER_PLAN_OUT)
  state/snapshots/<today>.json -- new snapshot for next run's diff
"""
import json
import re
import os
import sys
import shutil
import html as html_lib
from datetime import datetime, date
from pathlib import Path

SKILL = Path(__file__).resolve().parent
INPUTS = SKILL
STATE  = SKILL / "state"
STATE.mkdir(exist_ok=True)
OUT = Path(os.environ.get("SEMESTER_PLAN_OUT", str(STATE / "dashboard.html")))

SEMESTER_START = date(2026, 4, 1)
SEMESTER_END   = date(2026, 9, 30)

# ---- Load ----
sheet = json.loads((INPUTS / "nir-sheet.json").read_text(encoding="utf-8-sig"))
tree  = json.loads((STATE  / "link-tree.json").read_text(encoding="utf-8-sig"))
items = json.loads((STATE  / "all-items.json").read_text(encoding="utf-8-sig"))

# row -> sheet record
sheet_by_id = {}
cutline_row = None
for r in sheet:
    url = r.get("_ado_url", "") or ""
    m = re.search(r"/edit/(\d+)", url)
    if m:
        sheet_by_id[int(m.group(1))] = r
    if r.get("Area") == "CUTLINE":
        cutline_row = int(r["row"])

# wi by id
wi = {}
for it in items:
    f = it.get("fields", {})
    wi[int(f["System.Id"])] = {
        "id":         int(f["System.Id"]),
        "title":      f.get("System.Title", ""),
        "type":       f.get("System.WorkItemType", ""),
        "state":      f.get("System.State", ""),
        "assigned":   f.get("System.AssignedTo", ""),
        "area":       f.get("System.AreaPath", ""),
        "iter":       f.get("System.IterationPath", ""),
        "tags":       f.get("System.Tags", ""),
        "parent":     f.get("System.Parent", 0),
        "priority":   f.get("Microsoft.VSTS.Common.Priority", None),
    }

# parents map (parent_id -> [child_id, ...]) from link tree
parents = {int(k): [int(v) for v in vs] for k, vs in tree["parents"].items()}

# ---- Constants ----
FEATURE_IDS_ORDER = [
    34335261, 37265107, 34858688, 37264564, 37264663, 37264685, 37319892, 34335365,
    37264824, 37264849, 34334152, 37264926, 37264945, 37264965, 34665000, 37211984,
    37133013, 34334664, 36465576, 37265175, 37265196, 37319898, 37265215, 34334177,
    37265080, 37265004, 36457067,
]

# ADO state buckets — we map raw states to a 4-bucket UX
def task_bucket(state):
    s = (state or "").lower()
    if s in ("done", "closed", "resolved", "completed"): return "done"
    if s in ("in progress", "active"): return "active"
    if s in ("in review", "code review"): return "review"
    if s in ("removed", "cut"): return "removed"
    return "todo"  # New, To Do, Approved, Committed, Proposed

def pbi_bucket(state):
    s = (state or "").lower()
    if s in ("done", "closed", "completed"): return "done"
    if s in ("active", "in progress", "committed"): return "active"
    if s in ("approved",): return "approved"
    if s in ("removed",): return "removed"
    return "new"

# ---- Walk per Feature ----
def collect(feature_id):
    """Return dict with PBIs, Tasks, Bugs, aggregates."""
    pbis = []
    tasks = []
    bugs = []
    stack = [feature_id]
    seen = set([feature_id])
    while stack:
        cur = stack.pop()
        for child in parents.get(cur, []):
            if child in seen: continue
            seen.add(child)
            stack.append(child)
            c = wi.get(child)
            if not c: continue
            t = c["type"]
            if t == "Product Backlog Item":
                pbis.append(c)
            elif t == "Task":
                tasks.append(c)
            elif t == "Bug":
                bugs.append(c)
    return pbis, tasks, bugs

def short_name(assigned):
    if not assigned:
        return ""
    if isinstance(assigned, dict):
        return assigned.get("displayName") or assigned.get("uniqueName") or ""
    m = re.match(r"(.+?)\s*<", str(assigned))
    return (m.group(1) if m else str(assigned)).strip()

# ---- Build feature records ----
features = []
for fid in FEATURE_IDS_ORDER:
    feat_wi = wi.get(fid, {})
    sheet_row = sheet_by_id.get(fid, {})
    pbis, tasks, bugs = collect(fid)

    task_units = tasks + bugs  # retained for under-the-hood sprint detection only
    task_buckets = {"todo": 0, "active": 0, "review": 0, "done": 0, "removed": 0}
    for t in task_units:
        task_buckets[task_bucket(t["state"])] += 1
    pbi_buckets = {"new": 0, "approved": 0, "active": 0, "done": 0, "removed": 0}
    for p in pbis:
        pbi_buckets[pbi_bucket(p["state"])] += 1

    total_pbis_active = pbi_buckets["new"] + pbi_buckets["approved"] + pbi_buckets["active"] + pbi_buckets["done"]
    pct_pbis = (100.0 * pbi_buckets["done"] / total_pbis_active) if total_pbis_active else 0.0

    # Find which sprints this feature has any work pinned into (PBI iter OR task iter)
    sprint_pins = set()
    for p in pbis:
        m = re.search(r"2Wk\d+", p["iter"] or "")
        if m: sprint_pins.add(m.group(0))
    for t in task_units:
        m = re.search(r"2Wk\d+", t["iter"] or "")
        if m: sprint_pins.add(m.group(0))

    # Health/risk -- PBI-driven
    state = feat_wi.get("state", "")
    above_cut = (sheet_row.get("row") and int(sheet_row["row"]) < (cutline_row or 99999))
    no_breakdown = (len(pbis) == 0)
    risk = "ok"
    if state == "Done" or (pct_pbis >= 100 and total_pbis_active > 0):
        risk = "done"
    elif state == "Committed" and no_breakdown:
        risk = "risk-empty"
    elif state == "Committed" and pbi_buckets["done"] == 0 and pbi_buckets["active"] == 0 and total_pbis_active > 0:
        risk = "risk-stalled"
    elif state == "New" and above_cut:
        risk = "warn-new"
    elif not above_cut:
        risk = "stretch"

    features.append({
        "id": fid,
        "title": feat_wi.get("title") or sheet_row.get("Title") or "(no title)",
        "state": state,
        "area": sheet_row.get("Area") or "—",
        "ado_title_local": sheet_row.get("Title") or "",
        "description": sheet_row.get("Description") or "",
        "pm_owner": sheet_row.get("PM Owner") or "",
        "person_weeks": sheet_row.get("Person weeks") or "",
        "effort": sheet_row.get("Accumulated Effort") or "",
        "priority": sheet_row.get("Priority") or "",
        "dependency": sheet_row.get("Dependency") or "",
        "deps_ok": sheet_row.get("Dependecies OK") or "",
        "committed": (sheet_row.get("Commited") in ("True", True, "true", "TRUE")),
        "above_cut": above_cut,
        "tags": feat_wi.get("tags", ""),
        "iter": feat_wi.get("iter", ""),
        "ado_url": f"https://your-ado-org.visualstudio.com/One/_workitems/edit/{fid}",
        "pbis": pbis,
        "pbi_buckets": pbi_buckets,
        "pct_pbis": pct_pbis,
        "sprint_pins": sorted(sprint_pins),
        "risk": risk,
    })

# group by area
AREA_ORDER = ["Atlas", "Fabric Experience", "SFI", "COGS", "DRI", "Eng Excellence", "Misc", "—"]
by_area = {a: [] for a in AREA_ORDER}
for f in features:
    by_area.setdefault(f["area"], []).append(f)

# ---- Overall stats (PBI-centric) ----
total_features = len(features)
done_features = sum(1 for f in features if f["state"] == "Done" or (f["pct_pbis"] >= 100 and (f["pbi_buckets"]["new"]+f["pbi_buckets"]["approved"]+f["pbi_buckets"]["active"]+f["pbi_buckets"]["done"]) > 0))
committed_features = sum(1 for f in features if f["state"] == "Committed")
new_features = sum(1 for f in features if f["state"] == "New")
in_flight_features = sum(1 for f in features if f["pbi_buckets"]["active"] > 0)

all_pbis_total = sum(f["pbi_buckets"]["new"] + f["pbi_buckets"]["approved"] + f["pbi_buckets"]["active"] + f["pbi_buckets"]["done"] for f in features)
all_pbis_done  = sum(f["pbi_buckets"]["done"] for f in features)
all_pbis_active = sum(f["pbi_buckets"]["active"] for f in features)
overall_pct = (100.0 * all_pbis_done / all_pbis_total) if all_pbis_total else 0.0
risk_empty   = sum(1 for f in features if f["risk"] == "risk-empty")
risk_stalled = sum(1 for f in features if f["risk"] == "risk-stalled")
stretch_count = sum(1 for f in features if not f["above_cut"])

# ---- Semester pulse ----
TODAY = date.today()
sem_total_days = (SEMESTER_END - SEMESTER_START).days + 1
sem_elapsed_days = max(0, min(sem_total_days, (TODAY - SEMESTER_START).days + 1))
sem_remaining_days = max(0, sem_total_days - sem_elapsed_days)
sem_pct_time = 100.0 * sem_elapsed_days / sem_total_days if sem_total_days else 0.0
# Sprint number within the semester (2-week sprints from Apr 1)
sprint_idx_in_sem = max(1, (sem_elapsed_days + 13) // 14)
sprints_total_in_sem = (sem_total_days + 13) // 14
# Verdict
delta = overall_pct - sem_pct_time
if delta >= 5:
    verdict = ("ahead", f"Ahead of pace by {delta:.0f} pts")
elif delta >= -10:
    verdict = ("on", "On track")
elif delta >= -20:
    verdict = ("warn", f"Behind pace by {-delta:.0f} pts")
else:
    verdict = ("danger", f"Significantly behind by {-delta:.0f} pts")

stamp = datetime.now().strftime("%Y-%m-%d %H:%M IST")

# ---- Capacity model (v3) ----
# Constants from Your Manager's planning sheet, rows 62-85 of the "Nir" tab:
#   FTEs            = 9.25         (row 62)
#   Weeks per person = 23          (row 63, after DRI & vacation netting)
#   Total Budget    = 212.75       (row 85, = FTEs x weeks)
#   DRI line        = 36 PW        (row 2 - DRI carried as a Feature line)
BUDGET_PW = 212.75
DRI_PW    = 36.0
# feature-ids.json carries the 27 above-cutline Features with per-Feature pweeks
try:
    feat_ids_raw = json.loads((INPUTS / "feature-ids.json").read_text(encoding="utf-8-sig"))
except FileNotFoundError:
    feat_ids_raw = []
feature_pw_by_id = {}        # ALL Features (above + stretch) -- used for per-Feature pace
feature_pw_above_total = 0.0 # sum of pweeks for above-cutline ADO Features (for sanity check)
for r in feat_ids_raw:
    try:
        fid = int(r["id"])
        pw  = float(r.get("pweeks") or 0)
    except (TypeError, ValueError):
        continue
    feature_pw_by_id[fid] = pw
    if r.get("above_cutline"):
        feature_pw_above_total += pw

# Total commit above the cutline = Accumulated Effort at the cutline row in Your Manager's sheet.
# That value already includes:
#   - the DRI 36-PW line at row 2
#   - all above-cutline Features with ADO IDs
#   - the orphan above-cutline rows that don't have an ADO Feature yet (e.g., "Work with engine to not choke" 10 PW)
commit_pw_from_sheet = None
cutline_acc_row = None
for r in sheet:
    try:
        row_n = int(r.get("row") or 0)
    except (TypeError, ValueError):
        continue
    if not row_n or not cutline_row or row_n > cutline_row:
        continue
    try:
        acc = float(r.get("Accumulated Effort") or 0)
    except (TypeError, ValueError):
        continue
    if acc > 0 and (commit_pw_from_sheet is None or acc >= commit_pw_from_sheet):
        commit_pw_from_sheet = acc
        cutline_acc_row = row_n

COMMIT_PW = commit_pw_from_sheet if commit_pw_from_sheet is not None else (DRI_PW + feature_pw_above_total)
OVER_PW   = COMMIT_PW - BUDGET_PW   # >0 = over budget

# Per-Feature delivered / in-flight credit -- hybrid PBI-state formula:
#   if feature state == Done OR pct_pbis == 100% with active-set > 0  -> 100% credit
#   elif any PBI done or active                                       -> (done + 0.5*active) / total
#   else                                                              -> 0
def feature_pace(f):
    pw = feature_pw_by_id.get(f["id"], 0.0)
    pb = f["pbi_buckets"]
    active_set_total = pb["new"] + pb["approved"] + pb["active"] + pb["done"]
    if pw <= 0 or active_set_total == 0:
        return {"pw": pw, "delivered": 0.0, "in_flight": 0.0, "active_credit": 0.0, "pct_delivered": 0.0}
    if f["state"] == "Done" or pb["done"] == active_set_total:
        return {"pw": pw, "delivered": pw, "in_flight": pw, "active_credit": 0.0, "pct_delivered": 100.0}
    frac_done   = pb["done"]   / active_set_total
    frac_active = pb["active"] / active_set_total
    delivered     = frac_done * pw
    active_credit = 0.5 * frac_active * pw
    in_flight     = delivered + active_credit
    return {
        "pw": pw, "delivered": delivered, "in_flight": in_flight,
        "active_credit": active_credit,
        "pct_delivered": 100.0 * delivered / pw,
    }

for f in features:
    f["pace"] = feature_pace(f)

# Team-level pace targets
elapsed_pct_frac = sem_pct_time / 100.0
pw_features_delivered = sum(f["pace"]["delivered"]      for f in features)
pw_active_credit      = sum(f["pace"]["active_credit"]  for f in features)
# DRI rotation is steady-state work above the cutline that is NOT tracked in ADO.
# At any point in time, ~elapsed% of the 36 PW DRI line has been "delivered" by the on-call rotation.
# Without this, the in-flight number undercounts real work by ~9 PW at sprint-4 close.
pw_dri_delivered      = elapsed_pct_frac * DRI_PW
pw_delivered_total    = pw_features_delivered + pw_dri_delivered
pw_in_flight_total    = pw_delivered_total + pw_active_credit
pw_target_at_today    = elapsed_pct_frac * BUDGET_PW   # what we'd need to deliver to be on pace against budget
pw_commit_target      = elapsed_pct_frac * COMMIT_PW   # ...against the actual commit (slightly higher)

def pace_verdict(in_flight, target):
    if target <= 0:
        return ("on", "On track")
    ratio = in_flight / target
    if ratio >= 1.05:
        return ("ahead", f"Ahead of pace ({ratio*100:.0f}% of target)")
    if ratio >= 0.90:
        return ("on", f"On pace ({ratio*100:.0f}% of target)")
    if ratio >= 0.75:
        return ("warn", f"Lagging ({ratio*100:.0f}% of target)")
    return ("danger", f"Behind ({ratio*100:.0f}% of target)")

capacity_verdict = pace_verdict(pw_in_flight_total, pw_target_at_today)

# Smoothstep S-curve: models "fraction of total work delivered by time t" under a realistic
# S-shaped velocity profile (slow start, peak middle, slow finish).
# At t=0.25 -> ~16% rather than linear 25%, much closer to real teams' delivery shapes.
def _s_curve(t):
    t = max(0.0, min(1.0, t))
    return 3.0 * t * t - 2.0 * t * t * t

pw_target_scurve  = _s_curve(elapsed_pct_frac) * BUDGET_PW
pace_ratio_scurve = (pw_in_flight_total / pw_target_scurve) if pw_target_scurve > 0 else 1.0
pace_verdict_color = ("good" if pace_ratio_scurve >= 0.95
                      else "mid" if pace_ratio_scurve >= 0.80
                      else "bad")

# Per-Feature pace chip -- only meaningful for in-flight, above-cutline Features.
def feature_pace_chip(f):
    if not f.get("above_cut", False):
        return ""
    pace = f["pace"]
    if pace["pw"] <= 0:
        return ""
    pb = f["pbi_buckets"]
    # not started -> existing "○ not started" badge handles this; no pace chip
    if pb["done"] == 0 and pb["active"] == 0:
        return ""
    # done -> existing "✓ done" badge handles this; no pace chip
    if f["state"] == "Done" or pb["done"] == (pb["new"] + pb["approved"] + pb["active"] + pb["done"]):
        return ""
    target = elapsed_pct_frac * pace["pw"]
    v = pace_verdict(pace["in_flight"], target)
    label = f"{pace['in_flight']:.1f}/{pace['pw']:.0f} p-wk"
    return f'<span class="pace-chip pace-{v[0]}" title="{esc(v[1])} -- target {target:.1f} of {pace["pw"]:.0f} PW at this point in semester">{label}</span>'

# ---- Snapshot / diff model (v3) ----
SNAPSHOT_DIR = STATE / "snapshots"
SNAPSHOT_DIR.mkdir(exist_ok=True)
TODAY_ISO = date.today().isoformat()

def _load_snapshot_items(path):
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    out = {}
    for it in raw:
        f = it.get("fields", {})
        try:
            iid = int(f["System.Id"])
        except (KeyError, TypeError, ValueError):
            continue
        out[iid] = {
            "id":     iid,
            "title":  f.get("System.Title", ""),
            "type":   f.get("System.WorkItemType", ""),
            "state":  f.get("System.State", ""),
            "iter":   f.get("System.IterationPath", ""),
            "parent": f.get("System.Parent", 0),
        }
    return out

def _newest_prior_snapshot():
    cands = []
    for p in sorted(SNAPSHOT_DIR.glob("*.json")):
        stem = p.stem
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", stem) and stem < TODAY_ISO:
            cands.append((stem, p))
    return cands[-1] if cands else (None, None)

prev_snap_date, prev_snap_path = _newest_prior_snapshot()
prev_items = _load_snapshot_items(prev_snap_path) if prev_snap_path else None

# Current snapshot of PBIs (and Features) by id (light shape, matching the prev loader)
curr_pbi_by_id = {iid: v for iid, v in wi.items() if v["type"] == "Product Backlog Item"}

def _pbi_done(state):
    return (state or "").lower() in ("done", "closed", "completed")

def _iter_sprint(it):
    m = re.search(r"2Wk(\d+)", it or "")
    return int(m.group(1)) if m else None

diff = {
    "has_prior": prev_items is not None,
    "prior_date": prev_snap_date,
    "added": [],         # PBIs in curr not in prev
    "removed": [],       # PBIs in prev not in curr
    "completed": [],     # PBIs that were not-done in prev and Done now
    "uncompleted": [],   # PBIs that were Done in prev and not Done now (rare but possible)
    "slipped": [],       # IterationPath moved to a later sprint (2WkN -> 2WkM with M>N)
    "pulled_in": [],     # Sprint pulled earlier (M<N)
    "feature_pct_delta": [],  # per-Feature pct_done movement
}

if prev_items is not None:
    prev_pbi = {iid: v for iid, v in prev_items.items() if v["type"] == "Product Backlog Item"}
    curr_ids = set(curr_pbi_by_id)
    prev_ids = set(prev_pbi)

    for iid in curr_ids - prev_ids:
        v = curr_pbi_by_id[iid]
        diff["added"].append({"id": iid, "title": v["title"], "state": v["state"], "iter": v["iter"]})
    for iid in prev_ids - curr_ids:
        v = prev_pbi[iid]
        diff["removed"].append({"id": iid, "title": v["title"], "state": v["state"], "iter": v["iter"]})

    for iid in curr_ids & prev_ids:
        c = curr_pbi_by_id[iid]
        p = prev_pbi[iid]
        if _pbi_done(c["state"]) and not _pbi_done(p["state"]):
            diff["completed"].append({"id": iid, "title": c["title"], "prev": p["state"], "curr": c["state"]})
        elif _pbi_done(p["state"]) and not _pbi_done(c["state"]):
            diff["uncompleted"].append({"id": iid, "title": c["title"], "prev": p["state"], "curr": c["state"]})
        ps = _iter_sprint(p["iter"])
        cs = _iter_sprint(c["iter"])
        if ps is not None and cs is not None and ps != cs:
            rec = {"id": iid, "title": c["title"], "prev_sprint": ps, "curr_sprint": cs}
            if cs > ps:
                diff["slipped"].append(rec)
            else:
                diff["pulled_in"].append(rec)

    # Per-Feature pct delta: compute prev's pct from prev_pbi keyed by parent
    prev_pbi_by_parent = {}
    for iid, v in prev_pbi.items():
        pid = v.get("parent") or 0
        if pid:
            prev_pbi_by_parent.setdefault(int(pid), []).append(v)
    for f in features:
        prev_children = prev_pbi_by_parent.get(f["id"], [])
        if not prev_children:
            continue
        prev_total = sum(1 for c in prev_children if (c["state"] or "").lower() != "removed")
        prev_done  = sum(1 for c in prev_children if _pbi_done(c["state"]))
        if prev_total == 0:
            continue
        prev_pct = 100.0 * prev_done / prev_total
        delta = f["pct_pbis"] - prev_pct
        if abs(delta) >= 0.5:   # only surface meaningful moves
            diff["feature_pct_delta"].append({
                "id": f["id"], "title": f["title"],
                "prev_pct": prev_pct, "curr_pct": f["pct_pbis"], "delta": delta,
            })
    diff["feature_pct_delta"].sort(key=lambda x: x["delta"], reverse=True)

# ---- HTML ----
def esc(s): return html_lib.escape(str(s or ""))

def state_pill(state):
    s = (state or "").lower()
    cls = "pill-neutral"
    if s == "done": cls = "pill-done"
    elif s == "committed": cls = "pill-committed"
    elif s == "active" or s == "in progress": cls = "pill-active"
    elif s == "in review": cls = "pill-review"
    elif s == "new": cls = "pill-new"
    elif s == "removed": cls = "pill-removed"
    elif s == "to do": cls = "pill-todo"
    return f'<span class="pill {cls}">{esc(state)}</span>'

def feature_card(f):
    pb = f["pbi_buckets"]
    risk_badge = ""
    if f["risk"] == "risk-empty":
        risk_badge = '<span class="badge badge-warn" title="Committed but no PBIs linked">⚠ no breakdown</span>'
    elif f["risk"] == "risk-stalled":
        risk_badge = '<span class="badge badge-warn" title="PBIs exist but none active or done">⏸ no progress</span>'
    elif f["risk"] == "done":
        risk_badge = '<span class="badge badge-done">✓ done</span>'
    elif f["risk"] == "warn-new":
        risk_badge = '<span class="badge badge-info" title="Committed by plan but still New in ADO">○ not started</span>'
    elif f["risk"] == "stretch":
        risk_badge = '<span class="badge badge-stretch" title="Below the CUTLINE in the plan">stretch</span>'

    pace_chip = feature_pace_chip(f)

    total_pbis = pb["new"] + pb["approved"] + pb["active"] + pb["done"]
    pct_pbis = f["pct_pbis"]

    sprint_chip = ""
    if f["sprint_pins"]:
        sprint_chip = f'<span class="chip chip-cur">{", ".join(f["sprint_pins"])}</span>'

    # PBI rows for expand
    pbi_html = []
    for p in sorted(f["pbis"], key=lambda x: (pbi_bucket(x["state"]) == "done", x["state"], x["title"])):
        owner = short_name(p["assigned"])
        sprint = ""
        if "2Wk" in (p["iter"] or ""):
            m = re.search(r"2Wk\d+", p["iter"])
            if m: sprint = m.group(0)
        pbi_html.append(f"""
          <div class="pbi-row">
            <a class="pbi-title" href="https://your-ado-org.visualstudio.com/One/_workitems/edit/{p['id']}" target="_blank">{esc(p['title'])}</a>
            <div class="pbi-meta">
              {state_pill(p['state'])}
              {f'<span class="meta">{esc(owner)}</span>' if owner else ''}
              {f'<span class="meta meta-sprint">{esc(sprint)}</span>' if sprint else ''}
            </div>
          </div>""")
    if not f["pbis"]:
        pbi_html.append('<div class="pbi-empty">No PBIs linked yet.</div>')

    desc_short = (f["description"] or "").strip()
    if len(desc_short) > 280: desc_short = desc_short[:280] + "…"

    return f"""
    <article class="feature" data-area="{esc(f['area'])}" data-state="{esc(f['state'])}" data-risk="{esc(f['risk'])}" data-cut="{'above' if f['above_cut'] else 'below'}">
      <header class="feat-head">
        <div class="feat-title-row">
          <a class="feat-title" href="{f['ado_url']}" target="_blank" title="Open #{f['id']} in ADO">{esc(f['title'])}</a>
          {state_pill(f['state'])}
          {risk_badge}
          {pace_chip}
        </div>
        <div class="feat-meta">
          <span class="meta">#{f['id']}</span>
          {f'<span class="meta">PM: {esc(f["pm_owner"])}</span>' if f["pm_owner"] else ''}
          {f'<span class="meta">{esc(f["person_weeks"])}p-wk</span>' if f["person_weeks"] else ''}
          {sprint_chip}
        </div>
        {f'<p class="feat-desc">{esc(desc_short)}</p>' if desc_short else ''}
      </header>
      <div class="progress-block">
        <div class="progress-row">
          <span class="progress-label">PBIs · {pb['done']}/{total_pbis} done</span>
          <div class="bar"><div class="bar-fill" style="width:{pct_pbis:.0f}%"></div></div>
          <span class="progress-pct">{pct_pbis:.0f}%</span>
        </div>
        <div class="chips chips-pbi">
          <span class="chip chip-pbi-new">{pb['new']} new</span>
          <span class="chip chip-pbi-approved">{pb['approved']} approved</span>
          <span class="chip chip-pbi-active">{pb['active']} active</span>
          <span class="chip chip-pbi-done">{pb['done']} done</span>
          {f'<span class="chip chip-removed">{pb["removed"]} removed</span>' if pb['removed'] else ''}
        </div>
      </div>
      <details class="pbi-list">
        <summary>Show {len(f['pbis'])} PBI{('s' if len(f['pbis'])!=1 else '')}</summary>
        <div class="pbi-rows">{''.join(pbi_html)}</div>
      </details>
    </article>
    """

# ---- Area sections ----
section_html = []
all_areas_present = list(by_area.keys())
sorted_areas = [a for a in AREA_ORDER if a in by_area and by_area[a]] + [a for a in by_area if a not in AREA_ORDER and by_area[a]]

for area in sorted_areas:
    feats = by_area[area]
    if not feats: continue
    # area-level stats (PBI-centric)
    a_total = sum((f["pbi_buckets"]["new"] + f["pbi_buckets"]["approved"] + f["pbi_buckets"]["active"] + f["pbi_buckets"]["done"]) for f in feats)
    a_done = sum(f["pbi_buckets"]["done"] for f in feats)
    a_pct = (100.0 * a_done / a_total) if a_total else 0
    cards = "\n".join(feature_card(f) for f in feats)
    section_html.append(f"""
      <section class="area-section" data-area="{esc(area)}">
        <header class="area-header">
          <h2>{esc(area)}</h2>
          <div class="area-meta">
            <span>{len(feats)} feature{'s' if len(feats)!=1 else ''}</span>
            <span>·</span>
            <span>{a_done}/{a_total} PBIs done</span>
            <div class="bar bar-area"><div class="bar-fill" style="width:{a_pct:.0f}%"></div></div>
            <span class="progress-pct">{a_pct:.0f}%</span>
          </div>
        </header>
        <div class="feature-grid">{cards}</div>
      </section>""")

# ---- Top-level template ----
HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>DM Semester Plan — Progress</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<script>
  (() => {
    const param = new URLSearchParams(window.location.search).get("clawpilotTheme");
    const theme = param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    document.documentElement.setAttribute("data-theme", theme);
  })();
</script>
<style>
:root {
  color-scheme: light;
  --cp-bg: #f7f4ef;
  --cp-bg-elevated: #fcfbf8;
  --cp-surface: #ffffff;
  --cp-surface-soft: #f5f5f5;
  --cp-border: #dedede;
  --cp-border-strong: #919191;
  --cp-text: #242424;
  --cp-text-muted: #5c5c5c;
  --cp-text-soft: #6f6f6f;
  --cp-accent: #b11f4b;
  --cp-accent-hover: #9a1a41;
  --cp-accent-soft: rgba(177, 31, 75, 0.08);
  --cp-accent-fg: #ffffff;
  --cp-success: #16a34a;
  --cp-danger: #dc2626;
  --cp-warning: #f59e0b;
  --cp-link: #0078d4;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
  --cp-overlay: rgba(255, 255, 255, 0.8);
  --cp-panel: rgba(255, 255, 255, 0.86);
  --cp-panel-strong: rgba(255, 255, 255, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.55);
  --cp-highlight: rgba(177, 31, 75, 0.12);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --cp-bg: #3d3b3a;
  --cp-bg-elevated: #343231;
  --cp-surface: #292929;
  --cp-surface-soft: #2e2e2e;
  --cp-border: #474747;
  --cp-border-strong: #5f5f5f;
  --cp-text: #dedede;
  --cp-text-muted: #919191;
  --cp-text-soft: #b0b0b0;
  --cp-accent: #fd8ea1;
  --cp-accent-hover: #fb7b91;
  --cp-accent-soft: rgba(253, 142, 161, 0.14);
  --cp-accent-fg: #1a1a1a;
  --cp-success: #4ade80;
  --cp-danger: #f87171;
  --cp-warning: #fbbf24;
  --cp-link: #4da6ff;
  --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
  --cp-overlay: rgba(41, 41, 41, 0.88);
  --cp-panel: rgba(41, 41, 41, 0.72);
  --cp-panel-strong: rgba(41, 41, 41, 0.96);
  --cp-sheen: rgba(255, 255, 255, 0.04);
  --cp-highlight: rgba(253, 142, 161, 0.12);
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--cp-bg);
  color: var(--cp-text);
  line-height: 1.45;
  font-size: 14px;
}
a { color: var(--cp-link); text-decoration: none; }
a:hover { text-decoration: underline; }
.container { max-width: 1480px; margin: 0 auto; padding: 24px 28px 64px; }
.hero {
  background: var(--cp-bg-elevated);
  border: 1px solid var(--cp-border);
  border-radius: 16px;
  padding: 24px 28px;
  margin-bottom: 24px;
  box-shadow: 0 0 2px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.14);
}
.hero h1 { margin: 0 0 4px; font-size: 22px; letter-spacing: -0.01em; }
.hero .sub { color: var(--cp-text-muted); font-size: 13px; margin-bottom: 16px; }
.hero-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
.stat-card {
  background: var(--cp-surface);
  border: 1px solid var(--cp-border);
  border-radius: 10px;
  padding: 12px 14px;
}
.stat-card .n { font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--cp-text); }
.stat-card .l { font-size: 12px; color: var(--cp-text-muted); margin-top: 2px; }
.stat-card.accent .n { color: var(--cp-accent); }
.stat-card.warn .n { color: var(--cp-warning); }
.stat-card.danger .n { color: var(--cp-danger); }
.stat-card.success .n { color: var(--cp-success); }

.pulse {
  background: var(--cp-bg-elevated);
  border: 1px solid var(--cp-border);
  border-radius: 16px;
  padding: 18px 22px;
  margin-bottom: 20px;
  box-shadow: 0 0 2px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.14);
}
.pulse-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 14px; margin-bottom: 14px; flex-wrap: wrap; }
.pulse h2 { margin: 0 0 2px; font-size: 16px; letter-spacing: 0.02em; text-transform: uppercase; color: var(--cp-text); }
.pulse-sub { margin: 0; color: var(--cp-text-muted); font-size: 12.5px; }
.pulse-verdict {
  font-size: 13px; font-weight: 500;
  padding: 6px 14px;
  border-radius: 999px;
  border: 1px solid transparent;
  display: inline-flex; align-items: center; gap: 8px;
}
.pulse-verdict .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
.pulse-on { background: rgba(22,163,74,0.10); color: var(--cp-success); border-color: var(--cp-success); }
.pulse-on .dot { background: var(--cp-success); }
.pulse-ahead { background: rgba(22,163,74,0.16); color: var(--cp-success); border-color: var(--cp-success); }
.pulse-ahead .dot { background: var(--cp-success); }
.pulse-warn { background: rgba(245,158,11,0.12); color: var(--cp-warning); border-color: var(--cp-warning); }
.pulse-warn .dot { background: var(--cp-warning); }
.pulse-danger { background: rgba(220,38,38,0.12); color: var(--cp-danger); border-color: var(--cp-danger); }
.pulse-danger .dot { background: var(--cp-danger); }

.pulse-bars { display: flex; flex-direction: column; gap: 10px; margin: 6px 0 12px; }
.pulse-row { display: grid; grid-template-columns: 110px 1fr 42px; gap: 12px; align-items: center; }
.pulse-label { font-size: 12px; color: var(--cp-text-muted); }
.pulse-bar {
  position: relative;
  background: var(--cp-surface-soft);
  border-radius: 999px;
  height: 14px;
  overflow: visible;
  border: 1px solid var(--cp-border);
}
.pulse-fill { height: 100%; border-radius: 999px; transition: width .4s ease; }
.pulse-fill-time { background: var(--cp-text-soft); opacity: 0.45; }
.pulse-fill-work { background: var(--cp-accent); }
.pulse-marker {
  position: absolute; top: -3px; bottom: -3px; width: 2px; background: var(--cp-text); border-radius: 1px;
}
.pulse-marker-ghost { background: var(--cp-text-muted); opacity: 0.7; }
.pulse-pct { font-variant-numeric: tabular-nums; color: var(--cp-text); font-size: 13px; font-weight: 500; text-align: right; }
.pulse-foot { display: flex; gap: 10px; flex-wrap: wrap; color: var(--cp-text-muted); font-size: 12px; padding-top: 8px; border-top: 1px dashed var(--cp-border); }

.toolbar {
  display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
  background: var(--cp-bg-elevated);
  border: 1px solid var(--cp-border);
  border-radius: 12px;
  padding: 10px 12px;
  margin-bottom: 20px;
  position: sticky; top: 8px; z-index: 5;
}
.toolbar input[type=search], .toolbar select {
  background: var(--cp-surface);
  color: var(--cp-text);
  border: 1px solid var(--cp-border);
  border-radius: 10px;
  padding: 6px 10px;
  font-family: inherit;
  font-size: 13px;
  min-width: 180px;
}
.toolbar input[type=search]:focus, .toolbar select:focus { outline: 2px solid var(--cp-accent-soft); border-color: var(--cp-accent); }
.toolbar .filter-group { display: flex; gap: 6px; flex-wrap: wrap; }
.toolbar .filter-btn {
  background: var(--cp-surface);
  border: 1px solid var(--cp-border);
  color: var(--cp-text-muted);
  border-radius: 999px;
  padding: 4px 10px;
  font-size: 12px;
  cursor: pointer;
}
.toolbar .filter-btn.on { background: var(--cp-accent-soft); border-color: var(--cp-accent); color: var(--cp-accent); }
.toolbar .spacer { flex: 1; }
.theme-toggle {
  background: var(--cp-surface);
  border: 1px solid var(--cp-border);
  border-radius: 10px;
  padding: 6px 10px;
  cursor: pointer;
  color: var(--cp-text);
}
.toolbar .count { font-size: 12px; color: var(--cp-text-muted); padding: 0 4px; }

.area-section { margin-bottom: 32px; }
.area-header { display: flex; align-items: center; gap: 14px; margin: 12px 4px 12px; flex-wrap: wrap; }
.area-header h2 { margin: 0; font-size: 16px; letter-spacing: 0.02em; text-transform: uppercase; color: var(--cp-text); }
.area-meta { display: flex; align-items: center; gap: 10px; color: var(--cp-text-muted); font-size: 12px; }
.bar { background: var(--cp-surface-soft); border-radius: 999px; height: 8px; overflow: hidden; }
.bar-area { width: 160px; }
.bar-fill { background: var(--cp-accent); height: 100%; border-radius: 999px; transition: width .3s; }
.progress-pct { font-variant-numeric: tabular-nums; color: var(--cp-text-muted); font-size: 12px; min-width: 36px; text-align: right; }

.feature-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(420px, 1fr)); gap: 14px; }
.feature {
  background: var(--cp-surface);
  border: 1px solid var(--cp-border);
  border-radius: 16px;
  padding: 16px;
  display: flex; flex-direction: column; gap: 12px;
  box-shadow: 0 0 2px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.14);
  transition: border-color .15s, box-shadow .15s;
}
.feature:hover { border-color: var(--cp-border-strong); }
.feature[data-risk="risk-empty"] { border-color: var(--cp-warning); }
.feature[data-risk="risk-stalled"] { border-color: var(--cp-warning); }
.feature[data-risk="done"] { background: var(--cp-bg-elevated); }
.feature[data-cut="below"] { opacity: 0.78; }

.feat-head { display: flex; flex-direction: column; gap: 6px; }
.feat-title-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.feat-title { font-size: 15px; font-weight: 600; color: var(--cp-text); }
.feat-title:hover { color: var(--cp-accent); text-decoration: none; }
.feat-meta { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; color: var(--cp-text-muted); font-size: 12px; }
.feat-desc { margin: 0; color: var(--cp-text-soft); font-size: 12.5px; line-height: 1.4; }

.pill { display: inline-flex; align-items: center; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 500; border: 1px solid transparent; }
.pill-new { background: var(--cp-surface-soft); color: var(--cp-text-muted); border-color: var(--cp-border); }
.pill-todo { background: var(--cp-surface-soft); color: var(--cp-text-muted); border-color: var(--cp-border); }
.pill-committed { background: var(--cp-accent-soft); color: var(--cp-accent); border-color: var(--cp-accent); }
.pill-active { background: rgba(245, 158, 11, 0.12); color: var(--cp-warning); border-color: var(--cp-warning); }
.pill-review { background: rgba(0, 120, 212, 0.12); color: var(--cp-link); border-color: var(--cp-link); }
.pill-done { background: rgba(22, 163, 74, 0.14); color: var(--cp-success); border-color: var(--cp-success); }
.pill-removed { background: var(--cp-surface-soft); color: var(--cp-text-muted); border-color: var(--cp-border); text-decoration: line-through; }
.pill-neutral { background: var(--cp-surface-soft); color: var(--cp-text-muted); border-color: var(--cp-border); }

.badge { font-size: 11px; padding: 2px 8px; border-radius: 999px; border: 1px solid transparent; }
.badge-warn { background: rgba(245, 158, 11, 0.12); color: var(--cp-warning); border-color: var(--cp-warning); }
.badge-done { background: rgba(22, 163, 74, 0.14); color: var(--cp-success); border-color: var(--cp-success); }
.badge-info { background: var(--cp-accent-soft); color: var(--cp-accent); border-color: var(--cp-accent); }
.badge-stretch { background: var(--cp-surface-soft); color: var(--cp-text-soft); border: 1px dashed var(--cp-border-strong); }

.progress-block { display: flex; flex-direction: column; gap: 8px; }
.progress-row { display: flex; align-items: center; gap: 10px; font-size: 12px; color: var(--cp-text-muted); }
.progress-row .bar { flex: 1; }
.progress-label { min-width: 120px; }
.pbi-summary { padding-top: 6px; border-top: 1px dashed var(--cp-border); margin-top: 2px; }

.chips { display: flex; gap: 6px; flex-wrap: wrap; }
.chip {
  font-size: 11px; padding: 2px 8px; border-radius: 999px;
  border: 1px solid var(--cp-border); background: var(--cp-surface-soft); color: var(--cp-text-muted);
}
.chip-active { color: var(--cp-warning); border-color: var(--cp-warning); background: rgba(245, 158, 11, 0.08); }
.chip-review { color: var(--cp-link); border-color: var(--cp-link); background: rgba(0, 120, 212, 0.08); }
.chip-done { color: var(--cp-success); border-color: var(--cp-success); background: rgba(22, 163, 74, 0.08); }
.chip-removed { text-decoration: line-through; }
.chip-cur { color: var(--cp-accent); border-color: var(--cp-accent); background: var(--cp-accent-soft); }

.chip-pbi-active { color: var(--cp-warning); border-color: var(--cp-warning); background: rgba(245, 158, 11, 0.08); }
.chip-pbi-done { color: var(--cp-success); border-color: var(--cp-success); background: rgba(22, 163, 74, 0.08); }
.chip-pbi-approved { color: var(--cp-accent); border-color: var(--cp-accent); background: var(--cp-accent-soft); }

.pbi-list { font-size: 12px; }
.pbi-list summary { cursor: pointer; color: var(--cp-text-muted); padding: 4px 0; user-select: none; }
.pbi-list summary:hover { color: var(--cp-accent); }
.pbi-list[open] summary { color: var(--cp-text); }
.pbi-rows { display: flex; flex-direction: column; gap: 6px; padding-top: 8px; border-top: 1px solid var(--cp-border); margin-top: 4px; }
.pbi-row { display: flex; flex-direction: column; gap: 4px; padding: 6px 0; border-bottom: 1px dashed var(--cp-border); }
.pbi-row:last-child { border-bottom: none; }
.pbi-title { color: var(--cp-text); font-size: 12.5px; }
.pbi-meta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; color: var(--cp-text-muted); }
.pbi-empty { color: var(--cp-text-soft); font-style: italic; padding: 8px 0; }
.meta { font-size: 11px; }
.meta-sprint { background: var(--cp-accent-soft); color: var(--cp-accent); padding: 1px 6px; border-radius: 999px; }
.mini-bar { background: var(--cp-surface-soft); border-radius: 999px; height: 5px; flex: 1; max-width: 80px; overflow: hidden; }
.mini-bar-fill { background: var(--cp-accent); height: 100%; }

.cutline-divider {
  text-align: center; margin: 28px 0 14px;
  color: var(--cp-text-muted); font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase;
  position: relative;
}
.cutline-divider::before, .cutline-divider::after {
  content: ""; position: absolute; top: 50%; width: 40%; height: 1px;
  background: var(--cp-border-strong);
}
.cutline-divider::before { left: 0; }
.cutline-divider::after { right: 0; }
footer { color: var(--cp-text-soft); font-size: 11px; text-align: center; padding-top: 28px; }

/* ---- v3: Capacity & Pace ---- */
.capacity { background: var(--cp-bg-elevated); border: 1px solid var(--cp-border); border-radius: 12px; padding: 18px 22px; margin: 18px 0 8px; box-shadow: 0 2px 12px rgba(0,0,0,0.04); }
.capacity-head { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 10px; }
.capacity-head h2 { margin: 0; font-size: 18px; }
.capacity-sub { color: var(--cp-text-muted); font-size: 12.5px; margin: 2px 0 0; }
.capacity-grid { display: grid; grid-template-columns: 1fr 1.6fr; gap: 18px; align-items: start; }
.cap-card { background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 10px; padding: 14px 16px; }
.cap-card-chart { padding-bottom: 18px; }
.cap-chart-summary { display: flex; gap: 8px; flex-wrap: wrap; margin: 8px 0 12px 0; }
.cap-chip { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; border: 1px solid var(--cp-border); background: var(--cp-bg); color: var(--cp-text); }
.cap-chip-target { color: var(--cp-accent); border-color: var(--cp-accent); }
.cap-chip-actual.cap-chip-good, .cap-chip-ratio.cap-chip-good { color: var(--cp-success); border-color: var(--cp-success); background: rgba(22,163,74,0.06); }
.cap-chip-actual.cap-chip-mid,  .cap-chip-ratio.cap-chip-mid  { color: var(--cp-warning); border-color: var(--cp-warning); background: rgba(245,158,11,0.06); }
.cap-chip-actual.cap-chip-bad,  .cap-chip-ratio.cap-chip-bad  { color: var(--cp-danger);  border-color: var(--cp-danger);  background: rgba(239,68,68,0.06); }
.pace-svg { width: 100%; height: auto; display: block; margin-top: 4px; }
.cap-card h3 { margin: 0 0 8px; font-size: 13px; color: var(--cp-text-muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }
.cap-figure { font-size: 26px; font-weight: 700; line-height: 1.1; }
.cap-figure .unit { font-size: 13px; font-weight: 500; color: var(--cp-text-muted); margin-left: 4px; }
.cap-foot { margin-top: 8px; color: var(--cp-text-muted); font-size: 12px; }
.cap-bar { position: relative; height: 14px; background: var(--cp-surface-soft); border-radius: 7px; margin: 10px 0 6px; overflow: hidden; border: 1px solid var(--cp-border); }
.cap-bar-budget { position: absolute; top: 0; left: 0; height: 100%; background: linear-gradient(90deg, var(--cp-success), color-mix(in srgb, var(--cp-success) 70%, white)); }
.cap-bar-over { position: absolute; top: 0; height: 100%; background: repeating-linear-gradient(45deg, var(--cp-danger), var(--cp-danger) 5px, color-mix(in srgb, var(--cp-danger) 70%, white) 5px, color-mix(in srgb, var(--cp-danger) 70%, white) 10px); }
.cap-bar-mark { position: absolute; top: -3px; bottom: -3px; width: 2px; background: var(--cp-text); }
.cap-bar-legend { display: flex; gap: 14px; font-size: 11.5px; color: var(--cp-text-muted); }
.cap-bar-legend .sw { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 4px; vertical-align: -1px; }
.cap-bar-legend .sw-budget { background: var(--cp-success); }
.cap-bar-legend .sw-over { background: var(--cp-danger); }
.cap-verdict { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; }
.cap-verdict.ahead   { background: rgba(22, 163, 74, 0.12); color: var(--cp-success); }
.cap-verdict.on      { background: rgba(22, 163, 74, 0.10); color: var(--cp-success); }
.cap-verdict.warn    { background: rgba(245, 158, 11, 0.14); color: #b45309; }
.cap-verdict.danger  { background: rgba(220, 38, 38, 0.12); color: var(--cp-danger); }
.cap-flag { margin-top: 10px; padding: 8px 12px; border-left: 3px solid var(--cp-warning); background: rgba(245, 158, 11, 0.07); color: var(--cp-text-muted); font-size: 12px; border-radius: 0 6px 6px 0; }
.cap-flag-info { border-left-color: var(--cp-accent); background: rgba(96, 165, 250, 0.07); }

/* ---- v3: Per-Feature pace chip ---- */
.pace-chip { display: inline-flex; align-items: center; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; margin-left: 4px; border: 1px solid transparent; white-space: nowrap; }
.pace-chip.pace-ahead  { background: rgba(22, 163, 74, 0.10); color: var(--cp-success); border-color: rgba(22, 163, 74, 0.30); }
.pace-chip.pace-on     { background: rgba(22, 163, 74, 0.07); color: var(--cp-success); border-color: rgba(22, 163, 74, 0.20); }
.pace-chip.pace-warn   { background: rgba(245, 158, 11, 0.12); color: #b45309; border-color: rgba(245, 158, 11, 0.30); }
.pace-chip.pace-danger { background: rgba(220, 38, 38, 0.10); color: var(--cp-danger); border-color: rgba(220, 38, 38, 0.30); }

/* ---- v3: Changes since last refresh ---- */
.changes { background: var(--cp-bg-elevated); border: 1px solid var(--cp-border); border-radius: 12px; padding: 18px 22px; margin: 8px 0 18px; }
.changes-head { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 12px; }
.changes-head h2 { margin: 0; font-size: 18px; }
.changes-sub { color: var(--cp-text-muted); font-size: 12.5px; margin: 2px 0 0; }
.changes-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; }
.changes-card { background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 10px; padding: 12px 14px; }
.changes-card h3 { margin: 0 0 6px; font-size: 12px; color: var(--cp-text-muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; display: flex; gap: 6px; align-items: baseline; }
.changes-card .badge-n { background: var(--cp-surface-soft); color: var(--cp-text); padding: 1px 6px; border-radius: 4px; font-size: 11px; font-weight: 700; }
.changes-card.empty { opacity: 0.6; }
.changes-list { font-size: 12.5px; margin: 0; padding-left: 18px; }
.changes-list li { margin: 2px 0; line-height: 1.4; }
.changes-list a { color: var(--cp-link); text-decoration: none; }
.changes-list a:hover { text-decoration: underline; }
.changes-list .meta { color: var(--cp-text-muted); font-size: 11.5px; margin-left: 4px; }
.changes-empty-note { color: var(--cp-text-muted); font-size: 12px; margin: 0; padding: 8px 10px; background: var(--cp-surface-soft); border-radius: 6px; }
.changes-pct-up   { color: var(--cp-success); font-weight: 600; }
.changes-pct-down { color: var(--cp-danger); font-weight: 600; }

@media (max-width: 720px) {
  .container { padding: 14px; }
  .feature-grid { grid-template-columns: 1fr; }
  .progress-label { min-width: 90px; }
  .capacity-grid { grid-template-columns: 1fr; }
}
</style>
</head>
<body>
<div class="container">
"""

hero_html = f"""
<section class="hero">
  <h1>DM Semester Plan &mdash; Progress</h1>
  <div class="sub">Source: <strong>Nir</strong> sheet of Your Manager's spreadsheet (Planning-2026-Rb-2.xlsx) &middot; ADO snapshot {esc(stamp)} &middot; {total_features} Features &middot; {all_pbis_total} PBIs in flight</div>
  <div class="hero-stats">
    <div class="stat-card success"><div class="n">{overall_pct:.0f}%</div><div class="l">PBIs done overall</div></div>
    <div class="stat-card"><div class="n">{all_pbis_done}/{all_pbis_total}</div><div class="l">PBIs done / total</div></div>
    <div class="stat-card accent"><div class="n">{all_pbis_active}</div><div class="l">PBIs active</div></div>
    <div class="stat-card"><div class="n">{committed_features}/{total_features}</div><div class="l">Features in Committed state</div></div>
    <div class="stat-card success"><div class="n">{done_features}</div><div class="l">Features done</div></div>
    <div class="stat-card warn"><div class="n">{risk_empty}</div><div class="l">Committed w/o breakdown</div></div>
    <div class="stat-card warn"><div class="n">{risk_stalled}</div><div class="l">no PBI progress yet</div></div>
  </div>
</section>

<section class="pulse">
  <div class="pulse-head">
    <div>
      <h2>Semester Pulse</h2>
      <p class="pulse-sub">{SEMESTER_START.strftime('%b %d, %Y')} &mdash; {SEMESTER_END.strftime('%b %d, %Y')} &middot; Day {sem_elapsed_days} of {sem_total_days} &middot; sprint {sprint_idx_in_sem} of {sprints_total_in_sem}</p>
    </div>
    <div class="pulse-verdict pulse-on"><span class="dot"></span>Day {sem_elapsed_days} of {sem_total_days}</div>
  </div>
  <div class="pulse-bars">
    <div class="pulse-row">
      <div class="pulse-label">Time elapsed</div>
      <div class="pulse-bar pulse-bar-time">
        <div class="pulse-fill pulse-fill-time" style="width:{sem_pct_time:.1f}%"></div>
        <div class="pulse-marker" style="left:{sem_pct_time:.1f}%"></div>
      </div>
      <div class="pulse-pct">{sem_pct_time:.0f}%</div>
    </div>
    <div class="pulse-row">
      <div class="pulse-label">PBIs done</div>
      <div class="pulse-bar pulse-bar-work">
        <div class="pulse-fill pulse-fill-work" style="width:{overall_pct:.1f}%"></div>
        <div class="pulse-marker pulse-marker-ghost" style="left:{sem_pct_time:.1f}%" title="time-elapsed mark"></div>
      </div>
      <div class="pulse-pct">{overall_pct:.0f}%</div>
    </div>
  </div>
  <div class="pulse-foot">
    <span>{sem_remaining_days} days remaining</span>
    <span>&middot;</span>
    <span>{committed_features} Features committed &middot; {in_flight_features} in flight &middot; {done_features} done</span>
    <span>&middot;</span>
    <span>{stretch_count} below cutline (stretch)</span>
  </div>
</section>
"""

# ---- v3: Capacity & Pace ribbon ----
# Bar width logic: scale by COMMIT_PW so we can show both budget portion and over-commit portion.
_max_pw       = max(COMMIT_PW, BUDGET_PW, 1.0)
_budget_w     = 100.0 * min(BUDGET_PW, COMMIT_PW) / _max_pw
_over_left    = 100.0 * BUDGET_PW / _max_pw
_over_w       = max(0.0, 100.0 * OVER_PW / _max_pw)

_over_band_html = (
    f'<div class="cap-bar-over" style="left:{_over_left:.2f}%; width:{_over_w:.2f}%" title="Over budget by {OVER_PW:.2f} PW"></div>'
    if OVER_PW > 0.01 else ''
)
_dri_note_html = (
    '<div class="cap-flag cap-flag-info">DRI accounting &middot; '
    'DRI rotation is committed work above the cutline (36 PW). It is not tracked as a Feature in ADO &mdash; '
    'each DRI-eligible engineer absorbs 4.5 weeks of rotation duty out of their 23-week semester budget '
    '(effective dev budget 18.5 weeks for those folks). '
    f'At {sem_pct_time:.0f}% elapsed, steady-state DRI burn = {pw_dri_delivered:.1f} PW and is rolled into the actual number on the chart.</div>'
)

# ---- S-curve SVG (target vs actual) ----
def _build_pace_svg():
    W, H = 760, 280
    PAD_L, PAD_R, PAD_T, PAD_B = 64, 32, 26, 48
    pw = W - PAD_L - PAD_R
    ph = H - PAD_T - PAD_B
    y_top_pw = max(BUDGET_PW, pw_in_flight_total) * 1.05  # leave headroom

    def xp(frac): return PAD_L + pw * frac
    def yp(pw_val): return PAD_T + ph * (1.0 - pw_val / y_top_pw)

    pts = []
    for i in range(0, 81):
        t = i / 80.0
        pts.append(f"{xp(t):.1f},{yp(_s_curve(t) * BUDGET_PW):.1f}")
    s_curve_pts = " ".join(pts)

    today_frac = elapsed_pct_frac
    today_x  = xp(today_frac)
    y_actual = yp(pw_in_flight_total)
    y_target = yp(pw_target_scurve)
    y_budget = yp(BUDGET_PW)
    y_half   = yp(BUDGET_PW / 2.0)
    y_zero   = yp(0)

    actual_color = ("var(--cp-success)" if pace_ratio_scurve >= 0.95
                    else "var(--cp-warning)" if pace_ratio_scurve >= 0.80
                    else "var(--cp-danger)")

    actual_label_y = y_actual - 12 if y_actual > y_target else y_actual + 18
    target_label_y = y_target + 18 if y_actual > y_target else y_target - 12

    return f'''
<svg viewBox="0 0 {W} {H}" class="pace-svg" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="S-curve target vs actual person-weeks">
  <!-- gridlines -->
  <line x1="{PAD_L}" y1="{y_zero:.1f}"   x2="{xp(1.0):.1f}" y2="{y_zero:.1f}"   stroke="var(--cp-border)" stroke-width="1"/>
  <line x1="{PAD_L}" y1="{y_half:.1f}"   x2="{xp(1.0):.1f}" y2="{y_half:.1f}"   stroke="var(--cp-border)" stroke-width="1" stroke-dasharray="2 4" opacity="0.5"/>
  <line x1="{PAD_L}" y1="{y_budget:.1f}" x2="{xp(1.0):.1f}" y2="{y_budget:.1f}" stroke="var(--cp-border)" stroke-width="1" stroke-dasharray="2 4" opacity="0.5"/>
  <line x1="{PAD_L}" y1="{PAD_T}"        x2="{PAD_L}"      y2="{y_zero:.1f}"   stroke="var(--cp-border)" stroke-width="1"/>
  <!-- y-axis labels -->
  <text x="{PAD_L-8:.1f}" y="{y_zero+4:.1f}"   font-size="11" text-anchor="end" fill="var(--cp-text-muted)">0 PW</text>
  <text x="{PAD_L-8:.1f}" y="{y_half+4:.1f}"   font-size="11" text-anchor="end" fill="var(--cp-text-muted)">{BUDGET_PW/2:.0f} PW</text>
  <text x="{PAD_L-8:.1f}" y="{y_budget+4:.1f}" font-size="11" text-anchor="end" fill="var(--cp-text-muted)" font-weight="600">{BUDGET_PW:.0f} PW (budget)</text>
  <!-- x-axis labels -->
  <text x="{xp(0):.1f}"      y="{y_zero+22:.1f}" font-size="11" text-anchor="middle" fill="var(--cp-text-muted)">Apr 1</text>
  <text x="{xp(0.5):.1f}"    y="{y_zero+22:.1f}" font-size="11" text-anchor="middle" fill="var(--cp-text-muted)">Jul 1</text>
  <text x="{xp(1.0):.1f}"    y="{y_zero+22:.1f}" font-size="11" text-anchor="middle" fill="var(--cp-text-muted)">Sep 30</text>
  <!-- S-curve target -->
  <polyline points="{s_curve_pts}" fill="none" stroke="var(--cp-accent)" stroke-width="2.5"/>
  <text x="{xp(0.78):.1f}" y="{yp(_s_curve(0.78)*BUDGET_PW)-10:.1f}" font-size="11" fill="var(--cp-accent)" font-weight="600">Target curve</text>
  <!-- today vertical -->
  <line x1="{today_x:.1f}" y1="{PAD_T}" x2="{today_x:.1f}" y2="{y_zero:.1f}" stroke="var(--cp-text-muted)" stroke-width="1" stroke-dasharray="3 3" opacity="0.7"/>
  <text x="{today_x:.1f}" y="{PAD_T-8:.1f}" font-size="11" text-anchor="middle" fill="var(--cp-text)" font-weight="600">Today &middot; sprint {sprint_idx_in_sem}/{sprints_total_in_sem} &middot; {sem_pct_time:.0f}% elapsed</text>
  <!-- target dot on curve at today -->
  <circle cx="{today_x:.1f}" cy="{y_target:.1f}" r="6" fill="var(--cp-bg)" stroke="var(--cp-accent)" stroke-width="2.5"/>
  <text x="{today_x+12:.1f}" y="{target_label_y:.1f}" font-size="12" fill="var(--cp-accent)" font-weight="600">Target: {pw_target_scurve:.1f} PW</text>
  <!-- actual dot at today -->
  <circle cx="{today_x:.1f}" cy="{y_actual:.1f}" r="8" fill="{actual_color}" stroke="var(--cp-bg)" stroke-width="2"/>
  <text x="{today_x+12:.1f}" y="{actual_label_y:.1f}" font-size="13" fill="{actual_color}" font-weight="700">Actual: {pw_in_flight_total:.1f} PW &middot; {pace_ratio_scurve*100:.0f}% of target</text>
</svg>'''

_pace_svg_html = _build_pace_svg()

capacity_html = f"""
<section class="capacity">
  <div class="capacity-head">
    <div>
      <h2>Capacity &amp; Pace</h2>
      <p class="capacity-sub">Person-weeks (<strong>PW = person-week</strong>, one engineer working one week) committed vs. budget, and delivery pace vs. an S-curve target (slow start, mid acceleration, late landing). Source: rows 62&ndash;85 of the &ldquo;Nir&rdquo; sheet + per-Feature <code>pweeks</code>.</p>
    </div>
  </div>
  <div class="capacity-grid">
    <div class="cap-card">
      <h3>Budget vs. above-cutline commit</h3>
      <div class="cap-figure">{COMMIT_PW:.2f} <span class="unit">PW committed</span></div>
      <div class="cap-bar" title="Budget {BUDGET_PW:.2f} PW &middot; commit {COMMIT_PW:.2f} PW">
        <div class="cap-bar-budget" style="width:{_budget_w:.2f}%"></div>
        {_over_band_html}
      </div>
      <div class="cap-bar-legend">
        <span><span class="sw sw-budget"></span>Budget {BUDGET_PW:.2f} PW (9.25 FTE &times; 23 wk)</span>
        <span><span class="sw sw-over"></span>Over by {OVER_PW:+.2f} PW</span>
      </div>
      <div class="cap-foot">DRI line {DRI_PW:.0f} PW + Features {feature_pw_above_total:.0f} PW (+ orphan above-cutline rows w/o ADO IDs) = <strong>{COMMIT_PW:.0f} PW</strong> committed above cutline.</div>
    </div>
    <div class="cap-card cap-card-chart">
      <h3>Person-weeks: target vs. actual</h3>
      <div class="cap-chart-summary">
        <span class="cap-chip cap-chip-target">Target {pw_target_scurve:.1f} PW</span>
        <span class="cap-chip cap-chip-actual cap-chip-{pace_verdict_color}">Actual {pw_in_flight_total:.1f} PW</span>
        <span class="cap-chip cap-chip-ratio cap-chip-{pace_verdict_color}">{pace_ratio_scurve*100:.0f}% of target</span>
      </div>
      {_pace_svg_html}
      <div class="cap-foot">Actual = {pw_features_delivered:.1f} ADO done + {pw_dri_delivered:.1f} DRI rotation + {pw_active_credit:.1f} active credit (PBIs in-flight credited at 50%). Per-Feature pace chips appear on in-flight cards below.</div>
    </div>
  </div>
  {_dri_note_html}
</section>
"""

# ---- v3: "What changed since last refresh" panel ----
def _diff_li(rec, kind):
    iid = rec.get("id")
    title = esc(rec.get("title", ""))
    link = f'<a href="https://your-ado-org.visualstudio.com/One/_workitems/edit/{iid}" target="_blank">#{iid}</a>'
    if kind == "completed":
        return f'<li>{link} {title} <span class="meta">({esc(rec.get("prev",""))} &rarr; {esc(rec.get("curr",""))})</span></li>'
    if kind == "added":
        return f'<li>{link} {title} <span class="meta">[{esc(rec.get("state",""))}]</span></li>'
    if kind == "removed":
        return f'<li>{link} {title} <span class="meta">[{esc(rec.get("state",""))}]</span></li>'
    if kind == "slipped":
        return f'<li>{link} {title} <span class="meta">2Wk{rec.get("prev_sprint")} &rarr; 2Wk{rec.get("curr_sprint")}</span></li>'
    if kind == "pulled_in":
        return f'<li>{link} {title} <span class="meta">2Wk{rec.get("prev_sprint")} &rarr; 2Wk{rec.get("curr_sprint")}</span></li>'
    if kind == "feature_pct":
        cls = "changes-pct-up" if rec["delta"] > 0 else "changes-pct-down"
        sign = "+" if rec["delta"] > 0 else ""
        return f'<li>{link} {title} <span class="{cls}">{sign}{rec["delta"]:.0f} pts</span> <span class="meta">({rec["prev_pct"]:.0f}% &rarr; {rec["curr_pct"]:.0f}%)</span></li>'
    return f'<li>{link} {title}</li>'

def _diff_card(title, recs, kind, empty_msg=None):
    n = len(recs)
    klass = "changes-card" + (" empty" if n == 0 else "")
    if n == 0:
        body = f'<p class="changes-empty-note">{empty_msg or "Nothing in this bucket."}</p>'
    else:
        # cap at 8 rows for tidiness; show "+N more" if larger
        capped = recs[:8]
        more = ""
        if n > 8:
            more = f'<li><span class="meta">+{n-8} more&hellip;</span></li>'
        body = f'<ul class="changes-list">{"".join(_diff_li(r, kind) for r in capped)}{more}</ul>'
    return f'<div class="{klass}"><h3>{esc(title)} <span class="badge-n">{n}</span></h3>{body}</div>'

if diff["has_prior"]:
    changes_inner = "".join([
        _diff_card("Completed since last refresh", diff["completed"],   "completed",  empty_msg="No PBIs moved to Done this cycle."),
        _diff_card("Newly added PBIs",             diff["added"],       "added",      empty_msg="No new PBIs since last refresh."),
        _diff_card("Slipped to a later sprint",    diff["slipped"],     "slipped",    empty_msg="No sprint slips."),
        _diff_card("Pulled into an earlier sprint", diff["pulled_in"],  "pulled_in",  empty_msg="None pulled in."),
        _diff_card("Removed",                      diff["removed"],     "removed",    empty_msg="No PBIs removed."),
        _diff_card("Feature %-done movement",      diff["feature_pct_delta"], "feature_pct", empty_msg="No Feature progress moved by &ge; 0.5 points."),
    ])
    changes_html = f"""
<section class="changes">
  <div class="changes-head">
    <div>
      <h2>What changed since last refresh</h2>
      <p class="changes-sub">Diff vs. snapshot <code>{esc(diff['prior_date'])}</code> &middot; new PBIs, completions, sprint slips, and Feature %-done movement.</p>
    </div>
  </div>
  <div class="changes-grid">{changes_inner}</div>
</section>
"""
else:
    changes_html = """
<section class="changes">
  <div class="changes-head">
    <div>
      <h2>What changed since last refresh</h2>
      <p class="changes-sub">First run with baseline tracking enabled. The next refresh will diff against today's snapshot and surface adds, completions, sprint slips, and Feature %-done deltas.</p>
    </div>
  </div>
</section>
"""

toolbar_html = """
<div class="toolbar">
  <input type="search" id="search" placeholder="Search title, owner, ID…">
  <select id="areaFilter">
    <option value="">All areas</option>
  </select>
  <select id="stateFilter">
    <option value="">All states</option>
    <option>New</option>
    <option>Committed</option>
    <option>Done</option>
  </select>
  <div class="filter-group">
    <button class="filter-btn on" data-cut="any">All</button>
    <button class="filter-btn" data-cut="above">Above cutline</button>
    <button class="filter-btn" data-cut="below">Stretch</button>
  </div>
  <div class="filter-group">
    <button class="filter-btn" data-risk="risk-empty" title="Committed but no PBI breakdown">⚠ no breakdown</button>
    <button class="filter-btn" data-risk="risk-stalled" title="No task progress yet">⏸ stalled</button>
  </div>
  <span class="spacer"></span>
  <span class="count" id="count"></span>
  <button class="theme-toggle" id="themeToggle" title="Toggle theme">◐</button>
</div>
"""

js_block = """
<script>
(() => {
  const search = document.getElementById('search');
  const areaSel = document.getElementById('areaFilter');
  const stateSel = document.getElementById('stateFilter');
  const cutBtns = document.querySelectorAll('.filter-btn[data-cut]');
  const riskBtns = document.querySelectorAll('.filter-btn[data-risk]');
  const countEl = document.getElementById('count');
  const features = Array.from(document.querySelectorAll('.feature'));
  const areas = [...new Set(features.map(f => f.dataset.area))].sort();
  areas.forEach(a => {
    const o = document.createElement('option'); o.value = a; o.textContent = a; areaSel.appendChild(o);
  });

  let cutMode = 'any';
  let activeRisks = new Set();

  cutBtns.forEach(b => b.addEventListener('click', () => {
    cutBtns.forEach(x => x.classList.remove('on'));
    b.classList.add('on');
    cutMode = b.dataset.cut;
    apply();
  }));
  riskBtns.forEach(b => b.addEventListener('click', () => {
    b.classList.toggle('on');
    if (b.classList.contains('on')) activeRisks.add(b.dataset.risk);
    else activeRisks.delete(b.dataset.risk);
    apply();
  }));
  [search, areaSel, stateSel].forEach(el => el.addEventListener('input', apply));

  function apply() {
    const q = (search.value || '').toLowerCase();
    const area = areaSel.value;
    const state = stateSel.value;
    let shown = 0;
    features.forEach(f => {
      const txt = f.textContent.toLowerCase();
      let ok = true;
      if (q && !txt.includes(q)) ok = false;
      if (area && f.dataset.area !== area) ok = false;
      if (state && f.dataset.state !== state) ok = false;
      if (cutMode !== 'any' && f.dataset.cut !== cutMode) ok = false;
      if (activeRisks.size > 0 && !activeRisks.has(f.dataset.risk)) ok = false;
      f.style.display = ok ? '' : 'none';
      if (ok) shown++;
    });
    document.querySelectorAll('.area-section').forEach(s => {
      const visible = s.querySelectorAll('.feature:not([style*="display: none"])').length;
      s.style.display = visible ? '' : 'none';
    });
    countEl.textContent = `${shown} of ${features.length} features`;
  }
  apply();

  document.getElementById('themeToggle').addEventListener('click', () => {
    const cur = document.documentElement.getAttribute('data-theme');
    document.documentElement.setAttribute('data-theme', cur === 'dark' ? 'light' : 'dark');
  });
})();
</script>
"""

FOOT = f"""
<footer>Drafted by Nirvana on Nir's behalf · ADO snapshot {esc(stamp)} · click any feature card to open in ADO · sources: Your Manager's plan + your-ado-org/One</footer>
</div>
</body></html>
"""

# Assemble: hero + toolbar + sections (cutline divider between above/below if both present)
above_sections = []
below_sections = []
for area in sorted_areas:
    feats = by_area[area]
    has_above = any(f["above_cut"] for f in feats)
    has_below = any(not f["above_cut"] for f in feats)
    if has_above and not has_below:
        above_sections.append(area)
    elif has_below and not has_above:
        below_sections.append(area)
    else:
        above_sections.append(area)

# Single rendering pass — sections already include all features for that area;
# the cutline distinction is per-feature via data-cut attribute (visual de-emphasis + filter)
body_sections = "\n".join(section_html)

out = HEAD + hero_html + capacity_html + changes_html + toolbar_html + body_sections + js_block + FOOT
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(out, encoding="utf-8")

# Persist today's snapshot for the next run's diff (idempotent overwrite).
try:
    snap_target = SNAPSHOT_DIR / f"{TODAY_ISO}.json"
    shutil.copy(STATE / "all-items.json", snap_target)
    snap_msg = f"snapshot: {snap_target.name}"
except Exception as e:
    snap_msg = f"snapshot FAILED: {e}"

print(f"wrote {OUT}  ({OUT.stat().st_size:,} bytes)")
print(f"  features: {total_features}  pbis: {sum(len(f['pbis']) for f in features)}  pbis-done: {all_pbis_done}/{all_pbis_total} ({overall_pct:.1f}%)  time-elapsed: {sem_pct_time:.1f}%  verdict: {verdict[1]}")
print(f"  capacity: commit={COMMIT_PW:.2f} PW  budget={BUDGET_PW:.2f} PW  over={OVER_PW:+.2f} PW  in-flight={pw_in_flight_total:.1f} PW  target@today={pw_target_at_today:.1f} PW  pace={capacity_verdict[1]}")
print(f"  s-curve: target={pw_target_scurve:.1f} PW  actual={pw_in_flight_total:.1f} PW  ratio={pace_ratio_scurve*100:.0f}% ({pace_verdict_color})")
print(f"  diff vs {diff['prior_date'] or '(none)'}: added={len(diff['added'])} removed={len(diff['removed'])} completed={len(diff['completed'])} slipped={len(diff['slipped'])} pulled_in={len(diff['pulled_in'])} pct_moves={len(diff['feature_pct_delta'])}")
print(f"  {snap_msg}")

