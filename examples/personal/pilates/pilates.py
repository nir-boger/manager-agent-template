"""pilates — CLI for booking Wellbe / Arbox classes from Nirvana.

Subcommands:
    list   [--days N] [--name FRAGMENT] [--day Mon..Sun] [--time HH:MM]
    status                              # currently booked / waitlisted (text)
    upcoming                            # alias for status, with day-of-week labels
    book   --id <schedule_id>           # PREVIEW (default)
    book   --id <schedule_id> --confirm BOOK   # actually book
    cancel --id <schedule_user_id> --schedule <schedule_id>
           [--confirm CANCEL]
    sync                                # refresh state.json from API; mark
                                        # cancelled-by-user bookings
    register-target --target-id <id> [--wait] [--confirm BOOK]
                                        # full automation: target → next class,
                                        # respects user cancellations, waits
                                        # for registration window if --wait,
                                        # skips classes < 5 min away,
                                        # sends email on success
    poll-target ...   (kept for ad-hoc dry-runs; superseded by register-target)
    book-target ...   (kept for ad-hoc dry-runs; superseded by register-target)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

from arbox import (
    ALREADY_BOOKED,
    ALREADY_WAITLISTED,
    BOOK_OPEN,
    PAST,
    WAITLIST_OPEN,
    ArboxClient,
    ArboxError,
    class_label,
)
import state as state_mod
import email_helpers

HERE = Path(__file__).parent
CONFIG_PATH = HERE / "config.json"
STATE_PATH = HERE / "state.json"
TARGETS_PATH = HERE / "targets.json"

DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
DAY_NAMES_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday",
                  "Thursday", "Friday", "Saturday"]
DAY_LOOKUP = {d.lower(): i for i, d in enumerate(DAY_NAMES)}
DAY_LOOKUP.update({"sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
                   "thursday": 4, "friday": 5, "saturday": 6})

# Edge case: never try to book a class that's less than this many minutes
# away. Wellbe's `disable_cancellation_time` is 2h, so the system-design
# answer here is "well before that anyway". 5 min is paranoia floor.
MIN_LEAD_MINUTES = 5


def parse_day(s: str) -> int:
    s = s.strip().lower()
    if s.isdigit():
        return int(s) % 7
    if s not in DAY_LOOKUP:
        raise ValueError(f"unknown day: {s}")
    return DAY_LOOKUP[s]


def session_dow(s: dict) -> int:
    """Day-of-week 0=Sun..6=Sat from the schedule date."""
    d = datetime.strptime(s["date"], "%Y-%m-%d").date()
    py = d.weekday()  # Mon=0..Sun=6
    return (py + 1) % 7


def session_dt(s: dict) -> datetime:
    return datetime.strptime(f"{s['date']} {s['time']}", "%Y-%m-%d %H:%M")


def filter_classes(classes: list[dict], *, name: str | None = None,
                   day: int | None = None, time_hhmm: str | None = None,
                   include_past: bool = False) -> list[dict]:
    out = []
    rx = re.compile(name, re.IGNORECASE) if name else None
    for c in classes:
        if not include_past and c.get("booking_option") == PAST:
            continue
        if rx and not rx.search((c.get("box_categories") or {}).get("name", "")):
            continue
        if day is not None and session_dow(c) != day:
            continue
        if time_hhmm and c.get("time") != time_hhmm:
            continue
        out.append(c)
    return out


def load_targets() -> list[dict]:
    if not TARGETS_PATH.exists():
        return []
    data = json.loads(TARGETS_PATH.read_text(encoding="utf-8"))
    targets = data.get("targets", []) if isinstance(data, dict) else data
    return [t for t in targets if t.get("enabled", True)]


def find_target(target_id: str) -> dict | None:
    for t in load_targets():
        if t.get("id") == target_id:
            return t
    return None


# --- subcommands ----------------------------------------------------------

def cmd_list(client: ArboxClient, args: argparse.Namespace) -> int:
    classes = client.list_schedule_window(args.days)
    day = parse_day(args.day) if args.day else None
    matches = filter_classes(classes, name=args.name, day=day,
                             time_hhmm=args.time, include_past=args.include_past)
    if not matches:
        print("(no matching classes)")
        return 0
    for c in matches:
        booked = "✓" if c.get("user_booked") else (
            "W" if c.get("user_in_standby") else " ")
        free = c.get("free", 0)
        cap = c.get("max_users", 0)
        regd = c.get("registered", 0)
        opt = c.get("booking_option", "?")
        print(f"  [{booked}] id={c['id']:>9}  {c['date']} ({DAY_NAMES[session_dow(c)]}) "
              f"{c['time']}-{c['end_time']}  "
              f"{(c.get('box_categories') or {}).get('name'):<22} "
              f"coach={(c.get('coach') or {}).get('full_name', '?'):<22} "
              f"free={free}/{cap} reg={regd}  state={opt}")
    return 0


def cmd_status(client: ArboxClient, args: argparse.Namespace) -> int:
    classes = client.list_schedule_window(args.days)
    booked = [c for c in classes if c.get("user_booked")]
    waiting = [c for c in classes if c.get("user_in_standby")]
    print(f"=== Booked ({len(booked)}) ===")
    for c in booked:
        print(f"  {class_label(c)}  schedule_id={c['id']}  "
              f"schedule_user_id={c.get('user_booked')}")
    print(f"\n=== Waitlist ({len(waiting)}) ===")
    for c in waiting:
        print(f"  {class_label(c)}  schedule_id={c['id']}  "
              f"stand_by_id={c.get('user_in_standby')}  pos={c.get('stand_by_position')}")
    return 0


def cmd_upcoming(client: ArboxClient, args: argparse.Namespace) -> int:
    """Pretty-print upcoming bookings — what Nir gets when he asks
    'show me my upcoming pilates registrations'."""
    classes = client.list_schedule_window(args.days)
    classes_by_dt = sorted(
        [c for c in classes if c.get("user_booked") or c.get("user_in_standby")],
        key=session_dt,
    )
    if not classes_by_dt:
        print("(no upcoming pilates bookings)")
        return 0
    for c in classes_by_dt:
        dow = DAY_NAMES_FULL[session_dow(c)]
        name = (c.get("box_categories") or {}).get("name", "?")
        coach = (c.get("coach") or {}).get("full_name", "?")
        if c.get("user_booked"):
            mark = "BOOKED"
        else:
            pos = c.get("stand_by_position")
            mark = f"WAITLIST #{pos}"
        print(f"  {mark:<14}  {dow:<10}  {c['date']}  {c['time']}-{c['end_time']}  "
              f"{name}  ({coach})")
    return 0


def cmd_book(client: ArboxClient, args: argparse.Namespace) -> int:
    classes = client.list_schedule_window(14)
    target = next((c for c in classes if c["id"] == int(args.id)), None)
    if not target:
        print(f"ERROR: schedule_id {args.id} not found in next 14 days")
        return 2
    print(f"Target: {class_label(target)}")
    print(f"  state={target.get('booking_option')}  "
          f"free={target.get('free')}/{target.get('max_users')}")
    if target.get("booking_option") in (ALREADY_BOOKED, ALREADY_WAITLISTED):
        print("  → already booked / waitlisted; nothing to do")
        return 0
    if args.confirm != "BOOK":
        print('  PREVIEW ONLY — re-run with --confirm BOOK to actually register')
        return 0
    return _attempt_book(client, target, allow_waitlist=args.waitlist)


def _attempt_book(client: ArboxClient, target: dict,
                  allow_waitlist: bool) -> int:
    sid = int(target["id"])
    opt = target.get("booking_option")
    try:
        if opt == BOOK_OPEN:
            client.book(sid)
            print(f"  ✓ booked (schedule_id={sid})")
            return 0
        if opt == WAITLIST_OPEN and allow_waitlist:
            client.join_waitlist(sid)
            print(f"  ✓ waitlisted (schedule_id={sid})")
            return 0
        print(f"  ✗ class state {opt} is not bookable right now")
        return 3
    except ArboxError as e:
        # The API returns 425 with "alreadyRegistered" when we attempt to book
        # a class we've already booked — treat as success.
        if e.status == 425 and "alreadyRegistered" in (e.body or ""):
            print(f"  ✓ already registered (schedule_id={sid})")
            return 0
        print(f"  ✗ API error: status={e.status} code={e.code}")
        print(f"    body: {e.body[:400]}")
        return 4


def cmd_cancel(client: ArboxClient, args: argparse.Namespace) -> int:
    sched_id = int(args.schedule)
    user_id = int(args.id)
    if args.confirm != "CANCEL":
        print(f"PREVIEW: would cancel schedule_user_id={user_id} (schedule_id={sched_id})")
        print('  re-run with --confirm CANCEL to actually cancel')
        return 0
    try:
        client.cancel(user_id, sched_id)
        print(f"  ✓ cancelled")
        # Mark in state too
        st = state_mod.load(STATE_PATH)
        entry = st["tracked"].get(str(sched_id))
        if entry is not None:
            entry["cancelled_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
            state_mod.save(STATE_PATH, st)
        return 0
    except ArboxError as e:
        print(f"  ✗ {e}")
        return 4


def cmd_sync(client: ArboxClient, args: argparse.Namespace) -> int:
    """Refresh state.json by comparing tracked bookings with API truth.
    Marks user-cancelled bookings, refreshes schedule_user_ids."""
    st = state_mod.load(STATE_PATH)
    classes = client.list_schedule_window(args.days)
    just_cancelled = state_mod.sync_cancellations(st, classes)
    state_mod.save(STATE_PATH, st)
    if just_cancelled:
        print(f"=== Detected {len(just_cancelled)} user-cancelled booking(s) ===")
        for e in just_cancelled:
            print(f"  - {e.get('class_name')} {e.get('date')} {e.get('time')} "
                  f"(schedule_id={e.get('schedule_id')})")
        print("  These will NOT be re-registered automatically.")
    else:
        print("(no changes — all tracked bookings still active)")
    return 0


def find_target_match(classes: list[dict], *, name: str, day: int,
                      time_hhmm: str, on_or_after: datetime | None = None,
                      strict_match: bool = False) -> dict | None:
    matches = filter_classes(classes, name=name, day=day, time_hhmm=time_hhmm)
    if strict_match:
        # Require exact name equality (case-insensitive, trimmed)
        target_name_lower = name.strip().lower()
        matches = [
            m for m in matches
            if (m.get("box_categories") or {}).get("name", "").strip().lower()
               == target_name_lower
        ]
    if on_or_after is not None:
        matches = [m for m in matches if session_dt(m) >= on_or_after]
    if not matches:
        return None
    matches.sort(key=session_dt)
    return matches[0]


def cmd_book_target(client: ArboxClient, args: argparse.Namespace) -> int:
    day = parse_day(args.day)
    classes = client.list_schedule_window(args.days)
    target = find_target_match(classes, name=args.name, day=day,
                               time_hhmm=args.time)
    if not target:
        print(f"(no upcoming match for name~={args.name!r} day={args.day} time={args.time})")
        return 1
    print(f"Match: {class_label(target)}  schedule_id={target['id']}")
    print(f"  state={target.get('booking_option')}  "
          f"free={target.get('free')}/{target.get('max_users')}")
    if target.get("booking_option") in (ALREADY_BOOKED, ALREADY_WAITLISTED):
        print("  → already booked / waitlisted; nothing to do")
        return 0
    if args.confirm != "BOOK":
        print('  PREVIEW ONLY — re-run with --confirm BOOK to actually register')
        return 0
    return _attempt_book(client, target, allow_waitlist=args.waitlist)


def cmd_poll_target(client: ArboxClient, args: argparse.Namespace) -> int:
    day = parse_day(args.day)
    deadline = datetime.now() + timedelta(seconds=args.max_seconds)
    attempt = 0
    while datetime.now() < deadline:
        attempt += 1
        try:
            classes = client.list_schedule_window(args.days)
            target = find_target_match(classes, name=args.name, day=day,
                                       time_hhmm=args.time)
            if target:
                opt = target.get("booking_option")
                state_label = f"state={opt} free={target.get('free')}/{target.get('max_users')}"
                print(f"[{datetime.now().isoformat(timespec='seconds')}] "
                      f"attempt #{attempt}  id={target['id']}  {state_label}")
                if opt in (ALREADY_BOOKED, ALREADY_WAITLISTED):
                    print(f"  ✓ already booked / waitlisted")
                    return 0
                if opt == BOOK_OPEN:
                    if args.confirm != "BOOK":
                        print('  PREVIEW: would book now')
                        return 0
                    rc = _attempt_book(client, target, allow_waitlist=args.waitlist)
                    if rc == 0:
                        return 0
                elif opt == WAITLIST_OPEN and args.waitlist:
                    if args.confirm != "BOOK":
                        print('  PREVIEW: would waitlist now')
                        return 0
                    rc = _attempt_book(client, target, allow_waitlist=True)
                    if rc == 0:
                        return 0
            else:
                print(f"[{datetime.now().isoformat(timespec='seconds')}] "
                      f"attempt #{attempt}  no target match yet")
        except ArboxError as e:
            print(f"[{datetime.now().isoformat(timespec='seconds')}] "
                  f"attempt #{attempt}  API error {e.status} {e.code}")
        time.sleep(args.interval)
    print(f"timed out after {attempt} attempts")
    return 5


# --- register-target — the production-grade automation -------------------

def _next_class_dt_for_target(t: dict, *, now: datetime) -> datetime:
    """Compute the next class datetime for a target.

    For a recurring slot (day_of_week, time), the "next" class is the soonest
    occurrence that's still in the future at `now`.

    Tied to the registration window: when this is invoked, registration may
    already be open for the upcoming-week slot or about to open.
    """
    target_dow = int(t["day_of_week"])
    hh, mm = [int(x) for x in t["time"].split(":")]
    # Today as 0=Sun..6=Sat
    today_dow = (now.weekday() + 1) % 7
    days_ahead = (target_dow - today_dow) % 7
    candidate = (now.replace(hour=hh, minute=mm, second=0, microsecond=0)
                 + timedelta(days=days_ahead))
    if candidate <= now:
        candidate = candidate + timedelta(days=7)
    return candidate


def _registration_open_dt(class_dt: datetime, lead_hours: int) -> datetime:
    return class_dt - timedelta(hours=lead_hours)


def _send_failure_email(args, *, name: str, target_class: dict | None,
                        reason: str) -> None:
    """Notify Nir when a scheduled booking attempt definitively failed.
    Best-effort — never raises."""
    if args.no_email:
        return
    when = ""
    if target_class:
        when = (f" on {DAY_NAMES_FULL[session_dow(target_class)]} "
                f"{target_class.get('date')} at {target_class.get('time')}")
    body = (
        f"<p>Auto-booking <strong>{name}</strong>{when} did not go through.</p>"
        f"<p><strong>Reason:</strong> {reason}</p>"
        f"<p>I won't retry until the next scheduled run. "
        f"If you want me to try again, run "
        f"<code>pilates.ps1 register-target --target-id {args.target_id} "
        f"--confirm BOOK</code>.</p>"
    )
    subj = f"Pilates: auto-book FAILED for {name}"
    email_helpers.send_confirmation_email(
        subject=subj, body_html=body,
        to_addr=args.email_to,
        no_joke=args.no_joke, no_sig=False,
    )


def cmd_register_target(client: ArboxClient, args: argparse.Namespace) -> int:
    """Full automation flow.

    Resolves a target → the next class, respects user cancellations, optionally
    waits for the registration window to open, polls until book succeeds, and
    sends an email confirmation. Designed to run unattended from the per-slot
    scheduled task, e.g. every Monday at 10:59:50 to register for next Monday's
    10:00 class.
    """
    target = find_target(args.target_id)
    if target is None:
        print(f"ERROR: target id {args.target_id!r} not found in targets.json")
        return 2
    if not target.get("enabled", True):
        print(f"target {args.target_id} is disabled — exiting")
        return 0

    name = target["name"]
    target_dow = int(target["day_of_week"])
    target_time = target["time"]
    lead_hours = int(target.get("registration_lead_hours", 167))
    join_wait = bool(target.get("join_waitlist", True))

    now = datetime.now()
    class_dt = _next_class_dt_for_target(target, now=now)
    open_dt = _registration_open_dt(class_dt, lead_hours)
    print(f"target={args.target_id} → next class: {class_dt.isoformat(timespec='minutes')} "
          f"({DAY_NAMES_FULL[target_dow]} {target_time} {name})")
    print(f"  registration opened: {open_dt.isoformat(timespec='minutes')} "
          f"(lead {lead_hours}h)")

    # Edge case: class is too close to now — don't try
    if class_dt - now < timedelta(minutes=MIN_LEAD_MINUTES):
        print(f"  ✗ class is < {MIN_LEAD_MINUTES} min away ({class_dt - now}); skipping")
        return 6

    # Step 1: sync cancellations BEFORE we look for the class. This catches
    # any "user cancelled my booking" since the last run.
    sync_classes = client.list_schedule_window(args.days)
    st = state_mod.load(STATE_PATH)
    state_mod.sync_cancellations(st, sync_classes)
    state_mod.save(STATE_PATH, st)

    # Step 2: find the target class via the SAME schedule fetch (no need
    # to re-hit the API). We require strict name match so we don't book the
    # wrong "Pilates Mat" instead of "Reformer Pilates" — a target row's
    # name is the source of truth.
    target_class = find_target_match(sync_classes, name=name,
                                     day=target_dow, time_hhmm=target_time,
                                     on_or_after=now, strict_match=True)
    if target_class is None:
        if args.wait:
            # Class may not be published yet — gym typically publishes ~1 week
            # ahead. Don't bail; fall through to wait + poll. Even if we're
            # already past open_dt (slow gym publish), continue polling.
            print(f"  - no class visible yet; will wait+poll for it to publish")
        else:
            print(f"  ✗ no class matching {name!r} on {DAY_NAMES_FULL[target_dow]} "
                  f"at {target_time} found in next {args.days} days")
            return 7

    # Step 3: cancellation check — if Nir cancelled this class previously,
    # we DO NOT re-register.
    if target_class is not None and state_mod.is_cancelled(st, int(target_class["id"])):
        print(f"  ✗ schedule_id={target_class['id']} was cancelled by user "
              f"on {st['tracked'][str(target_class['id'])].get('cancelled_at')}; "
              f"NOT re-registering")
        return 8

    # Step 4: already-booked check
    if target_class is not None and target_class.get("booking_option") in (
            ALREADY_BOOKED, ALREADY_WAITLISTED):
        print(f"  → already booked/waitlisted; recording in state")
        state_mod.record_booking(
            st,
            schedule_id=int(target_class["id"]),
            class_name=(target_class.get("box_categories") or {}).get("name", name),
            coach=(target_class.get("coach") or {}).get("full_name"),
            date=target_class["date"],
            time=target_class["time"],
            target_id=args.target_id,
            schedule_user_id=target_class.get("user_booked")
                              or target_class.get("user_in_standby"),
        )
        state_mod.save(STATE_PATH, st)
        return 0

    # Step 5: wait for the registration window if requested
    if args.wait and now < open_dt:
        wait_seconds = (open_dt - now).total_seconds()
        # Aim for `pre_fire_seconds` early — i.e. at open_dt - pre_fire
        wake_dt = open_dt - timedelta(seconds=args.pre_fire_seconds)
        wait_to_wake = (wake_dt - datetime.now()).total_seconds()
        if wait_to_wake > 0:
            # Cap wait at args.max_wait_seconds (safety: scheduled task is
            # supposed to fire close to open time anyway)
            if wait_to_wake > args.max_wait_seconds:
                print(f"  ✗ registration opens in {wait_to_wake:.0f}s > "
                      f"max_wait {args.max_wait_seconds}s; skipping")
                return 9
            print(f"  - waiting {wait_to_wake:.1f}s for registration window...")
            time.sleep(wait_to_wake)

    if args.confirm != "BOOK":
        print('  PREVIEW ONLY — re-run with --confirm BOOK to actually register')
        return 0

    # Step 6: poll-and-book until success or timeout
    poll_deadline = datetime.now() + timedelta(seconds=args.max_seconds)
    attempt = 0
    booked_class: dict | None = None
    while datetime.now() < poll_deadline:
        attempt += 1
        try:
            classes = client.list_schedule_window(args.days)
            tc = find_target_match(classes, name=name, day=target_dow,
                                   time_hhmm=target_time, on_or_after=now,
                                   strict_match=True)
        except ArboxError as e:
            print(f"[{datetime.now().isoformat(timespec='seconds')}] "
                  f"attempt #{attempt}  list error {e.status} {e.code}: "
                  f"{(e.body or '')[:200]}")
            time.sleep(args.interval)
            continue

        if tc is None:
            print(f"[{datetime.now().isoformat(timespec='seconds')}] "
                  f"attempt #{attempt}  no class visible yet")
            time.sleep(args.interval)
            continue

        sid = int(tc["id"])

        # CRITICAL: re-check cancellation here too — class may have been
        # invisible at step 2/3 but visible now. Never re-register a cancelled
        # schedule_id.
        if state_mod.is_cancelled(st, sid):
            print(f"  ✗ schedule_id={sid} was cancelled by user "
                  f"on {st['tracked'][str(sid)].get('cancelled_at')}; "
                  f"NOT re-registering")
            return 8

        opt = tc.get("booking_option")
        print(f"[{datetime.now().isoformat(timespec='seconds')}] "
              f"attempt #{attempt}  id={sid}  state={opt} "
              f"free={tc.get('free')}/{tc.get('max_users')}")

        if opt in (ALREADY_BOOKED, ALREADY_WAITLISTED):
            booked_class = tc
            break

        try:
            if opt == BOOK_OPEN:
                client.book(sid)
                print(f"  ✓ booked (schedule_id={sid})")
                booked_class = tc
                break
            elif opt == WAITLIST_OPEN and join_wait:
                client.join_waitlist(sid)
                print(f"  ✓ waitlisted (schedule_id={sid})")
                booked_class = tc
                break
            else:
                # Not bookable yet (registration not open, or full + no waitlist).
                # Keep polling — opt may flip to BOOK_OPEN once server time
                # crosses the registration window.
                pass
        except ArboxError as e:
            body = e.body or ""
            # 425 alreadyRegistered = success (race-condition self-conflict)
            if e.status == 425 and "alreadyRegistered" in body:
                print(f"  ✓ already registered (race)")
                booked_class = tc
                break
            # 425 categoryFrequencyRestricts = membership cap reached
            if e.status == 425 and "categoryFrequencyRestricts" in body:
                print(f"  ! membership limit reached for category {name!r} — skipping")
                _send_failure_email(args, name=name, target_class=tc,
                                    reason="Membership frequency limit reached "
                                           "(already at the cap for this category today/week).")
                return 10
            # Other API errors — log and keep retrying within deadline
            print(f"  ✗ API error {e.status} {e.code}: {body[:200]}")

        time.sleep(args.interval)
    else:
        print(f"  ✗ timed out after {attempt} attempts ({args.max_seconds}s)")
        _send_failure_email(args, name=name, target_class=None,
                            reason=f"Polling timed out after {args.max_seconds}s "
                                   f"({attempt} attempts). Class may have filled "
                                   f"before booking succeeded, or registration "
                                   f"never opened during the polling window.")
        return 5

    if booked_class is None:
        print(f"  ✗ booking did not succeed within deadline")
        _send_failure_email(args, name=name, target_class=None,
                            reason="Booking loop exited without a confirmed booking.")
        return 5

    # Step 7: record in state
    sid = int(booked_class["id"])
    state_mod.record_booking(
        st,
        schedule_id=sid,
        class_name=(booked_class.get("box_categories") or {}).get("name", name),
        coach=(booked_class.get("coach") or {}).get("full_name"),
        date=booked_class["date"],
        time=booked_class["time"],
        target_id=args.target_id,
        schedule_user_id=booked_class.get("user_booked")
                          or booked_class.get("user_in_standby"),
    )
    state_mod.save(STATE_PATH, st)

    # Step 8: send the email confirmation
    if not args.no_email and not state_mod.email_already_sent(st, sid):
        all_classes = client.list_schedule_window(args.days)
        all_booked = sorted(
            [c for c in all_classes if c.get("user_booked")],
            key=session_dt,
        )
        all_waiting = sorted(
            [c for c in all_classes if c.get("user_in_standby")],
            key=session_dt,
        )
        body = email_helpers.render_confirmation_html(
            just_booked=booked_class,
            upcoming=all_booked,
            waitlist=all_waiting,
            joke_line=args.joke_line,
        )
        subj = (f"Pilates: registered for {(booked_class.get('box_categories') or {}).get('name', name)} "
                f"on {booked_class['date']} at {booked_class['time']}")
        ok = email_helpers.send_confirmation_email(
            subject=subj, body_html=body,
            to_addr=args.email_to,
            no_joke=args.no_joke, no_sig=False,
        )
        if ok:
            state_mod.mark_email_sent(st, sid)
            state_mod.save(STATE_PATH, st)
    return 0


# --- argparse -------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="pilates", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="list classes")
    p_list.add_argument("--days", type=int, default=14)
    p_list.add_argument("--name")
    p_list.add_argument("--day")
    p_list.add_argument("--time")
    p_list.add_argument("--include-past", action="store_true")
    p_list.set_defaults(fn=cmd_list)

    p_st = sub.add_parser("status", help="show current bookings (raw)")
    p_st.add_argument("--days", type=int, default=21)
    p_st.set_defaults(fn=cmd_status)

    p_up = sub.add_parser("upcoming", help="pretty-print upcoming bookings")
    p_up.add_argument("--days", type=int, default=21)
    p_up.set_defaults(fn=cmd_upcoming)

    p_b = sub.add_parser("book", help="book a class by schedule_id")
    p_b.add_argument("--id", required=True)
    p_b.add_argument("--confirm")
    p_b.add_argument("--waitlist", action="store_true",
                     help="if class full, fall back to waitlist")
    p_b.set_defaults(fn=cmd_book)

    p_c = sub.add_parser("cancel", help="cancel a booking")
    p_c.add_argument("--id", required=True, help="schedule_user_id (from `status`)")
    p_c.add_argument("--schedule", required=True, help="schedule_id")
    p_c.add_argument("--confirm")
    p_c.set_defaults(fn=cmd_cancel)

    p_sync = sub.add_parser("sync", help="refresh state.json from API")
    p_sync.add_argument("--days", type=int, default=21)
    p_sync.set_defaults(fn=cmd_sync)

    p_t = sub.add_parser("book-target", help="(legacy) book the next class matching name/day/time")
    p_t.add_argument("--name", required=True)
    p_t.add_argument("--day", required=True, help="Sun..Sat or 0..6 (0=Sun)")
    p_t.add_argument("--time", required=True, help="HH:MM")
    p_t.add_argument("--days", type=int, default=14)
    p_t.add_argument("--waitlist", action="store_true")
    p_t.add_argument("--confirm")
    p_t.set_defaults(fn=cmd_book_target)

    p_p = sub.add_parser("poll-target", help="(legacy) poll until a target booking succeeds")
    p_p.add_argument("--name", required=True)
    p_p.add_argument("--day", required=True)
    p_p.add_argument("--time", required=True)
    p_p.add_argument("--days", type=int, default=14)
    p_p.add_argument("--interval", type=float, default=1.0)
    p_p.add_argument("--max-seconds", type=int, default=120)
    p_p.add_argument("--waitlist", action="store_true")
    p_p.add_argument("--confirm")
    p_p.set_defaults(fn=cmd_poll_target)

    p_rt = sub.add_parser("register-target",
                          help="full automation: resolve target → next class, "
                               "respect cancellations, wait for window, book, email")
    p_rt.add_argument("--target-id", required=True,
                      help="id from targets.json (e.g. mon-10)")
    p_rt.add_argument("--days", type=int, default=14)
    p_rt.add_argument("--wait", action="store_true",
                      help="wait until registration window opens (vs. failing fast)")
    p_rt.add_argument("--max-wait-seconds", type=int, default=300,
                      help="max time to wait for the registration window (safety)")
    p_rt.add_argument("--pre-fire-seconds", type=float, default=2.0,
                      help="how many seconds before the open time to wake (default 2)")
    p_rt.add_argument("--max-seconds", type=int, default=120,
                      help="how long to keep polling once window is open")
    p_rt.add_argument("--interval", type=float, default=0.75,
                      help="seconds between poll attempts")
    p_rt.add_argument("--confirm")
    p_rt.add_argument("--no-email", action="store_true",
                      help="skip the confirmation email")
    p_rt.add_argument("--email-to", default="you@example.com")
    p_rt.add_argument("--joke-line",
                      help="optional joke text appended to the email body")
    p_rt.add_argument("--no-joke", action="store_true")
    p_rt.set_defaults(fn=cmd_register_target)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not CONFIG_PATH.exists():
        print(f"ERROR: missing {CONFIG_PATH}", file=sys.stderr)
        return 1
    client = ArboxClient.from_config(CONFIG_PATH)
    return args.fn(client, args)


if __name__ == "__main__":
    sys.exit(main())

