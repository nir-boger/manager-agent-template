# pilates — auto-book Wellbe (Arbox) classes

## Purpose
Keep Nir's standing Pilates booking lineup full without his attention. The Wellbe Android app is just an Arbox-branded client — we talk to the underlying Arbox member REST API directly so we can react in milliseconds when registration opens.

Currently registers him for **Reformer Pilates every Mon and Wed at 10:00**. Adding more slots = one row in `targets.json` + a single re-run of `register-tasks.ps1`.

## Trigger phrases (match any case-insensitively)
- `show me my upcoming pilates registrations` → `pilates.ps1 upcoming`
- `pilates status` → `pilates.ps1 status`
- `register me for pilates` → confirm scope first; usually means **just run `register-tasks.ps1` if not already**, otherwise shells `register-target --target-id <slot> --confirm BOOK`
- `cancel pilates` → take a confirmation, then run `pilates.ps1 cancel --id <schedule_user_id> --schedule <schedule_id> --confirm CANCEL`. Mark `cancelled_at` in state so we don't re-book.
- `list pilates classes` / `list pilates [--day Wed --time 10:00]` → `pilates.ps1 list --name "Pilates" --days 14`
- `add a pilates target` → edit `targets.json` then re-run `register-tasks.ps1`

## How automation works
| Slot | Class | Registration opens | Scheduled task fires |
|---|---|---|---|
| `mon-10` | Reformer Pilates Mon 10:00 | Mon 11:00 prior week | `DM-PilatesAuto-mon-10` Mon 10:59:50 |
| `wed-10` | Reformer Pilates Wed 10:00 | Wed 11:00 prior week | `DM-PilatesAuto-wed-10` Wed 10:59:50 |

Wellbe's `enable_registration_time` field is `167` hours — exactly 1 week minus 1 hour. So a 10:00 class on `<day>` opens at 11:00 the same `<day>` the previous week. Tasks fire 10s early, then `register-target --wait` polls at 0.5s intervals until `scheduleUser/insert` returns 200.

## Hard rules
1. **Respect cancellations.** `state.json[<schedule_id>].cancelled_at` is set whenever a sync detects the booking is no longer present in the API. `register-target` refuses to re-register a `cancelled_at`-marked schedule. The user is the source of truth — never override.
2. **Edge case: too close.** Skip booking if the class is < 5 minutes away (`MIN_LEAD_MINUTES`).
3. **Idempotent.** `state.json` keys by `schedule_id`. Re-running `register-target` for an already-booked class just records it; no double-register attempts.
4. **Treat `425 alreadyRegistered` as success.** Race-condition safe.
5. **Preview-first writes.** `book` and `cancel` require a literal `--confirm BOOK` / `--confirm CANCEL` token, just like the `whatsapp` skill.
6. **No silent surprises.** `register-target` only books classes whose `box_categories.name` strictly matches the target row's `name` (case-insensitive).
7. **Email on every successful registration** (unless `--no-email`). Includes the booked class plus a table of all upcoming Pilates bookings + a one-line joke per the playbook + the canonical Nirvana signature.

## Files
```
examples/personal/pilates/
├── SKILL.md                # this file
├── arbox.py                # Arbox API client (siteLogin / list / book / cancel)
├── pilates.py              # CLI entry — list, status, upcoming, book, cancel,
│                           #   sync, register-target, book-target, poll-target
├── pilates.ps1             # PowerShell wrapper (auto-installs deps once)
├── email_helpers.py        # render_confirmation_html + send_confirmation_email
├── send-email.ps1          # Outlook COM dispatcher (uses _shared/signature.ps1)
├── state.py                # state.json load/save/sync helpers
├── targets.json            # standing wishlist (committed; no PII)
├── register-tasks.ps1      # idempotent scheduled-task installer
└── requirements.txt        # requests, python-dateutil
```

> **Note (Phase 4 of templatize-Nirvana):** the skill moved here from
> `.copilot/skills/pilates/` on 2026-05-05. A forwarder remains at the old
> path so the existing `DM-PilatesAuto-mon-10` / `DM-PilatesAuto-wed-10`
> scheduled tasks keep working without re-registration. Re-running
> `register-tasks.ps1` from this folder will rewrite the tasks to point
> here directly (the forwarder remains valid either way).

Gitignored alongside (per `.gitignore`):
```
examples/personal/pilates/config.json   # email, password, box ids, membership id, tokens
examples/personal/pilates/state.json    # bookings + cancellation tracking
examples/personal/pilates/.deps-installed
reports/pilates/*.lock
```

## Setup (one-time)
1. Ensure `config.json` exists with the cracked-auth field set (see plan.md / checkpoint history; key fields: `user.email`, `user.password`, `box.id`, `box.external_url_id`, `box.locations_box_id`, `membership_user.id`, `auth.whiteLabel="Wellbe"`).
2. Run `pwsh -File register-tasks.ps1`. This unregisters any old `DM-PilatesAuto-*` tasks and creates fresh ones from `targets.json`.
3. Smoke test: `pwsh -File pilates.ps1 status` should list current bookings.

## Adding / changing slots
1. Edit `targets.json` (add a new entry or flip `enabled: false`).
2. Re-run `register-tasks.ps1` — it removes orphan tasks for disabled slots and re-creates the live ones.

## Recovery / debugging
- 401 on writes → token aged out; the client auto-relogs on first 401 (one retry). If both attempts 401, re-check `config.json` `membership_user.id` is the row from `GET /boxes/{box}/memberships/active` (not `users_boxes.id`).
- 425 with `categoryFrequencyRestricts` → membership cap reached for the day; `register-target` exits 10 and skips email.
- 403 with Cloudflare HTML body → CF rate-limited the IP. Wait 30-60s; happens after consecutive failed POSTs.
- Manual one-shot: `pwsh -File pilates.ps1 book --id <schedule_id> --confirm BOOK`.
- Manual cancel: `pwsh -File pilates.ps1 cancel --id <schedule_user_id> --schedule <schedule_id> --confirm CANCEL`.

## Voice
- The CLI itself is silent (this is plumbing, not a chat surface).
- The **email** confirmation follows the standard Nirvana voice: signature via `_shared/signature.ps1`, joke via `_shared/joke-playbook.md`. NOJOKE / NOSIG overrides honored. Subject: `Pilates: registered for {name} on {date} at {time}`.
- Direct chat-trigger answers (e.g. "show me my upcoming pilates registrations") get a plain-text rendering of `pilates.ps1 upcoming`. No signature/joke — these are Nir-only conversations.
