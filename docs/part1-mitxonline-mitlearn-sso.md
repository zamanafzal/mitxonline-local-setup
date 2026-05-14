# Part 1 — MITx Online + MIT Learn SSO Setup

This document configures **MITx Online** to authenticate via **MIT Learn Keycloak** through **APISIX**.

After following this guide:
- Logging in at `http://mitxonline.odl.local:9080/login/` redirects to Keycloak
- A user already logged into MIT Learn is **automatically logged in** to MITx Online (shared Keycloak session)

> **Automation:** Instead of following these steps manually, you can run `scripts/setup_mitxonline_mitlearn.sh` from the MITx Online repo root. See the [README](../README.md) for details.

---

## Prerequisites

| Service | How it runs |
|---|---|
| MITx Online (`mitxonline-*` containers) | `docker compose up` in the mitxonline repo |
| MIT Learn (`mit-learn-*` containers) | MIT Learn repo `docker compose up` |
| MIT Learn Keycloak (`mit-learn-keycloak-1`) | Started as part of MIT Learn, runs on port **8066** |

> MIT Learn Keycloak is at `http://kc.ol.local:8066`. It has an `ol-local` realm with an `apisix` client already configured. MITx Online will reuse this Keycloak — you do **not** need to start a separate Keycloak for MITx Online.

---

## Step 1 — Add hostnames to `/etc/hosts`

Open `/etc/hosts` with sudo and make sure these lines are present:

```
127.0.0.1   mitxonline.odl.local
127.0.0.1   kc.ol.local
```

To check and add in one command:

```bash
echo "127.0.0.1   mitxonline.odl.local" | sudo tee -a /etc/hosts
echo "127.0.0.1   kc.ol.local" | sudo tee -a /etc/hosts
```

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
# Tell Docker Compose to start APISIX
COMPOSE_PROFILES=keycloak,apisix

# APISIX port
APISIX_PORT=9080

# Logout lands back on mitxonline via APISIX port
APP_LOGOUT_URL=http://mitxonline.odl.local:9080/logout/

# When an unauthenticated user hits a login-required page on port 8013,
# Django sends them here. APISIX on port 9080 authenticates via Keycloak.
OPENEDX_SOCIAL_LOGIN_PATH=http://mitxonline.odl.local:9080/login/

# MIT Learn Keycloak — use the ol-local realm on port 8066
KEYCLOAK_REALM=ol-local
KEYCLOAK_DISCOVERY_URL=http://kc.ol.local:8066/realms/ol-local/.well-known/openid-configuration
KEYCLOAK_CLIENT_ID=apisix
KEYCLOAK_CLIENT_SECRET=<secret from Step 2>

# APISIX middleware settings
MITOL_APIGATEWAY_DISABLE_MIDDLEWARE=False
MITOL_APIGATEWAY_USERINFO_CREATE=True
MITOL_APIGATEWAY_USERINFO_UPDATE=True
```

> **Do not change** `KEYCLOAK_SVC_HOSTNAME`, `KEYCLOAK_PORT`, or `KEYCLOAK_SSL_PORT`. Those are only used by the bundled mitxonline Keycloak which we are not using.

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

---

## Step 5 — Start everything

```bash
cd /path/to/mitxonline
docker compose up -d
```

This starts all services including APISIX (port 9080) because `COMPOSE_PROFILES=keycloak,apisix` is in `.env`.

After starting, restart web and nginx to pick up `.env` changes:

```bash
docker compose up -d web nginx
```

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
docker exec mitxonline-api-1 nslookup kc.ol.local
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
  ├─ http://mitxonline.odl.local:9080  ──►  APISIX (mitxonline-api-1)
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
Re-run Step 2 to get the new secret, update `KEYCLOAK_CLIENT_SECRET` in `.env`, then restart APISIX.

### mitxonline admin login at port 9080
`http://mitxonline.odl.local:9080/admin/login/` passes through to Django admin — shows standard username/password form.

