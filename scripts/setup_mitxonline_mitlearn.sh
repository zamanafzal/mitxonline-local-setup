#!/usr/bin/env bash
#
# setup_mitxonline_mitlearn.sh
#
# Configures MITx Online to authenticate via MIT Learn Keycloak through APISIX.
# Run from the MITx Online repo root.
#
# Usage:
#   /path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh
#   /path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh --keycloak-port 8066
#
# Host/port overrides (--apisix-port, --mitxonline-host) update .env only.
# You must also edit config/apisix/apisix.yaml redirect_uri to match.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via CLI flags or env vars)
# ---------------------------------------------------------------------------
KC_HOST="${KC_HOST:-kc.ol.local}"
KC_REALM="${KC_REALM:-ol-local}"
KC_CLIENT_ID="${KC_CLIENT_ID:-apisix}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
MITXONLINE_HOST="${MITXONLINE_HOST:-mitxonline.odl.local}"
APISIX_PORT="${APISIX_PORT:-9080}"
ENV_FILE=".env"
OVERRIDE_FILE="docker-compose.override.yml"
DEFAULT_APISIX_REDIRECT_HOST="mitxonline.odl.local"
DEFAULT_APISIX_REDIRECT_PORT="9080"

# Auto-detect Keycloak port from running mit-learn-keycloak container
auto_detect_kc_port() {
  local port
  port=$(docker inspect mit-learn-keycloak-1 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data:
    ports = data[0].get('NetworkSettings',{}).get('Ports',{})
    for k,v in ports.items():
        if v and '8080' in k:
            print(v[0]['HostPort'])
            break
" 2>/dev/null || true)
  echo "${port:-8066}"
}

KC_PORT="${KC_PORT:-$(auto_detect_kc_port)}"

# Parse CLI overrides
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keycloak-port)    KC_PORT="$2"; shift 2;;
    --keycloak-host)    KC_HOST="$2"; shift 2;;
    --keycloak-realm)   KC_REALM="$2"; shift 2;;
    --keycloak-client)  KC_CLIENT_ID="$2"; shift 2;;
    --apisix-port)      APISIX_PORT="$2"; shift 2;;
    --mitxonline-host)  MITXONLINE_HOST="$2"; shift 2;;
    --env-file)         ENV_FILE="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Run from the MITx Online repo root."
      echo ""
      echo "Options:"
      echo "  --keycloak-port PORT     Keycloak host port (default: auto-detect or 8066)"
      echo "  --keycloak-host HOST     Keycloak hostname (default: kc.ol.local)"
      echo "  --keycloak-realm REALM   Keycloak realm (default: ol-local)"
      echo "  --keycloak-client ID     Keycloak client ID (default: apisix)"
      echo "  --apisix-port PORT       APISIX host port (default: 9080; also edit apisix.yaml)"
      echo "  --mitxonline-host HOST   MITx Online hostname (default: mitxonline.odl.local; also edit apisix.yaml)"
      echo "  --env-file PATH          Path to .env file (default: .env)"
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   MITx Online + MIT Learn SSO Setup                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Keycloak:     ${KC_HOST}:${KC_PORT} (realm: ${KC_REALM}, client: ${KC_CLIENT_ID})"
echo "  APISIX:       ${MITXONLINE_HOST}:${APISIX_PORT}"
echo "  .env:         ${ENV_FILE}"
echo ""

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ ERROR: ${ENV_FILE} not found. Are you in the MITx Online repo root?"
  exit 1
fi

if [[ "$APISIX_PORT" != "$DEFAULT_APISIX_REDIRECT_PORT" || "$MITXONLINE_HOST" != "$DEFAULT_APISIX_REDIRECT_HOST" ]]; then
  echo "  ⚠️  Custom APISIX host/port: update redirect_uri in config/apisix/apisix.yaml"
  echo "     to http://${MITXONLINE_HOST}:${APISIX_PORT}/login/.apisix/redirect"
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 1: /etc/hosts
# ---------------------------------------------------------------------------
echo "── Step 1: /etc/hosts ──────────────────────────────────────────"
HOSTS_TO_ADD=("${MITXONLINE_HOST}" "${KC_HOST}")
ADDED=0
for h in "${HOSTS_TO_ADD[@]}"; do
  if ! grep -qE "^\s*127\.0\.0\.1\s+.*\b$(echo "$h" | sed 's/\./\\./g')\b" /etc/hosts 2>/dev/null; then
    echo "  Adding: 127.0.0.1  ${h}"
    echo "127.0.0.1   ${h}" | sudo tee -a /etc/hosts > /dev/null
    ADDED=$((ADDED + 1))
  fi
done
[[ $ADDED -eq 0 ]] && echo "  ✅ All hosts already present." || echo "  ✅ Added ${ADDED} host(s)."

# ---------------------------------------------------------------------------
# Step 2: Fetch Keycloak client secret
# ---------------------------------------------------------------------------
echo ""
echo "── Step 2: Keycloak client secret ──────────────────────────────"

if ! curl -sf -o /dev/null "http://localhost:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration"; then
  echo "  ❌ Keycloak not reachable at localhost:${KC_PORT}."
  echo "     Is MIT Learn running with the keycloak profile?"
  echo "     (COMPOSE_PROFILES=backend,frontend,keycloak,apisix in MIT Learn .env)"
  exit 1
fi

TOKEN=$(curl -sf -X POST "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN_USER}&password=${KC_ADMIN_PASS}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

KC_SECRET=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/${KC_REALM}/clients" \
  -H "Authorization: Bearer ${TOKEN}" \
  | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if c['clientId'] == '${KC_CLIENT_ID}':
        print(c.get('secret', '')); break
")

if [[ -z "$KC_SECRET" ]]; then
  echo "  ❌ Could not find secret for client '${KC_CLIENT_ID}' in realm '${KC_REALM}'"
  exit 1
fi
echo "  ✅ Secret fetched successfully."

# ---------------------------------------------------------------------------
# Step 3: .env configuration
# ---------------------------------------------------------------------------
echo ""
echo "── Step 3: .env ────────────────────────────────────────────────"

# Helper: set or update a key=value in .env (handles URLs with / safely)
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

set_env "COMPOSE_PROFILES"                     "apisix"
set_env "APISIX_PORT"                          "${APISIX_PORT}"
set_env "APP_LOGOUT_URL"                       "http://${MITXONLINE_HOST}:${APISIX_PORT}/logout/"
set_env "OPENEDX_SOCIAL_LOGIN_PATH"            "http://${MITXONLINE_HOST}:${APISIX_PORT}/login/"
set_env "KEYCLOAK_REALM"                       "${KC_REALM}"
set_env "KEYCLOAK_BASE_URL"                    "http://${KC_HOST}:${KC_PORT}"
set_env "KEYCLOAK_REALM_NAME"                  "${KC_REALM}"
set_env "KEYCLOAK_DISCOVERY_URL"               "http://${KC_HOST}:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration"
set_env "KEYCLOAK_CLIENT_ID"                   "${KC_CLIENT_ID}"
set_env "KEYCLOAK_CLIENT_SECRET"               "${KC_SECRET}"
set_env "MITOL_APIGATEWAY_DISABLE_MIDDLEWARE"  "False"
set_env "MITOL_APIGATEWAY_USERINFO_CREATE"     "True"
set_env "MITOL_APIGATEWAY_USERINFO_UPDATE"     "True"

rm -f "${ENV_FILE}.bak"
echo "  ✅ .env updated."

# ---------------------------------------------------------------------------
# Step 4: docker-compose.override.yml
# ---------------------------------------------------------------------------
echo ""
echo "── Step 4: docker-compose.override.yml ─────────────────────────"

if [[ -f "$OVERRIDE_FILE" ]]; then
  echo "  Backing up existing ${OVERRIDE_FILE} → ${OVERRIDE_FILE}.bak"
  cp "$OVERRIDE_FILE" "${OVERRIDE_FILE}.bak"
fi

cat > "$OVERRIDE_FILE" <<YAML
services:
  web:
    extra_hosts:
      - "kc.odl.local:host-gateway"
      - "${KC_HOST}:host-gateway"
  celery:
    extra_hosts:
      - "kc.odl.local:host-gateway"
      - "${KC_HOST}:host-gateway"
  api:
    extra_hosts:
      - "${KC_HOST}:host-gateway"
YAML
echo "  ✅ Created ${OVERRIDE_FILE}"

# ---------------------------------------------------------------------------
# Step 5: Start services
# ---------------------------------------------------------------------------
echo ""
echo "── Step 5: Starting services ───────────────────────────────────"
docker compose up -d 2>&1 | tail -5
docker compose up -d --force-recreate api 2>&1 | tail -3
sleep 3
docker compose up -d web nginx 2>&1 | tail -3
echo "  ✅ Services started."

# ---------------------------------------------------------------------------
# Step 6: Verify
# ---------------------------------------------------------------------------
echo ""
echo "── Step 6: Verification ────────────────────────────────────────"

check() {
  local label="$1" ok="$2" detail="$3"
  if [[ "$ok" == "true" ]]; then
    printf "  ✅ %-40s %s\n" "$label" "$detail"
  else
    printf "  ❌ %-40s %s\n" "$label" "$detail"
  fi
}

# Keycloak discovery
KC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${KC_HOST}:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration")
check "Keycloak discovery" "$([ "$KC_STATUS" = "200" ] && echo true || echo false)" "$KC_STATUS"

# APISIX proxy
sleep 2
APISIX_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${MITXONLINE_HOST}:${APISIX_PORT}/" 2>/dev/null || echo "000")
check "APISIX proxy" "$([ "$APISIX_STATUS" = "200" ] && echo true || echo false)" "$APISIX_STATUS"

# Login redirect
REDIRECT=$(curl -s -o /dev/null -w "%{redirect_url}" --max-redirs 0 "http://${MITXONLINE_HOST}:${APISIX_PORT}/login/" 2>/dev/null)
REDIR_OK=$(echo "$REDIRECT" | grep -q "${KC_HOST}:${KC_PORT}/realms/${KC_REALM}" && echo true || echo false)
check "Login → Keycloak redirect" "$REDIR_OK" ""

# APISIX DNS
API_CONTAINER=$(docker compose ps -q api 2>/dev/null | head -1)
if [[ -n "$API_CONTAINER" ]]; then
  DNS_OK=$(docker exec "$API_CONTAINER" nslookup "${KC_HOST}" > /dev/null 2>&1 && echo true || echo false)
else
  DNS_OK=false
fi
check "APISIX DNS (${KC_HOST})" "$DNS_OK" ""

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Setup complete!"
echo "  Open http://${MITXONLINE_HOST}:${APISIX_PORT}/login/ to test SSO."
echo "════════════════════════════════════════════════════════════════"
