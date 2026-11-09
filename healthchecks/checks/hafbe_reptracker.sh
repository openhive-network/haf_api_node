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
check_sync_status "reptracker" 60 "${REPTRACKER_LIVE_URL:-http://reputation-tracker-postgrest:3001/live}" \
  "$POSTGRES_URL_REPTRACKER" reptracker_endpoints.get_rep_sync_status "reptracker_endpoints, reptracker_app"

# Cap from the live postgrest pool (see pool_cap_up in shed_functions.sh).
pool_cap_up "reptracker" "${REPTRACKER_METRICS_URL:-http://reputation-tracker-postgrest:3001/metrics}" \
  "${REPUTATION_TRACKER_SERVER_MAXCONN:-32}" "${REPTRACKER_SHED_MAXCONNS:-32 8 4}"
exit 0
