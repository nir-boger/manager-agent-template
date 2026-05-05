"""Email helpers for the pilates skill.

We don't render the joke or signature here — those come from the shared
PowerShell helpers (joke-playbook + signature.ps1). This module just
formats the pilates-specific HTML and shells out to send-email.ps1.
"""
from __future__ import annotations

import html as _html
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

DAY_NAMES_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday",
                  "Thursday", "Friday", "Saturday"]


def _esc(s: str | None) -> str:
    return _html.escape(str(s)) if s is not None else ""


def _dow_for_date(date_str: str) -> str:
    d = datetime.strptime(date_str, "%Y-%m-%d").date()
    py = d.weekday()  # Mon=0..Sun=6
    return DAY_NAMES_FULL[(py + 1) % 7]


def render_confirmation_html(*, just_booked: dict,
                             upcoming: list[dict],
                             waitlist: list[dict],
                             joke_line: str | None = None) -> str:
    """Render the email HTML body. `just_booked`, `upcoming`, `waitlist`
    are class-record dicts from /schedule/betweenDates."""
    name = (just_booked.get("box_categories") or {}).get("name", "?")
    coach = (just_booked.get("coach") or {}).get("full_name", "?")
    parts = []
    parts.append(
        f"<p>Just registered for "
        f"<strong>{_esc(name)}</strong> on "
        f"<strong>{_esc(_dow_for_date(just_booked['date']))}, "
        f"{_esc(just_booked['date'])}</strong> at "
        f"<strong>{_esc(just_booked['time'])}</strong> "
        f"with {_esc(coach)}.</p>"
    )

    if upcoming:
        parts.append("<p><strong>Upcoming Pilates bookings:</strong></p>")
        parts.append(
            '<table style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:13px;">'
        )
        parts.append(
            "<tr style='background:#f3f3f3;'>"
            "<th style='border:1px solid #ddd;padding:6px 10px;text-align:left;'>Day</th>"
            "<th style='border:1px solid #ddd;padding:6px 10px;text-align:left;'>Date</th>"
            "<th style='border:1px solid #ddd;padding:6px 10px;text-align:left;'>Time</th>"
            "<th style='border:1px solid #ddd;padding:6px 10px;text-align:left;'>Class</th>"
            "<th style='border:1px solid #ddd;padding:6px 10px;text-align:left;'>Coach</th>"
            "</tr>"
        )
        for c in upcoming:
            parts.append(
                "<tr>"
                f"<td style='border:1px solid #ddd;padding:6px 10px;'>{_esc(_dow_for_date(c['date']))}</td>"
                f"<td style='border:1px solid #ddd;padding:6px 10px;'>{_esc(c['date'])}</td>"
                f"<td style='border:1px solid #ddd;padding:6px 10px;'>{_esc(c['time'])}</td>"
                f"<td style='border:1px solid #ddd;padding:6px 10px;'>{_esc((c.get('box_categories') or {}).get('name','?'))}</td>"
                f"<td style='border:1px solid #ddd;padding:6px 10px;'>{_esc((c.get('coach') or {}).get('full_name','?'))}</td>"
                "</tr>"
            )
        parts.append("</table>")
    else:
        parts.append("<p><em>No other upcoming Pilates bookings.</em></p>")

    if waitlist:
        parts.append("<p><strong>Currently on waitlist:</strong></p><ul>")
        for c in waitlist:
            parts.append(
                f"<li>{_esc(_dow_for_date(c['date']))}, {_esc(c['date'])} "
                f"{_esc(c['time'])} — {_esc((c.get('box_categories') or {}).get('name','?'))}"
                f" (position {_esc(c.get('stand_by_position'))})</li>"
            )
        parts.append("</ul>")

    if joke_line:
        parts.append(f"<p><em>{_esc(joke_line)}</em></p>")

    return "\n".join(parts)


def send_confirmation_email(*, subject: str, body_html: str,
                            to_addr: str, no_joke: bool = False,
                            no_sig: bool = False) -> bool:
    """Shell out to send-email.ps1. Returns True on success, False otherwise.
    Errors are printed but never re-raised — a failed email must not undo a
    successful booking."""
    here = Path(__file__).parent
    ps1 = here / "send-email.ps1"
    if not ps1.exists():
        print(f"  ! send-email.ps1 missing at {ps1}; skipping email")
        return False
    try:
        with tempfile.NamedTemporaryFile(
                "w", suffix=".html", delete=False, encoding="utf-8") as fh:
            fh.write(body_html)
            body_path = fh.name
    except Exception as e:
        print(f"  ! could not write email body file: {e}")
        return False
    cmd = [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(ps1),
        "-Subject", subject,
        "-BodyFile", body_path,
        "-To", to_addr,
    ]
    if no_joke:
        cmd.append("-NoJoke")
    if no_sig:
        cmd.append("-NoSig")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if res.returncode != 0:
            print(f"  ! email send failed (rc={res.returncode}):")
            print(f"    stdout: {res.stdout.strip()[:500]}")
            print(f"    stderr: {res.stderr.strip()[:500]}")
            return False
        print(f"  ✉  email sent to {to_addr}")
        return True
    except subprocess.TimeoutExpired:
        print("  ! email send timed out after 60s")
        return False
    except Exception as e:
        print(f"  ! email send error: {e}")
        return False
    finally:
        try:
            Path(body_path).unlink(missing_ok=True)
        except Exception:
            pass
