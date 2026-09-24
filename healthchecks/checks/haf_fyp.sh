#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API (rewriter ->
# postgrest -> DB round-trip + app last-block age in one call).
#
# 60s like every sibling. haf_fyp's standalone stack used 360, but measured block age
# at the tip is 2-6s: the ranker runs in its own process and does not stall the sync
# loop. If a false `down` appears, sample /sync-status' last_block_time before raising
# this.
check_sync_status "haf_fyp" 60 "${HAF_FYP_HEALTH_URL:-http://haf-fyp-postgrest-rewriter:80/sync-status}"

shed_up "${HAF_FYP_SHED_MAXCONNS:-32 8 4}"
exit 0
