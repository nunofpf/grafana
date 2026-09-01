#!/bin/sh
# Ensures a dedicated Grafana admin account for the Grafana MCP server exists on startup.
# Only creates the MCP account if it doesn't already exist, then removes
# the default admin account if it's still present, so the script is idempotent.
# Configured via CMF_GRAFANA_MCP_ACCOUNT_NAME/_PASSWORD/_EMAIL env vars; no-op if login is unset.
set -eu

log() {
  echo "[create_mcp_account] $*"
}

: "${CMF_GRAFANA_MCP_ACCOUNT_NAME:=}"

if [ -z "$CMF_GRAFANA_MCP_ACCOUNT_NAME" ]; then
  log "CMF_GRAFANA_MCP_ACCOUNT_NAME is not set, skipping."
  exit 0
fi

log "Waiting for Grafana to become healthy..."
until curl -sf "http://localhost:3000/api/health" >/dev/null 2>&1; do
  sleep 1
done
log "Grafana is healthy."

lookup_response=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=$CMF_GRAFANA_MCP_ACCOUNT_NAME" 2>&1) || lookup_response=""
mcp_user_id=$(echo "$lookup_response" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

if [ -z "$mcp_user_id" ]; then
  log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' not found, creating it..."
  create_response=$(curl -sf -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    -d "{\"name\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"login\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"password\":\"$CMF_GRAFANA_MCP_ACCOUNT_PASSWORD\",\"email\":\"${CMF_GRAFANA_MCP_ACCOUNT_EMAIL:-$CMF_GRAFANA_MCP_ACCOUNT_NAME@localhost}\"}" \
    "http://localhost:3000/api/admin/users" 2>&1) || true
  log "Create account response: $create_response"
else
  log "MCP account '$CMF_GRAFANA_MCP_ACCOUNT_NAME' already exists (id=$mcp_user_id), skipping creation."
fi

# Drop the default admin account, now that the MCP account exists to take its place.
admin_lookup_response=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=admin" 2>&1) || admin_lookup_response=""
admin_user_id=$(echo "$admin_lookup_response" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

if [ -n "$admin_user_id" ]; then
  log "Default admin account found (id=$admin_user_id), deleting it..."
  delete_response=$(curl -sf -w "\n%{http_code}" -X DELETE -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    "http://localhost:3000/api/admin/users/$admin_user_id" 2>&1) || true
  log "Delete admin account response: $delete_response"
else
  log "Default admin account not found, nothing to delete."
fi

log "Done."
