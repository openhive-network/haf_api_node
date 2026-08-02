#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API (hive/hivesense!134).
# Note: hivesense syncs embeddings out of band; its last_block_time tracks
# the embedding server's head in steady state and honestly lags during
# catch-up, so the standard 60s threshold applies unchanged.
check_sync_status "hivesense" 60 "${HIVESENSE_HEALTH_URL:-http://hivesense-postgrest-rewriter:80/sync-status}"

shed_up "${HIVESENSE_SHED_MAXCONNS:-32 8 4}"
exit 0
