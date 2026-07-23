#!/usr/bin/env python3
"""
LOCAL-ONLY test-harness proxy for per-block content feedback (mit-learn backend).

Do NOT deploy / do NOT push as part of any app. This mirrors the learn-ai era
`feedback_proxy.py`: it lets the Learning MFE submit feedback locally without
solving the real cross-origin session/CSRF problem in the browser.

How it works
------------
The browser (MFE at http://localhost:2000) POSTs feedback to this proxy
(http://localhost:8899) same-ish origin. The proxy authenticates to mit-learn
SERVER-SIDE by injecting the APISIX ``X-Userinfo`` header (base64 JSON of a real
local user), exactly as the APISIX gateway would in production. mit-learn's
ApisixUserMiddleware logs that user in (session), and DRF's SessionAuthentication
enforces CSRF - so the proxy first primes a CSRF cookie via GET /api/v0/users/me/
(which is @ensure_csrf_cookie) and then echoes the csrftoken back in the
``X-CSRFToken`` header on the POST. A persistent cookie jar keeps the session +
csrftoken across the two calls.

Net effect: the browser never needs a mit-learn session cookie or CSRF token -
the proxy owns all of that server-side. That is what makes local testing work.

Run
---
    MITLEARN_BACKEND=http://localhost:8061 \
    FEEDBACK_USER_SUB=<global_id> FEEDBACK_USER_EMAIL=<email> \
    python3 feedback_proxy.py            # listens on :8899

Then set in the MFE .env.development:
    FEEDBACK_SUBMIT_URL='http://localhost:8899/api/v0/content_feedback/'
"""

import base64
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = os.environ.get("MITLEARN_BACKEND", "http://localhost:8061").rstrip("/")
PORT = int(os.environ.get("FEEDBACK_PROXY_PORT", "8899"))
ALLOWED_ORIGIN = os.environ.get("FEEDBACK_MFE_ORIGIN", "http://localhost:2000")

# A real local mit-learn user (see: manage.py -> users.User). Only `sub`
# (global_id) is strictly required; the rest fill in nicely.
USER_INFO = {
    "sub": os.environ.get("FEEDBACK_USER_SUB", ""),
    "email": os.environ.get("FEEDBACK_USER_EMAIL", ""),
    "preferred_username": os.environ.get(
        "FEEDBACK_USER_USERNAME", os.environ.get("FEEDBACK_USER_EMAIL", "")
    ),
    "given_name": os.environ.get("FEEDBACK_USER_FIRST", "Local"),
    "family_name": os.environ.get("FEEDBACK_USER_LAST", "Tester"),
    "name": os.environ.get("FEEDBACK_USER_NAME", "Local Tester"),
}
X_USERINFO = base64.b64encode(json.dumps(USER_INFO).encode()).decode()

# Cookies are managed manually (not via cookiejar) because local mit-learn sets
# them on Domain=.odl.local, which a cookiejar refuses to resend to `localhost`.
# We capture Set-Cookie name=value pairs and replay them verbatim, so the domain
# is irrelevant. The CSRF cookie name is also non-default locally
# (e.g. `csrftoken-local`), so we detect it by substring rather than hard-coding.
_cookies = {}


def _capture_cookies(response):
    for raw in response.info().get_all("Set-Cookie") or []:
        name, _, rest = raw.partition("=")
        value = rest.split(";", 1)[0]
        _cookies[name.strip()] = value.strip()


def _csrf_token():
    for name, value in _cookies.items():
        if "csrftoken" in name:
            return value
    return ""


def _cookie_header():
    return "; ".join(f"{name}={value}" for name, value in _cookies.items())


def _prime_csrf():
    """GET /api/v0/users/me/ to log in server-side and capture session + csrf cookies."""
    req = urllib.request.Request(
        f"{BACKEND}/api/v0/users/me/",
        method="GET",
        headers={"X-Userinfo": X_USERINFO, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            _capture_cookies(resp)
    except urllib.error.HTTPError as err:
        _capture_cookies(err)  # a non-200 still carries Set-Cookie


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        # Reflect the caller's Origin so this works regardless of the MFE host
        # (e.g. apps.local.openedx.io:2000 or localhost:2000). With
        # Allow-Credentials the origin must be an exact echo, not "*".
        origin = self.headers.get("Origin") or ALLOWED_ORIGIN
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.send_header(
            "Access-Control-Allow-Headers", "content-type, x-csrftoken, accept"
        )
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):  # noqa: N802
        # Primes / passes through auth GETs (e.g. the client's users/me priming).
        _prime_csrf()
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if not _csrf_token():
            _prime_csrf()

        req = urllib.request.Request(
            f"{BACKEND}{self.path}",
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Userinfo": X_USERINFO,
                "X-CSRFToken": _csrf_token(),
                "Cookie": _cookie_header(),
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                status, payload = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, payload = err.code, err.read()
        except urllib.error.URLError as err:
            status, payload = 502, json.dumps({"proxy_error": str(err)}).encode()

        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        # Concise logging.
        print(f"[feedback_proxy] {self.command} {self.path} -> {args}")  # noqa: T201


def main():
    if not USER_INFO["sub"]:
        print(  # noqa: T201
            "WARNING: FEEDBACK_USER_SUB (global_id) is empty - mit-learn will reject "
            "the request. Set it to a real local user's global_id."
        )
    print(  # noqa: T201
        f"[feedback_proxy] listening on http://localhost:{PORT} -> {BACKEND} "
        f"as user sub={USER_INFO['sub'] or '(unset)'}; MFE origin {ALLOWED_ORIGIN}"
    )
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
