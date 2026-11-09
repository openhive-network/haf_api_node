#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes the app probes.
check_haf_lib

# postgrest liveness plus the app's last-block age from the SQL function
# behind /sync-status (see check_http_sync_age.sh).
check_sync_status "proxy_whitelist" 60 "${PROXY_WHITELIST_LIVE_URL:-http://proxy-whitelist-postgrest:3001/live}" \
  "$POSTGRES_URL_PROXY_WHITELIST" proxy_whitelist_endpoints.sync_status "proxy_whitelist_endpoints, proxy_whitelist_app"

shed_up "${PROXY_WHITELIST_SHED_MAXCONNS:-32 8 4}"
exit 0
