#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql): is_instance_ready + LIB age. This MUST stay ahead of
# the app probes — during HAF massive sync the app sync-status functions
# intentionally error rather than run unindexed lookups, and this gate reports
# the real reason instead.
check_haf_lib

# Each app's postgrest liveness plus its last-block age from the SQL function
# behind /sync-status (see check_http_sync_age.sh).
check_sync_status "reptracker" 60 "${REPTRACKER_LIVE_URL:-http://reputation-tracker-postgrest:3001/live}" \
  "$POSTGRES_URL_REPTRACKER" reptracker_endpoints.get_rep_sync_status "reptracker_endpoints, reptracker_app"
check_sync_status "hivemind" 60 "${HIVEMIND_LIVE_URL:-http://hivemind-postgrest-server:3001/live}" \
  "$POSTGRES_URL_HIVEMIND" hivemind_endpoints.get_sync_status "hivemind_endpoints, public"

shed_up "${HIVEMIND_SHED_MAXCONNS:-64 12 6}"
exit 0
