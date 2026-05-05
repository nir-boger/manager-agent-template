"""Arbox / Wellbe REST API client.

Talks to https://apiappv2.arboxapp.com/api/v2/ on behalf of a single
authenticated member, scoped to one gym (box) and one location.

All credentials and box/membership IDs live in `config.json` (gitignored).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import requests

BASE = "https://apiappv2.arboxapp.com/api/v2"

USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 13; SM-G998B) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
)


class ArboxError(Exception):
    def __init__(self, status: int, body: str, code: str | None = None):
        super().__init__(f"[{status}] {code or ''} {body[:300]}")
        self.status = status
        self.body = body
        self.code = code


@dataclass
class ArboxClient:
    config_path: Path
    config: dict
    session: requests.Session

    @classmethod
    def from_config(cls, config_path: Path) -> "ArboxClient":
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        s = requests.Session()
        s.headers.update({
            "accept": "application/json",
            "content-type": "application/json",
            "origin": "https://wellbe.web.arboxapp.com",
            "referer": "https://wellbe.web.arboxapp.com/",
            "whiteLabel": cfg["auth"]["whiteLabel"],
            "lang": "en",
            "newSite": "1",
            "version": "10",
            "User-Agent": USER_AGENT,
        })
        return cls(config_path=config_path, config=cfg, session=s)

    # --- internal helpers -------------------------------------------------

    def _authed_headers(self) -> dict[str, str]:
        # All confirmed by SPA bundle inspection: the SPA's site-flow header
        # builder sets accessToken, refreshToken, identifier, refererName,
        # plus the booking endpoint additionally needs boxFk.
        return {
            "accessToken": self.config["auth"]["token"],
            "refreshToken": self.config["auth"]["refreshToken"],
            "identifier": self.config["box"]["external_url_id"],
            "refererName": "site",
            "boxFk": str(self.config["box"]["id"]),
        }

    def _save_config(self) -> None:
        self.config_path.write_text(
            json.dumps(self.config, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    def _request(self, method: str, path: str, *, json_body: Any = None,
                 authed: bool = True, timeout: float = 15.0,
                 retry_login: bool = True) -> Any:
        # The SPA appends XDEBUG_SESSION_START=PHPSTORM to every request;
        # mimic exactly so the API behaves identically.
        url = f"{BASE}/{path.lstrip('/')}?XDEBUG_SESSION_START=PHPSTORM"
        headers = dict(self.session.headers)
        if authed:
            headers.update(self._authed_headers())
        try:
            r = self.session.request(method, url, headers=headers,
                                     json=json_body, timeout=timeout)
        except requests.RequestException as e:
            raise ArboxError(0, str(e)) from e
        if r.status_code in (401, 403) and authed and retry_login:
            # Token may have aged out — retry once after a fresh login.
            self.login_refresh()
            return self._request(method, path, json_body=json_body,
                                 authed=authed, timeout=timeout, retry_login=False)
        if not r.ok:
            try:
                j = r.json()
                code = (j.get("error") or {}).get("messageToUser")
            except Exception:
                code = None
            raise ArboxError(r.status_code, r.text, code=code)
        # Some endpoints return text/html with empty body
        if not r.text:
            return None
        try:
            return r.json()
        except Exception:
            return r.text

    # --- auth -------------------------------------------------------------

    def login_refresh(self) -> None:
        """Re-login with email+password and persist new tokens to config.

        Uses /user/siteLogin (the SPA's actual endpoint). Plain /user/login
        also works for read endpoints, but its token is rejected by write
        endpoints like scheduleUser/insert. siteLogin needs the box
        identifier header to be present.
        """
        body = {
            "email": self.config["user"]["email"],
            "password": self.config["user"]["password"],
        }
        # siteLogin needs identifier + refererName headers but no token yet.
        url = f"{BASE}/user/siteLogin?XDEBUG_SESSION_START=PHPSTORM"
        headers = dict(self.session.headers)
        headers["identifier"] = self.config["box"]["external_url_id"]
        headers["refererName"] = "site"
        try:
            r = self.session.post(url, headers=headers, json=body, timeout=15)
        except requests.RequestException as e:
            raise ArboxError(0, f"siteLogin: {e}") from e
        if not r.ok:
            try:
                j = r.json()
                code = (j.get("error") or {}).get("messageToUser")
            except Exception:
                code = None
            raise ArboxError(r.status_code, r.text, code=code)
        data = r.json()["data"]
        self.config["auth"]["token"] = data["token"]
        self.config["auth"]["refreshToken"] = data["refreshToken"]
        self.config["auth"]["obtained_at"] = datetime.now().isoformat()
        self._save_config()

    # --- read -------------------------------------------------------------

    def get_profile(self) -> dict:
        resp = self._request("GET", "user/profile")
        return resp["data"]

    def list_schedule(self, from_date: str, to_date: str) -> list[dict]:
        body = {
            "from": from_date,
            "to": to_date,
            "locations_box_id": self.config["box"]["locations_box_id"],
        }
        resp = self._request("POST", "schedule/betweenDates", json_body=body)
        return resp["data"]

    def list_schedule_window(self, days: int = 14) -> list[dict]:
        today = datetime.now().date()
        return self.list_schedule(
            today.isoformat(),
            (today + timedelta(days=days)).isoformat(),
        )

    # --- write ------------------------------------------------------------

    def book(self, schedule_id: int) -> dict:
        # SPA omits uuidPayment when it's undefined; mirror that exactly.
        body = {
            "extras": None,
            "membership_user_id": self.config["membership_user"]["id"],
            "schedule_id": int(schedule_id),
        }
        resp = self._request("POST", "scheduleUser/insert", json_body=body)
        return resp.get("data", resp) if isinstance(resp, dict) else resp

    def join_waitlist(self, schedule_id: int) -> dict:
        body = {
            "extras": None,
            "membership_user_id": self.config["membership_user"]["id"],
            "schedule_id": int(schedule_id),
        }
        resp = self._request("POST", "scheduleStandBy/insert", json_body=body)
        return resp.get("data", resp) if isinstance(resp, dict) else resp

    def check_late_cancel(self, schedule_id: int) -> bool:
        try:
            self._request("POST", "scheduleUser/checkLateCancel",
                          json_body={"schedule_id": int(schedule_id)})
            return False
        except ArboxError as e:
            if e.status == 513:
                return True
            raise

    def cancel(self, schedule_user_id: int, schedule_id: int) -> dict:
        late = self.check_late_cancel(schedule_id)
        body = {
            "schedule_user_id": int(schedule_user_id),
            "schedule_id": int(schedule_id),
            "late_cancel": late,
        }
        resp = self._request("POST", "scheduleUser/delete", json_body=body)
        return resp.get("data", resp) if isinstance(resp, dict) else resp

    def cancel_waitlist(self, schedule_stand_by_id: int) -> dict:
        body = {"schedule_stand_by_id": int(schedule_stand_by_id)}
        resp = self._request("POST", "scheduleStandBy/delete", json_body=body)
        return resp.get("data", resp) if isinstance(resp, dict) else resp


# --- helpers --------------------------------------------------------------

# booking_option string constants (raw API values; the JS constants w.kq.*
# are uppercase but the API returns camelCase strings)
BOOK_OPEN = "insertScheduleUser"
WAITLIST_OPEN = "insertStandBy"
ALREADY_BOOKED = "cancelScheduleUser"
ALREADY_WAITLISTED = "cancelWaitList"
PAST = "past"


def class_label(s: dict) -> str:
    name = (s.get("box_categories") or {}).get("name", "?")
    coach = (s.get("coach") or {}).get("full_name", "?")
    return f"{s.get('date')} {s.get('time')}-{s.get('end_time')} {name} ({coach})"
