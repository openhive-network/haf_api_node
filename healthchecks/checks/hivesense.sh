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
# behind /sync-status (hive/hivesense!134; see check_http_sync_age.sh).
# Note: hivesense syncs embeddings out of band; its last_block_time tracks
# the embedding server's head in steady state and honestly lags during
# catch-up, so the standard 60s threshold applies unchanged.
check_sync_status "hivesense" 60 "${HIVESENSE_LIVE_URL:-http://hivesense-postgrest:3001/live}" \
  "$POSTGRES_URL_HIVESENSE" hivesense_endpoints.get_hivesense_sync_status "hivesense_endpoints, hivesense_app"

# Cap from the live postgrest pool (see pool_cap_up in shed_functions.sh).
pool_cap_up "hivesense" "${HIVESENSE_METRICS_URL:-http://hivesense-postgrest:3001/metrics}" \
  "${HIVESENSE_SERVER_MAXCONN:-32}" "${HIVESENSE_SHED_MAXCONNS:-32 8 4}"
exit 0
