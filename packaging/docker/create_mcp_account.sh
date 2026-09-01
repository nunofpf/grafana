#!/bin/sh
# Ensures a dedicated Grafana admin account for the Grafana MCP server exists on startup.
# Only creates the MCP account if it doesn't already exist, then removes
# the default admin account if it's still present, so the script is idempotent.
# Configured via CMF_GRAFANA_MCP_ACCOUNT_NAME/_PASSWORD/_EMAIL env vars; no-op if login is unset.
set -eu

: "${CMF_GRAFANA_MCP_ACCOUNT_NAME:=}"

if [ -z "$CMF_GRAFANA_MCP_ACCOUNT_NAME" ]; then
  exit 0
fi

until curl -sf "http://localhost:3000/api/health" >/dev/null 2>&1; do
  sleep 1
done

mcp_user_id=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
  "http://localhost:3000/api/users/lookup?loginOrEmail=$CMF_GRAFANA_MCP_ACCOUNT_LOGIN" 2>/dev/null \
  | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

if [ -z "$mcp_user_id" ]; then
  curl -sf -X POST -H "Content-Type: application/json" \
    -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    -d "{\"name\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"login\":\"$CMF_GRAFANA_MCP_ACCOUNT_NAME\",\"password\":\"$CMF_GRAFANA_MCP_ACCOUNT_PASSWORD\",\"email\":\"${CMF_GRAFANA_MCP_ACCOUNT_EMAIL:-$CMF_GRAFANA_MCP_ACCOUNT_NAME@localhost}\"}" \
    "http://localhost:3000/api/admin/users" >/dev/null
fi

# Drop the default admin account, now that the MCP account exists to take its place.
admin_user_id=$(curl -sf -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
"http://localhost:3000/api/users/lookup?loginOrEmail=admin" 2>/dev/null \
| sed -n 's/.*"id":\([0-9]*\).*/\1/p')

if [ -n "$admin_user_id" ]; then
curl -sf -X DELETE -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    "http://localhost:3000/api/admin/users/$admin_user_id" >/dev/null
fi
