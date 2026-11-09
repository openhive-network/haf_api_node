#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes the app probes.
check_haf_lib

# postgrest liveness plus the app's last-block age from the SQL function
# behind /sync-status (see check_http_sync_age.sh).
#
# 60s like every sibling. haf_fyp's standalone stack used 360, but measured block age
# at the tip is 2-6s: the ranker runs in its own process and does not stall the sync
# loop. If a false `down` appears, sample /sync-status' last_block_time before raising
# this.
check_sync_status "haf_fyp" 60 "${HAF_FYP_LIVE_URL:-http://haf-fyp-postgrest:3001/live}" \
  "$POSTGRES_URL_HAF_FYP" haf_fyp_endpoints.get_sync_status "haf_fyp_endpoints, public"

# Cap from the live postgrest pool (see pool_cap_up in shed_functions.sh).
pool_cap_up "haf_fyp" "${HAF_FYP_METRICS_URL:-http://haf-fyp-postgrest:3001/metrics}" \
  "${HAF_FYP_SERVER_MAXCONN:-32}" "${HAF_FYP_SHED_MAXCONNS:-32 8 4}"
exit 0
