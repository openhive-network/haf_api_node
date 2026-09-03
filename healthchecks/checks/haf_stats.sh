#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API (hive/haf_stats!72), so
# this covers rewriter -> postgrest -> DB as well as the app's own block age.
# haf_stats tracks live blocks without the catch-up oscillation haf_fyp has, so
# the standard 60s threshold applies unchanged.
check_sync_status "haf_stats" 60 "${HAF_STATS_HEALTH_URL:-http://haf-stats-postgrest-rewriter:80/sync-status}"

shed_up "${HAF_STATS_SHED_MAXCONNS:-32 8 4}"
exit 0
