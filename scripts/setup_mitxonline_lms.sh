#!/usr/bin/env bash
#
# setup_mitxonline_lms.sh
#
# Connects Tutor LMS to MITx Online: Docker network, CORS, OAuth2 app, LMS settings.
# Run from the MITx Online repo root.
#
# Usage:
#   ./setup_mitxonline_lms.sh
#   ./setup_mitxonline_lms.sh --tutor-root ~/Library/Application\ Support/tutor-main
#
# All flags are optional — defaults match the standard local dev setup.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via CLI flags or env vars)
# ---------------------------------------------------------------------------
MITXONLINE_HOST="${MITXONLINE_HOST:-mitxonline.odl.local}"
MITXONLINE_DJANGO_PORT="${MITXONLINE_DJANGO_PORT:-8013}"
APISIX_PORT="${APISIX_PORT:-9080}"
LMS_HOST="${LMS_HOST:-local.openedx.io}"
LMS_PORT="${LMS_PORT:-8000}"
MFE_HOST="${MFE_HOST:-apps.local.openedx.io}"
TUTOR_ROOT="${TUTOR_ROOT:-${HOME}/Library/Application Support/tutor-main}"
DOCKER_NETWORK="${DOCKER_NETWORK:-mitxonline_default}"
VARNISH_CONTAINER="${VARNISH_CONTAINER:-mitxonline-varnish-1}"
WEB_CONTAINER="${WEB_CONTAINER:-mitxonline-web-1}"
ENV_FILE=".env"

# Auto-detect LMS container name
auto_detect_lms_container() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'tutor.*dev-lms-1$' | head -1 || echo "tutor_main_dev-lms-1"
}

LMS_CONTAINER="${LMS_CONTAINER:-$(auto_detect_lms_container)}"

# MFE ports (standard Tutor MFE ports)
MFE_PORTS=(1984 1993 1994 1995 1996 1997 1999 2001 2002 2025)

# Parse CLI overrides
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tutor-root)        TUTOR_ROOT="$2"; shift 2;;
    --lms-host)          LMS_HOST="$2"; shift 2;;
    --lms-port)          LMS_PORT="$2"; shift 2;;
    --lms-container)     LMS_CONTAINER="$2"; shift 2;;
    --mfe-host)          MFE_HOST="$2"; shift 2;;
    --mitxonline-host)   MITXONLINE_HOST="$2"; shift 2;;
    --apisix-port)       APISIX_PORT="$2"; shift 2;;
    --varnish-container) VARNISH_CONTAINER="$2"; shift 2;;
    --web-container)     WEB_CONTAINER="$2"; shift 2;;
    --env-file)          ENV_FILE="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --tutor-root PATH          Tutor root dir (default: ~/Library/Application Support/tutor-main)"
      echo "  --lms-host HOST            LMS hostname (default: local.openedx.io)"
      echo "  --lms-port PORT            LMS port (default: 8000)"
      echo "  --lms-container NAME       LMS container name (default: auto-detect)"
      echo "  --mfe-host HOST            MFE hostname (default: apps.local.openedx.io)"
      echo "  --mitxonline-host HOST     MITx Online hostname (default: mitxonline.odl.local)"
      echo "  --apisix-port PORT         APISIX port (default: 9080)"
      echo "  --varnish-container NAME   Varnish container (default: mitxonline-varnish-1)"
      echo "  --web-container NAME       MITx Online web container (default: mitxonline-web-1)"
      echo "  --env-file PATH            Path to .env (default: .env)"
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TUTOR_COMPOSE="${TUTOR_ROOT}/env/dev/docker-compose.yml"
LMS_DEV_PY="${TUTOR_ROOT}/env/apps/openedx/settings/lms/development.py"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Tutor LMS + MITx Online Integration                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  LMS:          ${LMS_HOST}:${LMS_PORT} (container: ${LMS_CONTAINER})"
echo "  MITx Online:  ${MITXONLINE_HOST}:${MITXONLINE_DJANGO_PORT} / :${APISIX_PORT}"
echo "  Tutor root:   ${TUTOR_ROOT}"
echo ""

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ ERROR: ${ENV_FILE} not found. Are you in the MITx Online repo root?"
  exit 1
fi

# Helper: set or update a key=value in .env
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Step 1: /etc/hosts
# ---------------------------------------------------------------------------
echo "── Step 1: /etc/hosts ──────────────────────────────────────────"
HOSTS_TO_ADD=("${LMS_HOST}" "openedx.odl.local")
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
# Step 2: MITx Online .env CORS settings
# ---------------------------------------------------------------------------
echo ""
echo "── Step 2: MITx Online .env CORS ──────────────────────────────"

# Build CORS origins list
CORS_ORIGINS="http://open.odl.local:8062,http://localhost:8062,http://${LMS_HOST}:${LMS_PORT}"
for p in "${MFE_PORTS[@]}"; do
  CORS_ORIGINS="${CORS_ORIGINS},http://${MFE_HOST}:${p}"
done

set_env "MITXONLINE_DOCKER_BASE_URL" "http://${VARNISH_CONTAINER}"
set_env "CORS_ALLOWED_ORIGINS" "${CORS_ORIGINS}"

# Escape dots for regex values
MFE_HOST_ESC="${MFE_HOST//./\\.}"
LMS_HOST_ESC="${LMS_HOST//./\\.}"
set_env "CORS_ALLOWED_ORIGIN_REGEXES" "http://${MFE_HOST_ESC}:\\\\d+,http://${LMS_HOST_ESC}:\\\\d+"

set_env "CSRF_TRUSTED_ORIGINS" "http://open.odl.local:8062,http://api.open.odl.local:8065,http://localhost:8062,http://${LMS_HOST}:${LMS_PORT},http://${MFE_HOST}:1999,http://${MITXONLINE_HOST}:${APISIX_PORT}"
set_env "OPENEDX_AUTHN_MFE_OAUTH2_CORS" "false"

rm -f "${ENV_FILE}.bak"
echo "  ✅ .env CORS updated."

# ---------------------------------------------------------------------------
# Step 3: Tutor docker-compose.yml network patching
# ---------------------------------------------------------------------------
echo ""
echo "── Step 3: Tutor docker-compose.yml ───────────────────────────"

if [[ ! -f "$TUTOR_COMPOSE" ]]; then
  echo "  ⚠️  ${TUTOR_COMPOSE} not found. Skipping."
  echo "     You must manually add ${DOCKER_NETWORK} to the Tutor compose file."
else
  if grep -q "${DOCKER_NETWORK}" "$TUTOR_COMPOSE" 2>/dev/null; then
    echo "  ✅ Already patched with ${DOCKER_NETWORK}."
  else
    echo "  Patching..."
    cp "$TUTOR_COMPOSE" "${TUTOR_COMPOSE}.bak"

    python3 << PYEOF
import yaml, sys

compose_file = """${TUTOR_COMPOSE}"""
network_name = "${DOCKER_NETWORK}"

with open(compose_file) as f:
    data = yaml.safe_load(f)

# Add external network at top level
if 'networks' not in data:
    data['networks'] = {}
data['networks'][network_name] = {'external': True}

# Add network to lms service
if 'services' in data and 'lms' in data['services']:
    lms = data['services']['lms']
    if 'networks' not in lms:
        lms['networks'] = {}
    if 'default' not in lms['networks']:
        lms['networks']['default'] = {'aliases': ['${LMS_HOST}']}
    if network_name not in lms['networks']:
        lms['networks'][network_name] = {'aliases': ['lms.mitxonline']}

with open(compose_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("    ✅ Patched successfully.")
PYEOF
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Connect LMS to mitxonline network
# ---------------------------------------------------------------------------
echo ""
echo "── Step 4: Docker network ─────────────────────────────────────"

if ! docker network inspect "${DOCKER_NETWORK}" > /dev/null 2>&1; then
  echo "  ⚠️  ${DOCKER_NETWORK} does not exist."
  echo "     Start MITx Online first: docker compose up -d"
else
  if docker ps --format '{{.Names}}' | grep -q "^${LMS_CONTAINER}$"; then
    if docker network inspect "${DOCKER_NETWORK}" 2>/dev/null | grep -q "${LMS_CONTAINER}"; then
      echo "  ✅ ${LMS_CONTAINER} already on ${DOCKER_NETWORK}."
    else
      docker network connect "${DOCKER_NETWORK}" "${LMS_CONTAINER}"
      echo "  ✅ Connected ${LMS_CONTAINER} to ${DOCKER_NETWORK}."
    fi
  else
    echo "  ⚠️  ${LMS_CONTAINER} not running. Start Tutor first, then re-run."
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Create/retrieve OAuth2 Application in MITx Online
# ---------------------------------------------------------------------------
echo ""
echo "── Step 5: OAuth2 Application (MITx Online → LMS) ─────────────"

OAUTH_CLIENT_ID=""
OAUTH_CLIENT_SECRET=""

if docker ps --format '{{.Names}}' | grep -q "^${WEB_CONTAINER}$"; then
  OAUTH_OUTPUT=$(docker exec "${WEB_CONTAINER}" python manage.py shell -c "
from oauth2_provider.models import Application

app = Application.objects.filter(name='edx-oauth-app').first()
if app:
    print(f'EXISTS|{app.client_id}|{app.client_secret}')
else:
    app = Application.objects.create(
        name='edx-oauth-app',
        client_type='confidential',
        authorization_grant_type='authorization-code',
        skip_authorization=True,
        redirect_uris='http://${LMS_HOST}:${LMS_PORT}/auth/complete/ol-oauth2/',
    )
    print(f'CREATED|{app.client_id}|{app.client_secret}')
" 2>/dev/null)

  OAUTH_STATUS=$(echo "$OAUTH_OUTPUT" | grep -E '^(EXISTS|CREATED)' | cut -d'|' -f1)
  OAUTH_CLIENT_ID=$(echo "$OAUTH_OUTPUT" | grep -E '^(EXISTS|CREATED)' | cut -d'|' -f2)
  OAUTH_CLIENT_SECRET=$(echo "$OAUTH_OUTPUT" | grep -E '^(EXISTS|CREATED)' | cut -d'|' -f3)

  if [[ -n "$OAUTH_CLIENT_ID" ]]; then
    if [[ "$OAUTH_STATUS" == "CREATED" ]]; then
      echo "  ✅ Created OAuth2 app 'edx-oauth-app'"
    else
      echo "  ✅ Found existing OAuth2 app 'edx-oauth-app'"
    fi
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  OAuth2 Application Credentials                         │"
    echo "  │                                                         │"
    echo "  │  Client ID:     ${OAUTH_CLIENT_ID}"
    echo "  │  Client Secret: ${OAUTH_CLIENT_SECRET}"
    echo "  │                                                         │"
    echo "  │  Use these as Key and Secret in the LMS                 │"
    echo "  │  OAuth2ProviderConfig (see next steps).                 │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
  else
    echo "  ❌ Failed to create/retrieve OAuth2 app."
    echo "     Output: ${OAUTH_OUTPUT}"
    echo "     Create manually: see docs/part2-tutor-lms-mitxonline.md Step 5"
  fi
else
  echo "  ⚠️  ${WEB_CONTAINER} not running. Cannot create OAuth2 app."
  echo "     Create manually: see docs/part2-tutor-lms-mitxonline.md Step 5"
fi

# ---------------------------------------------------------------------------
# Step 6: LMS development.py CORS snippet
# ---------------------------------------------------------------------------
echo ""
echo "── Step 6: LMS CORS settings ──────────────────────────────────"

MARKER="# --- CORS for local MFEs + MITx Online hosts ---"

if [[ ! -f "$LMS_DEV_PY" ]]; then
  echo "  ⚠️  ${LMS_DEV_PY} not found. Skipping."
  echo "     Add the CORS snippet manually (see docs/part2-tutor-lms-mitxonline.md)."
else
  if grep -q "$MARKER" "$LMS_DEV_PY" 2>/dev/null; then
    echo "  ✅ CORS snippet already present."
  else
    echo "  Appending CORS snippet..."

    cat >> "$LMS_DEV_PY" << PYEOF

${MARKER}
from corsheaders.defaults import default_headers

CORS_ORIGIN_WHITELIST = [
$(for p in "${MFE_PORTS[@]}"; do echo "    \"http://${MFE_HOST}:${p}\","; done)
    "http://${LMS_HOST}:${LMS_PORT}",
    "http://${MITXONLINE_HOST}:${MITXONLINE_DJANGO_PORT}",
    "http://${MITXONLINE_HOST}:${APISIX_PORT}",
]
CORS_ORIGIN_ALLOW_ALL = False
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOW_HEADERS = list(default_headers) + ["use-jwt-cookie"]
LOGIN_REDIRECT_URL = "/"
ENABLE_REQUIRE_THIRD_PARTY_AUTH = False
PYEOF
    echo "  ✅ Done."
  fi
fi

# ---------------------------------------------------------------------------
# Step 7: Restart MITx Online web/nginx
# ---------------------------------------------------------------------------
echo ""
echo "── Step 7: Restarting MITx Online ─────────────────────────────"
docker compose up -d web nginx 2>&1 | tail -3
echo "  ✅ web/nginx restarted."

# ---------------------------------------------------------------------------
# Step 8: Verify
# ---------------------------------------------------------------------------
echo ""
echo "── Step 8: Verification ───────────────────────────────────────"

check() {
  local label="$1" ok="$2" detail="$3"
  if [[ "$ok" == "true" ]]; then
    printf "  ✅ %-40s %s\n" "$label" "$detail"
  else
    printf "  ❌ %-40s %s\n" "$label" "$detail"
  fi
}

# LMS on network
NET_OK=$(docker network inspect "${DOCKER_NETWORK}" 2>/dev/null | grep -q "${LMS_CONTAINER}" && echo true || echo false)
check "LMS on ${DOCKER_NETWORK}" "$NET_OK" ""

# LMS → MITx Online connectivity
if docker ps --format '{{.Names}}' | grep -q "^${LMS_CONTAINER}$"; then
  VARNISH_STATUS=$(docker exec "${LMS_CONTAINER}" curl -sf -o /dev/null -w "%{http_code}" "http://${VARNISH_CONTAINER}/.well-known/openid-configuration" 2>/dev/null || echo "failed")
  check "LMS → MITx Online" "$([ "$VARNISH_STATUS" = "200" ] && echo true || echo false)" "$VARNISH_STATUS"
else
  check "LMS → MITx Online" "false" "container not running"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "    1. Create OAuth2ProviderConfig in LMS admin using the"
echo "       Client ID and Secret printed above (Step 5):"
echo "       http://${LMS_HOST}:${LMS_PORT}/admin/third_party_auth/oauth2providerconfig/"
echo "    2. Restart LMS: tutor dev restart lms"
echo "    3. Staff admin login:"
echo "       http://${LMS_HOST}:${LMS_PORT}/login?next=/admin&skip_authn_mfe=1"
if [[ -n "${OAUTH_CLIENT_ID:-}" ]]; then
echo ""
echo "  OAuth2 credentials (from Step 5):"
echo "    Client ID:     ${OAUTH_CLIENT_ID}"
echo "    Client Secret: ${OAUTH_CLIENT_SECRET}"
fi
echo "════════════════════════════════════════════════════════════════"

