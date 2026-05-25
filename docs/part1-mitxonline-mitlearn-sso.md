# Part 1 — MITx Online + MIT Learn SSO Setup

This document configures **MITx Online** to authenticate via **MIT Learn Keycloak** through **MITx Online's APISIX** gateway.

After following this guide:
- Logging in at `http://mitxonline.odl.local:9080/login/` redirects to Keycloak
- A user already logged into MIT Learn is **automatically logged in** to MITx Online (shared Keycloak session)

> **Automation:** Run the setup script from the MITx Online repo root (script lives in this repo):
>
> ```bash
> cd /path/to/mitxonline
> /path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh
> ```
>
> See the [README](../README.md) for details.

---

## Prerequisites

| Service | How it runs |
|---|---|
| MIT Learn Keycloak (`mit-learn-keycloak-1`) | MIT Learn repo with `keycloak` profile — e.g. `COMPOSE_PROFILES=backend,frontend,keycloak,apisix` in MIT Learn `.env`, then `docker compose up` |
| MITx Online | Started by this guide or the setup script (Step 5) — does not need to be running beforehand |

> MIT Learn Keycloak is at `http://kc.ol.local:8066`. It has an `ol-local` realm with an `apisix` client already configured. MITx Online will reuse this Keycloak — you do **not** need MITx Online's bundled Keycloak (`kc.odl.local:7080`).

### Two APISIX instances (by design)

MIT Learn runs its own APISIX on port **8065** for the Learn frontend. This guide configures a **separate** MITx Online APISIX on port **9080** that talks to the **same** Keycloak. Cross-service SSO works because both gateways share the Keycloak session at `kc.ol.local:8066` — not because traffic goes through one APISIX.

---

## Step 1 — Add hostnames to `/etc/hosts`

Open `/etc/hosts` with sudo and make sure these lines are present:

```
127.0.0.1   mitxonline.odl.local
127.0.0.1   kc.ol.local
```

To add manually (check first — `tee -a` will create duplicates if the line already exists):

```bash
grep -q mitxonline.odl.local /etc/hosts || echo "127.0.0.1   mitxonline.odl.local" | sudo tee -a /etc/hosts
grep -q kc.ol.local /etc/hosts || echo "127.0.0.1   kc.ol.local" | sudo tee -a /etc/hosts
```

The setup script deduplicates automatically.

---

## Step 2 — Get the Keycloak `apisix` client secret

The MIT Learn Keycloak (`mit-learn-keycloak-1`) has an `apisix` client in the `ol-local` realm. Get its secret:

```bash
# Get an admin token (uses default local dev credentials)
TOKEN=$(curl -s -X POST 'http://localhost:8066/realms/master/protocol/openid-connect/token' \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=admin' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# Fetch the apisix client secret
curl -s "http://localhost:8066/admin/realms/ol-local/clients" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; [print(c['clientId'], c.get('secret','')) for c in json.load(sys.stdin) if c['clientId']=='apisix']"
```

This will print:
```
apisix <your-secret>
```

Copy the secret — you will need it in Step 3.

> The secret will differ on each machine depending on when MIT Learn Keycloak was created. Always fetch it fresh using the commands above.

---

## Step 3 — Configure `.env`

In the MITx Online repo root, open `.env` and set or add these values:

```dotenv
# Start MITx Online APISIX only (not the bundled mitxonline Keycloak)
COMPOSE_PROFILES=apisix

# APISIX port
APISIX_PORT=9080

# Logout lands back on mitxonline via APISIX port
APP_LOGOUT_URL=http://mitxonline.odl.local:9080/logout/

# When an unauthenticated user hits a login-required page on port 8013,
# Django sends them here. APISIX on port 9080 authenticates via Keycloak.
OPENEDX_SOCIAL_LOGIN_PATH=http://mitxonline.odl.local:9080/login/

# MIT Learn Keycloak — use the ol-local realm on port 8066
KEYCLOAK_REALM=ol-local
KEYCLOAK_BASE_URL=http://kc.ol.local:8066
KEYCLOAK_REALM_NAME=ol-local
KEYCLOAK_DISCOVERY_URL=http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration
KEYCLOAK_CLIENT_ID=apisix
KEYCLOAK_CLIENT_SECRET=<secret from Step 2>

# APISIX middleware settings
MITOL_APIGATEWAY_DISABLE_MIDDLEWARE=False
MITOL_APIGATEWAY_USERINFO_CREATE=True
MITOL_APIGATEWAY_USERINFO_UPDATE=True
```

> **Do not change** `KEYCLOAK_SVC_HOSTNAME`, `KEYCLOAK_PORT`, or `KEYCLOAK_SSL_PORT`. Those are only used by the bundled mitxonline Keycloak which we are not using.
>
> `KEYCLOAK_REALM` is consumed by the APISIX container. `KEYCLOAK_REALM_NAME` and `KEYCLOAK_BASE_URL` are used by Django (e.g. account email/password update flows).

### Custom hostname or APISIX port

`config/apisix/apisix.yaml` hardcodes the OIDC callback:

```
redirect_uri: "http://mitxonline.odl.local:9080/login/.apisix/redirect"
```

If you change the hostname or port from the defaults above, you must edit that file to match **before** testing login.

---

## Step 4 — Create `docker-compose.override.yml`

Create the file `docker-compose.override.yml` in the MITx Online repo root:

```yaml
services:
  web:
    extra_hosts:
      - "kc.odl.local:host-gateway"
      - "kc.ol.local:host-gateway"
  celery:
    extra_hosts:
      - "kc.odl.local:host-gateway"
      - "kc.ol.local:host-gateway"
  api:
    extra_hosts:
      - "kc.ol.local:host-gateway"
```

**Why:** Docker containers cannot see your `/etc/hosts`. `host-gateway` tells each container to resolve `kc.ol.local` to the Docker host machine, where MIT Learn Keycloak is listening on port 8066.

> The setup script **replaces** this file (backing up any existing copy to `.bak`). Merge manually if you already have custom overrides.

---

## Step 5 — Start everything

```bash
cd /path/to/mitxonline
docker compose up -d
docker compose up -d --force-recreate api
docker compose up -d web nginx
```

This starts all core services plus APISIX (port 9080) because `COMPOSE_PROFILES=apisix` is in `.env`. Recreating `api` ensures APISIX picks up Keycloak env vars (especially important after updating the client secret).

---

## Step 6 — Verify everything is working

```bash
# 1. Keycloak discovery endpoint is reachable
curl -s -o /dev/null -w "%{http_code}" \
  http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration
# Expected: 200

# 2. APISIX is up and proxying mitxonline
curl -s -o /dev/null -w "%{http_code}" http://mitxonline.odl.local:9080/
# Expected: 200

# 3. Login redirect goes to the correct Keycloak
curl -s -o /dev/null -w "%{redirect_url}" --max-redirs 0 \
  http://mitxonline.odl.local:9080/login/
# Expected URL should contain: kc.ol.local:8066/realms/ol-local

# 4. APISIX container can resolve kc.ol.local
docker compose exec api nslookup kc.ol.local
# Expected: resolves to the host gateway IP
```

---

## Testing the SSO Login Flow

1. **Clear cookies** for `mitxonline.odl.local` and `kc.ol.local`
2. Go to **`http://mitxonline.odl.local:9080/login/`**
3. You will be redirected to **`http://kc.ol.local:8066`** (MIT Learn Keycloak login page)
4. Log in with any `ol-local` realm user (these are standard local dev users seeded by MIT Learn Keycloak)
5. After login, Keycloak redirects back to APISIX → you are logged in to MITx Online

### Testing cross-service SSO

If the user is **already logged into MIT Learn** (same Keycloak), visiting `http://mitxonline.odl.local:9080/login/` logs them in **automatically** — Keycloak recognises the existing session.

---

## Architecture Overview

```
Browser
  │
  ├─ http://mitxonline.odl.local:9080  ──►  APISIX (mitxonline api service)
  │                                            │
  │                                            ├─ unauthenticated? ──► Keycloak (kc.ol.local:8066)
  │                                            │                          │
  │                                            │◄─── auth code callback ──┘
  │                                            │
  │                                            └─► nginx ──► Django (web)
  │                                                          ApisixUserMiddleware
  │                                                          creates/updates user from headers
  │
  └─ http://mitxonline.odl.local:8013  ──►  Varnish ──► nginx ──► Django (direct, no APISIX)

MIT Learn (separate): open.odl.local:8065 ──► Learn APISIX ──► same Keycloak (8066)
```

---

## Troubleshooting

### "Too many redirects" on mitxonline.odl.local:8013
You are hitting port 8013 (direct, no APISIX). **Always use port 9080 for browser login.**

### Login page shows error after Keycloak redirect
- The `redirect_uri` in the Keycloak URL must contain `:9080`. Check `config/apisix/apisix.yaml` has `redirect_uri: "http://mitxonline.odl.local:9080/login/.apisix/redirect"`.
- Restart APISIX: `docker compose up -d --force-recreate api`

### APISIX can't reach Keycloak
Make sure `docker-compose.override.yml` exists and has `kc.ol.local:host-gateway` under the `api` service. Then: `docker compose up -d --force-recreate api`

### Keycloak client secret changed
Re-run Step 2 to get the new secret, update `KEYCLOAK_CLIENT_SECRET` in `.env`, then: `docker compose up -d --force-recreate api`

### mitxonline admin login at port 9080
`http://mitxonline.odl.local:9080/admin/login/` passes through to Django admin — shows standard username/password form.
