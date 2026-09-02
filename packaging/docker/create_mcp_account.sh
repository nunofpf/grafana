#!/bin/sh
# Ensures a dedicated Grafana admin account for the Grafana MCP server exists on startup.
# Creates MCP account if missing, deletes default admin account. Script is idempotent.
# Required: CMF_GRAFANA_MCP_ACCOUNT_NAME, CMF_GRAFANA_MCP_ACCOUNT_PASSWORD.
# Optional: CMF_GRAFANA_MCP_ACCOUNT_EMAIL, GF_SECURITY_ADMIN_{USER,PASSWORD} (defaults: admin/admin).
set -eu

log() {
  echo "[create_mcp_account] $*"
}

: "${CMF_GRAFANA_MCP_ACCOUNT_NAME:=}"
: "${CMF_GRAFANA_MCP_ACCOUNT_PASSWORD:=}"
: "${GF_SECURITY_ADMIN_USER:=admin}"
: "${GF_SECURITY_ADMIN_PASSWORD:=admin}"

if [ -z "$CMF_GRAFANA_MCP_ACCOUNT_NAME" ]; then
  log "CMF_GRAFANA_MCP_ACCOUNT_NAME is not set, skipping."
  exit 0
fi

if [ -z "$CMF_GRAFANA_MCP_ACCOUNT_PASSWORD" ]; then
  log "CMF_GRAFANA_MCP_ACCOUNT_PASSWORD is not set, skipping."
  exit 0
fi

http_status() {
  curl -s -o /dev/null -w "%{http_code}" -u "$1:$2" "http://localhost:3000$3"
}

# Extracts the id field from Grafana JSON responses.
json_get_id() {
  echo "$1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'
}

log "Waiting for Grafana to become healthy..."
until curl -sf "http://localhost:3000/api/health" >/dev/null 2>&1; do
  sleep 1
done
log "Grafana is healthy."

# 1. Check if the MCP account already exists and works (e.g. on subsequent container starts)
mcp_auth_code=$(http_status "$CMF_GRAFANA_MCP_ACCOUNT_NAME" "$CMF_GRAFANA_MCP_ACCOUNT_PASSWORD" "/api/org")
if [ "$mcp_auth_code" = "200" ]; then
  log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' already exists and is authenticated. Setup already completed."
  exit 0
fi

# 2. Check if default admin credentials work to perform initial setup.
# A 401/403 means the default admin was already removed by a previous run, so there is nothing left to do.
admin_auth_code=$(http_status "$GF_SECURITY_ADMIN_USER" "$GF_SECURITY_ADMIN_PASSWORD" "/api/org")

case "$admin_auth_code" in
  200) ;;
  401 | 403)
    log "Default admin account '$GF_SECURITY_ADMIN_USER' cannot authenticate (HTTP $admin_auth_code); assuming setup already completed by a previous run."
    exit 0
    ;;
  *)
    log "Unexpected response (HTTP $admin_auth_code) while checking default admin account. Skipping."
    exit 0
    ;;
esac

lookup_response=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=$CMF_GRAFANA_MCP_ACCOUNT_NAME" 2>&1) || lookup_response=""
mcp_user_id=$(json_get_id "$lookup_response")

if [ -z "$mcp_user_id" ]; then
  log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' not found, creating it..."
  create_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    -d "{\"name\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"login\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"password\":\"$CMF_GRAFANA_MCP_ACCOUNT_PASSWORD\",\"email\":\"${CMF_GRAFANA_MCP_ACCOUNT_EMAIL:-$CMF_GRAFANA_MCP_ACCOUNT_NAME@localhost}\"}" \
    "http://localhost:3000/api/admin/users" 2>&1) || create_status="error"
  case "$create_status" in
    201) log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' created successfully." ;;
    409) log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' already exists." ;;
    *) log "MCP account creation returned HTTP $create_status; proceeding anyway." ;;
  esac
else
  log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' already exists (id=$mcp_user_id), skipping creation."
fi

# Drop the default admin account, now that the MCP account exists to take its place.
admin_lookup_response=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=$GF_SECURITY_ADMIN_USER" 2>&1) || admin_lookup_response=""
admin_user_id=$(json_get_id "$admin_lookup_response")

if [ -n "$admin_user_id" ]; then
  log "Default admin account found (id=$admin_user_id), deleting it..."
  delete_response=$(curl -sf -w "\n%{http_code}" -X DELETE -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    "http://localhost:3000/api/admin/users/$admin_user_id" 2>&1) || true
  log "Delete admin account response: $delete_response"
else
  log "Default admin account not found, nothing to delete."
fi

log "Done."
