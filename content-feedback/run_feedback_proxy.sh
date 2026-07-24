#!/usr/bin/env bash
#
# LOCAL-ONLY helper (do not deploy). Starts the content-feedback test proxy
# (feedback_proxy.py) with a real local mit-learn user auto-detected, so testers
# don't have to look up a global_id by hand.
#
# Usage:
#   ./run_feedback_proxy.sh                 # auto-detect a user from the mit-learn DB
#   FEEDBACK_USER_EMAIL=me@x.edu ./run_feedback_proxy.sh   # pin a specific user by email
#
# Env overrides (all optional):
#   MITLEARN_CONTAINER   mit-learn web container name (default: mit-learn-web-1)
#   MITLEARN_BACKEND     backend URL the proxy forwards to (default: http://localhost:8061)
#   FEEDBACK_PROXY_PORT  port to listen on (default: 8899)
#   FEEDBACK_MFE_ORIGIN  allowed CORS origin (default: http://localhost:2000)
set -euo pipefail

CONTAINER="${MITLEARN_CONTAINER:-mit-learn-web-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: mit-learn container '$CONTAINER' is not running." >&2
  echo "Start mit-learn (docker compose up) or set MITLEARN_CONTAINER." >&2
  exit 1
fi

# Auto-detect a user (or the one pinned by FEEDBACK_USER_EMAIL). We need a
# global_id because that is what APISIX would send and what the backend keys on.
LOOKUP_EMAIL="${FEEDBACK_USER_EMAIL:-}"
# Pass the email through the container env (not string-interpolated into the
# Python source) so an odd address can't break or inject into the snippet.
INFO=$(docker exec -e LOOKUP_EMAIL="$LOOKUP_EMAIL" "$CONTAINER" python manage.py shell -c "
import os
from users.models import User
email = os.environ.get('LOOKUP_EMAIL', '')
qs = User.objects.filter(global_id__isnull=False).exclude(global_id='')
u = qs.filter(email=email).first() if email else qs.first()
print((u.global_id + '|' + (u.email or '')) if u else '')
" 2>/dev/null | tr -d '\r' | grep '|' || true)

if [ -z "$INFO" ]; then
  echo "ERROR: no mit-learn user with a global_id found${LOOKUP_EMAIL:+ for email $LOOKUP_EMAIL}." >&2
  echo "Log in to mit-learn once (so a user is provisioned) or pass FEEDBACK_USER_EMAIL." >&2
  exit 1
fi

export FEEDBACK_USER_SUB="${INFO%%|*}"
export FEEDBACK_USER_EMAIL="${INFO##*|}"
echo "Using mit-learn user: $FEEDBACK_USER_EMAIL (global_id=$FEEDBACK_USER_SUB)"

exec python3 "$HERE/feedback_proxy.py"
