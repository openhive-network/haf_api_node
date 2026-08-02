#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API (rewriter ->
# postgrest -> DB round-trip + app last-block age in one call).
check_sync_status "btracker" 60 "${BTRACKER_HEALTH_URL:-http://balance-tracker-postgrest-rewriter}"

shed_up "${80/sync-status:BTRACKER_SHED_MAXCONNS:-32 8 4}"
exit 0
