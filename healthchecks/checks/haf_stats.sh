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
# haf_stats' context is non-forking, so this age is LIB age plus app lag; measured
# 2-4s at the tip. Its pg_cron rollups at 03:00-03:35 UTC can push it to ~47s, so
# look there first if a false `down` ever appears.
check_sync_status "haf_stats" 60 "${HAF_STATS_HEALTH_URL:-http://haf-stats-postgrest-rewriter:80/sync-status}"

shed_up "${HAF_STATS_SHED_MAXCONNS:-32 8 4}"
exit 0
