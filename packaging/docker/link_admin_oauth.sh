#!/bin/sh
# Links the default Grafana admin account to a generic-OAuth identity on startup,
# so OAuth-based clients (e.g. the Grafana MCP server) can authenticate as admin.
# Script is idempotent. There is no public Grafana API to create this link, so the
# user_auth row is written directly to the sqlite database; id/uid values are
# looked up dynamically via the Grafana API instead of being hardcoded.
# Optional: GF_SECURITY_ADMIN_{USER,PASSWORD} (defaults: admin/admin), GF_PATHS_DATA (default: /var/lib/grafana).
set -eu

log() {
  echo "[link_admin_oauth] $*"
}

: "${GF_SECURITY_ADMIN_USER:=admin}"
: "${GF_SECURITY_ADMIN_PASSWORD:=admin}"
: "${GF_PATHS_DATA:=/var/lib/grafana}"

auth_module="oauth_generic_oauth"
db_path="$GF_PATHS_DATA/grafana.db"

log "Waiting for Grafana to become healthy..."
until curl -sf "http://localhost:3000/api/health" >/dev/null 2>&1; do
  sleep 1
done
log "Grafana is healthy."

if [ ! -f "$db_path" ]; then
  log "Grafana database not found at $db_path, skipping."
  exit 0
fi

# A 401/403 means the admin password was already rotated/removed by a previous run.
admin_auth_code=$(curl -s -o /dev/null -w "%{http_code}" -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" "http://localhost:3000/api/org")
case "$admin_auth_code" in
  200) ;;
  401 | 403)
    log "Default admin account '$GF_SECURITY_ADMIN_USER' cannot authenticate (HTTP $admin_auth_code); assuming setup already completed."
    exit 0
    ;;
  *)
    log "Unexpected response (HTTP $admin_auth_code) while checking admin account. Skipping."
    exit 0
    ;;
esac

lookup_response=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=$GF_SECURITY_ADMIN_USER" 2>&1) || lookup_response=""

admin_id=$(echo "$lookup_response" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
admin_uid=$(echo "$lookup_response" | sed -n 's/.*"uid":"\([^"]*\)".*/\1/p')

if [ -z "$admin_id" ] || [ -z "$admin_uid" ]; then
  log "Could not resolve id/uid for '$GF_SECURITY_ADMIN_USER', skipping."
  exit 0
fi

# admin_uid is Grafana-generated, but validate its shape before it reaches raw SQL below.
case "$admin_uid" in
  *[!A-Za-z0-9]*)
    log "Unexpected uid format for '$GF_SECURITY_ADMIN_USER', skipping."
    exit 0
    ;;
esac

# Use the admin's own uid as the external OAuth identity so the link is deterministic.
existing=$(sqlite3 "$db_path" \
  "SELECT COUNT(*) FROM user_auth WHERE user_id = $admin_id AND auth_module = '$auth_module' AND auth_id = '$admin_uid';")

if [ "$existing" -gt 0 ]; then
  log "Admin account already linked to '$auth_module', nothing to do."
  exit 0
fi

log "Linking admin account (id=$admin_id, uid=$admin_uid) to '$auth_module'..."
sqlite3 "$db_path" \
  "INSERT INTO user_auth (user_id, auth_module, auth_id, created, user_uid) VALUES ($admin_id, '$auth_module', '$admin_uid', datetime('now'), '$admin_uid');"
log "Done."
