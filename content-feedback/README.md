# Content Feedback — Local Testing Harness

Self-contained local-only tooling to test the **per-block "Send feedback"** feature end to end.
Everything you need lives in this folder:

```
content-feedback/
├── README.md              ← you are here
├── feedback_proxy.py      ← local-only auth proxy (stands in for APISIX)
└── run_feedback_proxy.sh  ← auto-detects a local mit-learn user and starts the proxy
```

How to test the **per-block "Send feedback"** flow end to end on your machine:
learner clicks the feedback **megaphone** on a course block → a drawer opens → they pick a
reaction (👍 / 👎 / 💡) + optional comment → **submit** → a record lands in the **mit-learn**
database.

> **What this does and doesn't cover.** This exercises the real UI, the cross-origin message,
> the drawer, and a real write to the mit-learn `content_feedback` API. Production auth
> (APISIX + OIDC) is **simulated locally by a small proxy** (`feedback_proxy.py`) that
> logs in as a real local user on the server side. So this proves the *feature* works; it does
> **not** prove the production cross-origin auth (that's a separate, tracked item — see
> [Why the proxy exists](#why-the-proxy-exists)).

Living doc — updated as the setup evolves.

---

## Why the proxy exists

In production the Learning MFE and mit-learn are served **same-site over HTTPS**, so the
browser can carry the mit-learn session + CSRF cookies on a cross-origin `fetch`
(`SameSite=None; Secure`, `CSRF_COOKIE_DOMAIN` set, APISIX injecting `x-userinfo`).

Locally the pieces sit on **different sites over plain HTTP** (the MFE on
`apps.local.openedx.io:2000`, mit-learn/APISIX on `open.odl.local:8065` or `localhost:8061`),
so those cookies can't flow — `SameSite=None` requires `Secure`, which requires HTTPS. Rather
than fake HTTPS + a shared parent domain, `feedback_proxy.py` stands in for APISIX: it
authenticates to mit-learn **server-side** (injects the `X-Userinfo` header, primes CSRF,
owns the session), so the browser never needs a mit-learn cookie. That is the one and only
reason it exists; it is **local-only** and must never be deployed.

---

## 1. Prerequisites (one-time)

You need these running/installed locally:

1. **mit-learn** (backend + DB), via its docker compose. Confirm the web container is up:
   ```bash
   docker ps --format '{{.Names}}' | grep mit-learn-web
   ```
2. **The `content_feedback` migration applied** to the mit-learn DB:
   ```bash
   docker exec mit-learn-web-1 python manage.py migrate content_feedback
   ```
3. **A mit-learn user.** Log in to mit-learn once in your browser so your user is provisioned
   (the proxy needs a real `global_id`). Any existing local user works.
4. **The LMS (Open edX / Tutor) with the `ol_openedx_feedback` trigger installed and enabled.**
   This renders the megaphone inside the unit iframe; without all three of these it won't show.
   - **Install the plugin** into the **LMS** Python env
     ([open-edx-plugins #813](https://github.com/mitodl/open-edx-plugins/pull/813), merged).
     It self-registers via entry points (`xblock_asides.v1` + `lms.djangoapp`) — no
     `INSTALLED_APPS` edits — but you must **restart the LMS** afterwards. Editable install
     from a local checkout (recommended while iterating), or `pip install ol-openedx-feedback`:
     ```bash
     docker exec -it <lms-container> pip install -e /path/to/open-edx-plugins/src/ol_openedx_feedback
     # then restart the LMS process/container
     ```
     LMS-only — do **not** install in Studio/CMS.
   - **Enable XBlock Asides:** LMS admin → **XBlock Asides Config**
     (`/admin/lms_xblock/xblockasidesconfig/`) → add an entry, check **Enabled**. Asides don't
     render at all without this.
   - **Turn on the waffle flag** `ol_openedx_feedback.feedback_enabled` (default off), globally
     or per test course:
     ```bash
     docker exec <lms-container> ./manage.py lms waffle_flag \
       ol_openedx_feedback.feedback_enabled --everyone --create
     ```
5. **The Learning MFE** (`frontend-app-learning`) checked out with the feedback slot wiring
   from **[lehrer #83](https://github.com/mitodl/lehrer/pull/83)**, deps installed
   (`npm ci`, first time only), **plus the smoot-design drawer bundle staged into its static
   dir**. The MFE loads `feedbackDrawerManager.es.js` at runtime (like AskTIM) from
   `public/static/smoot-design/` — it is **not** an npm dependency, so you must build it and
   copy it in from a **[smoot-design #241](https://github.com/mitodl/smoot-design/pull/241)**
   checkout (Node 24):
   ```bash
   # in your smoot-design checkout (branch zafzal/11629-feedback-drawer)
   nvm use 24 && yarn build:bundles:feedback
   # → dist/bundles/feedbackDrawerManager.es.js (+ .map); copy both into the MFE:
   cp dist/bundles/feedbackDrawerManager.es.js dist/bundles/feedbackDrawerManager.es.js.map \
     /path/to/frontend-app-learning/public/static/smoot-design/
   ```
   Sanity-check it's served: `curl -s -o /dev/null -w '%{http_code}\n' \
   http://localhost:2000/static/smoot-design/feedbackDrawerManager.es.js` → **200**. Re-copy
   whenever you rebuild the bundle so the MFE serves the current build.
6. **The MFE `.env.development` must set `DEPLOYMENT_NAME='mitxonline'`.**
   ⚠️ This is the single most important flag: `env.config.jsx` only wires up the feedback
   (and AskTIM) sidebar coordinator when `DEPLOYMENT_NAME` contains `mitxonline`. Without it,
   the megaphone click posts a message that nothing is listening for → **the drawer never
   opens** (this was the exact "clicking does nothing" bug). Any change to `.env.development`
   requires a **dev-server restart** (webpack reads env only at startup).

   The feedback env keys the MFE expects (point the submit + prime URLs at the proxy):
   ```dotenv
   DEPLOYMENT_NAME='mitxonline'
   ENABLE_AI_DRAWER_SLOT='true'
   FEEDBACK_SUBMIT_URL='http://localhost:8899/api/v0/content_feedback/'
   FEEDBACK_CSRF_PRIME_URL='http://localhost:8899/api/v0/users/me/'
   FEEDBACK_CSRF_COOKIE_NAME='csrftoken-local'
   ```
   (The drawer renders inline in the AskTIM sidebar column — slot mode is the default and only
   presentation; there is no `FEEDBACK_SLOT_MODE` toggle.)

---

## 2. Start the pieces

### a. Start the auth proxy (simulates APISIX)
From **this folder** (`content-feedback/`):
```bash
./run_feedback_proxy.sh
```
It auto-detects a mit-learn user and listens on `http://localhost:8899`. Startup takes ~10s
(it queries the mit-learn DB for a user). Pin a specific user with
`FEEDBACK_USER_EMAIL=you@example.edu ./run_feedback_proxy.sh`.

Leave it running in its own terminal. You should see:
`Using mit-learn user: <email> (global_id=…)`.

**Confirm the shim is working** before touching the browser — hit it directly and expect a
`200` (it primes CSRF and reaches mit-learn server-side):
```bash
curl -s -o /dev/null -w "prime: %{http_code}\n" \
  http://localhost:8899/api/v0/users/me/ -H "Origin: http://localhost:2000"
```
`prime: 200` = the proxy authenticated to mit-learn and is ready. `000` = not up yet (give it
~10s) or port in use; `403` = it couldn't authenticate (see Troubleshooting). For a full
write test without the UI, use the headless check in [§4](#headless-quick-check-no-browser).

Env overrides (all optional): `MITLEARN_CONTAINER` (default `mit-learn-web-1`),
`MITLEARN_BACKEND` (default `http://localhost:8061`), `FEEDBACK_PROXY_PORT` (default `8899`),
`FEEDBACK_MFE_ORIGIN` (default `http://localhost:2000`).

### b. Start the Learning MFE
In another terminal, from your `frontend-app-learning` checkout:
```bash
npm run dev
```
The app serves under **`/learning/`** — with `npm run dev` that's
`http://apps.local.openedx.io:2000/learning/`.

> Origins involved (they legitimately differ): the MFE is `apps.local.openedx.io:2000`, the
> unit iframe / LMS is `local.openedx.io:8000`, and the proxy is `localhost:8899`. The proxy
> **reflects the caller's `Origin`**, so cross-origin submit works regardless of the MFE host.
> The MFE accepts the megaphone message because it matches `LMS_BASE_URL` (from the runtime
> MFE config = `local.openedx.io:8000`).

---

## 3. Test in the browser

1. Log in and open a **course unit** that has content blocks (video / problem / HTML).
2. On a block, click the **"Send feedback" megaphone** (rendered by the LMS plugin inside the
   unit iframe).
3. The feedback drawer opens in the AskTIM sidebar column, pre-labeled with the block name.
4. Pick a reaction and (optionally) type a comment, then **Submit**.
5. You should see a success state (the drawer confirms/closes).

---

## 4. Verify the submission landed

```bash
docker exec mit-learn-web-1 python manage.py shell -c \
  "from content_feedback.models import ContentFeedback as C; \
   f=C.objects.order_by('-created_on').first(); \
   print(C.objects.count(), '|', f and (f.sentiment, f.block_usage_key, f.user and f.user.email, f.comment))"
```
Or in Django admin: **Content feedback → Content feedbacks** (read-only list). The model is
**append-only** — submitting again on the same block creates a **new** row (full history kept).

### Headless quick check (no browser)
Confirms the proxy → mit-learn path independent of the UI:
```bash
curl -s http://localhost:8899/api/v0/users/me/ -H "Origin: http://localhost:2000" -o /dev/null -w "prime: %{http_code}\n"
curl -s -X POST http://localhost:8899/api/v0/content_feedback/ \
  -H "Origin: http://localhost:2000" -H "Content-Type: application/json" \
  -d '{"course_id":"course-v1:X","block_usage_key":"block-v1:X","sentiment":"idea","comment":"headless test"}' \
  -w "\nsubmit: %{http_code}\n"
```
Expect `prime: 200` and `submit: 201`.

---

## 5. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **No megaphone on blocks** | LMS plugin `ol_openedx_feedback` not installed, XBlock Asides off, or waffle flag `ol_openedx_feedback.feedback_enabled` off for the course. |
| **Click megaphone → nothing opens** | #1 cause: `DEPLOYMENT_NAME='mitxonline'` missing from the MFE `.env.development`, so the sidebar coordinator that handles feedback never mounts. Confirm it's set **and restart `npm run dev`** (env is read only at startup). Also confirm you're on `…/learning/…` and `ENABLE_AI_DRAWER_SLOT='true'`. (Verify in devtools: `document.querySelector('.feedback-drawer-slot-wrapper')` should exist.) |
| **Submit fails / "Something went wrong"** | CORS: the proxy must reflect your MFE origin. Ensure you're running the current `feedback_proxy.py` (it echoes the request `Origin`) and re-run `./run_feedback_proxy.sh`. Confirm the proxy is up on `http://localhost:8899`. |
| **`prime`/`submit` returns 000** | Proxy not up yet (it takes ~10s to start) or port 8899 in use (`lsof -ti tcp:8899 \| xargs kill`). |
| **`submit` returns 403** | The proxy couldn't authenticate — ensure the mit-learn container is up and the detected user has a `global_id` (log in to mit-learn once). |
| **Proxy: "no mit-learn user with a global_id"** | Log in to mit-learn in the browser once, or pass `FEEDBACK_USER_EMAIL=…`. |

---

## 6. Notes for reviewers / next steps (not part of tester setup)

- The proxy (`feedback_proxy.py`) injects the `X-Userinfo` header server-side and owns the
  session/CSRF, so the browser needs no mit-learn cookie. **In production, APISIX plays this
  role** — there is no proxy.
- Open items before production: APISIX route + CORS/CSRF allow-listing of the MFE origin +
  setting `FEEDBACK_SUBMIT_URL` + confirming the cross-site session-cookie strategy, plus the
  submission rate-limit throttle. Tracked in `mitodl/hq#11629`.
