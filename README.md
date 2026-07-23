# mitxonline-local-setup

Automation scripts and documentation for wiring **MITx Online** into a local dev stack: SSO with **MIT Learn** (Keycloak + APISIX) and (eventually) **Open edX / Tutor LMS**.

| Part | Status | What it does |
|------|--------|--------------|
| **Part 1** | **Ready** | MITx Online ↔ MIT Learn SSO via shared Keycloak + MITx Online APISIX |
| **Part 2** | **Not ready yet** | Tutor LMS ↔ MITx Online (Docker network, CORS, OAuth2) — draft docs/scripts exist but the Open edX side is **not validated for sharing**; use Part 1 only for now |
| **Part 3** | **Test harness** | Local end-to-end testing of the per-block **content feedback** feature (mit-learn backend) via a local-only auth proxy that stands in for APISIX |

---

## What Part 1 gives you

After Part 1:

- Browser login at **`http://mitxonline.odl.local:9080/login/`** redirects to MIT Learn Keycloak (`kc.ol.local:8066`)
- A user already logged into **MIT Learn** (same Keycloak realm) is logged into **MITx Online** automatically
- Direct access on **`http://mitxonline.odl.local:8013`** still works for dev, but **use `:9080` for SSO login**

Architecture in brief: MIT Learn and MITx Online each run their own APISIX (Learn `:8065`, MITx Online `:9080`), but both authenticate against the **same** Keycloak instance.

---

## Prerequisites

Before running Part 1:

1. **Docker Desktop** running
2. **[MITx Online](https://github.com/mitodl/mitxonline)** cloned on a **recent `main`** that includes the APISIX `api` service in `docker-compose.yml` (`image: apache/apisix:latest`, profile `apisix`). Older checkouts without that service will fail at Step 5 with `service "api" has neither an image nor a build context specified`.
3. **[MIT Learn](https://github.com/mitodl/mit-learn)** running with Keycloak:
   - In MIT Learn `.env`: `COMPOSE_PROFILES=backend,frontend,keycloak,apisix`
   - Start: `docker compose up -d` in the MIT Learn repo
   - Verify Keycloak: `curl -sf http://localhost:8066/realms/ol-local/.well-known/openid-configuration` returns JSON

Clone this repo anywhere (it does not need to live inside the MITx Online tree):

```bash
git clone https://github.com/zamanafzal/mitxonline-local-setup.git
```

---

## Part 1 — Quick start (automated)

Run from the **MITx Online repo root**. The script updates MITx Online’s `.env` and `docker-compose.override.yml` there — not in this repo.

```bash
cd /path/to/mitxonline
/path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh
```

You will be prompted for **sudo** once to add `/etc/hosts` entries if missing.

### What the script does

1. Adds `127.0.0.1 mitxonline.odl.local` and `127.0.0.1 kc.ol.local` to `/etc/hosts` (skips if present)
2. Auto-detects MIT Learn Keycloak port (default **8066**) and fetches the `apisix` client secret from the local Keycloak admin API
3. Updates MITx Online `.env`:
   - `COMPOSE_PROFILES=apisix` (MITx Online APISIX only — does **not** start MITx Online’s bundled Keycloak)
   - Keycloak / APISIX / `MITOL_APIGATEWAY_*` settings for SSO
4. Creates `docker-compose.override.yml` so containers can reach `kc.ol.local` via `host-gateway` (backs up any existing file to `.bak`)
5. Runs `docker compose up`, recreates the APISIX (`api`) container, restarts `web` and `nginx`
6. Prints pass/fail checks (Keycloak discovery, APISIX proxy, login redirect, DNS)

### Manual alternative

Step-by-step guide: [docs/part1-mitxonline-mitlearn-sso.md](docs/part1-mitxonline-mitlearn-sso.md)

---

## Part 1 — Verification checklist

After the script finishes (or after following the manual doc), confirm:

### Automated checks (script output)

| Check | Expected |
|-------|----------|
| Keycloak discovery | HTTP **200** for `http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration` |
| APISIX proxy | HTTP **200** for `http://mitxonline.odl.local:9080/` |
| Login → Keycloak redirect | `curl` redirect URL contains `kc.ol.local:8066/realms/ol-local` |
| APISIX DNS | `docker compose exec api nslookup kc.ol.local` resolves (host gateway) |

### Manual commands

```bash
cd /path/to/mitxonline

# Keycloak reachable from host
curl -s -o /dev/null -w "%{http_code}\n" \
  http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration

# APISIX serving MITx Online
curl -s -o /dev/null -w "%{http_code}\n" http://mitxonline.odl.local:9080/

# Login sends browser to Keycloak
curl -s -o /dev/null -w "%{redirect_url}\n" --max-redirs 0 \
  http://mitxonline.odl.local:9080/login/

# APISIX container env loaded
docker compose exec api env | grep KEYCLOAK_DISCOVERY_URL
```

### Browser smoke test

1. Clear cookies for `mitxonline.odl.local` and `kc.ol.local`
2. Open **`http://mitxonline.odl.local:9080/login/`**
3. You should land on Keycloak at `http://kc.ol.local:8066`
4. Log in with a local dev user (e.g. `student@odl.local` / `student` — seeded by MIT Learn Keycloak)
5. You should return to MITx Online logged in

**Cross-service SSO:** log into MIT Learn first, then visit `http://mitxonline.odl.local:9080/login/` — Keycloak should skip the password prompt.

### What to check in MITx Online `.env`

These should be set (the script does this for you):

```dotenv
COMPOSE_PROFILES=apisix
APISIX_PORT=9080
OPENEDX_SOCIAL_LOGIN_PATH=http://mitxonline.odl.local:9080/login/
APP_LOGOUT_URL=http://mitxonline.odl.local:9080/logout/
KEYCLOAK_REALM=ol-local
KEYCLOAK_BASE_URL=http://kc.ol.local:8066
KEYCLOAK_REALM_NAME=ol-local
KEYCLOAK_DISCOVERY_URL=http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration
KEYCLOAK_CLIENT_ID=apisix
KEYCLOAK_CLIENT_SECRET=<fetched at setup time — not committed>
MITOL_APIGATEWAY_DISABLE_MIDDLEWARE=False
MITOL_APIGATEWAY_USERINFO_CREATE=True
MITOL_APIGATEWAY_USERINFO_UPDATE=True
```

> **Secrets:** `KEYCLOAK_CLIENT_SECRET` is written to your local MITx Online `.env` only. This repo contains no machine-specific secrets.

---

## Part 1 — CLI options

```bash
/path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh --help
```

Common overrides:

```bash
# Non-default Keycloak port
/path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh --keycloak-port 9066
```

Environment variables: `KC_PORT`, `KC_HOST`, `KC_REALM`, `APISIX_PORT`, `MITXONLINE_HOST`, etc.

> **Custom hostname or APISIX port:** the script updates `.env` only. You must also edit `config/apisix/apisix.yaml` `redirect_uri` in the MITx Online repo to match.

---

## Part 1 — Re-running and idempotency

Safe to re-run after Keycloak reset or `.env` drift. The script:

- Skips existing `/etc/hosts` lines
- Updates `.env` keys in place (no duplicates)
- Recreates the APISIX container so Keycloak env vars reload
- Backs up `docker-compose.override.yml` before overwriting

If Keycloak was recreated and login breaks, re-run the script (or refresh `KEYCLOAK_CLIENT_SECRET` manually) then:

```bash
cd /path/to/mitxonline
docker compose up -d --force-recreate api
```

---

## Part 1 — Troubleshooting

| Symptom | Fix |
|---------|-----|
| Redirect loop on `:8013` | Use **`http://mitxonline.odl.local:9080`** for login, not `:8013` |
| Error after Keycloak redirect | Confirm `config/apisix/apisix.yaml` has `redirect_uri: "http://mitxonline.odl.local:9080/login/.apisix/redirect"`; `docker compose up -d --force-recreate api` |
| APISIX can't reach Keycloak | Ensure `docker-compose.override.yml` has `kc.ol.local:host-gateway` under `api`; recreate `api` |
| `api` has neither an image nor a build context | Your MITx Online checkout is **too old** — `docker-compose.override.yml` only adds DNS for `api`; the image/ports come from base `docker-compose.yml`. Run `git pull` on MITx Online, then re-run the script |
| Script fails at Keycloak step | Start MIT Learn with `keycloak` profile; check `curl http://localhost:8066/realms/ol-local/.well-known/openid-configuration` |

More detail: [Part 1 troubleshooting](docs/part1-mitxonline-mitlearn-sso.md#troubleshooting)

---

## Part 2 — Open edX / Tutor LMS (not ready yet)

Part 2 connects **Tutor LMS** to MITx Online for OAuth, CORS, and Docker networking. Files are included for early experimentation:

- Script: `scripts/setup_mitxonline_lms.sh`
- Doc: [docs/part2-tutor-lms-mitxonline.md](docs/part2-tutor-lms-mitxonline.md)

**Do not rely on Part 2 for production or team onboarding yet.** The Open edX side still needs review, testing, and cleanup before it is documented as supported. Complete **Part 1** first; Part 2 will be marked ready in this README when validated.

---

## Part 3 — Content feedback local testing (test harness)

Everything for this part lives in its own self-contained folder: **[`content-feedback/`](content-feedback/)** (proxy + start script + full README). A **local-only** auth proxy (`content-feedback/feedback_proxy.py`) lets you test the per-block **"Send feedback"** feature end to end on your machine: click the megaphone on a course block → drawer opens → pick 👍 / 👎 / 💡 + comment → submit → a row lands in the **mit-learn** `content_feedback` table.

Why a proxy? In production the Learning MFE and mit-learn are **same-site over HTTPS**, so the browser carries mit-learn's session + CSRF cookies on a cross-origin submit (APISIX injects identity). Locally the pieces are on **different sites over plain HTTP**, so those cookies can't flow. The proxy stands in for APISIX — it authenticates to mit-learn **server-side** (injects `X-Userinfo`, primes CSRF, owns the session), so the browser needs no mit-learn cookie. This proves the *feature*; it does **not** exercise production cross-origin auth.

```bash
# from the content-feedback/ folder, with mit-learn's docker stack up
cd content-feedback
./run_feedback_proxy.sh                  # auto-detects a local mit-learn user; listens on :8899
```

Then point the Learning MFE's `.env.development` `FEEDBACK_SUBMIT_URL` / `FEEDBACK_CSRF_PRIME_URL` at the proxy and start it. Full step-by-step (prereqs, LMS plugin + waffle flag, MFE slot wiring, verification, troubleshooting): [content-feedback/README.md](content-feedback/README.md).

> **Local-only.** `feedback_proxy.py` / `run_feedback_proxy.sh` simulate production auth and must **never** be deployed. Related PRs: open-edx-plugins #813 (trigger, merged), mit-learn #3593 (backend, merged), smoot-design #241 (drawer) and lehrer #83 (MFE slot wiring) — both open. Feature tracking: `mitodl/hq#11629`.

---

## Repo structure

```
mitxonline-local-setup/
├── README.md
├── .gitignore
├── docs/
│   ├── part1-mitxonline-mitlearn-sso.md   ← supported
│   └── part2-tutor-lms-mitxonline.md      ← draft / not ready
├── scripts/
│   ├── setup_mitxonline_mitlearn.sh       ← supported
│   └── setup_mitxonline_lms.sh            ← draft / not ready
└── content-feedback/                      ← Part 3 (self-contained test harness)
    ├── README.md                          ← testing guide
    ├── feedback_proxy.py                  ← local-only auth proxy
    └── run_feedback_proxy.sh              ← starts the proxy
```

---

## Related MIT ODL repos

- [MITx Online](https://github.com/mitodl/mitxonline) — also see `docs/local-sso-setup.md` for a longer combined guide
- [MIT Learn](https://github.com/mitodl/mit-learn) — see `README-keycloak.md` for Keycloak defaults and dev users
