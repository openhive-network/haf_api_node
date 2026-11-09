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
# haf_stats' context is non-forking, so this age is LIB age plus app lag; measured
# 2-4s at the tip. Its pg_cron rollups at 03:00-03:35 UTC can push it to ~47s, so
# look there first if a false `down` ever appears.
check_sync_status "haf_stats" 60 "${HAF_STATS_LIVE_URL:-http://haf-stats-postgrest:3001/live}" \
  "$POSTGRES_URL_HAF_STATS" haf_stats_endpoints.get_sync_status "haf_stats_endpoints, haf_stats_app"

# Cap from the live postgrest pool (see pool_cap_up in shed_functions.sh).
pool_cap_up "haf_stats" "${HAF_STATS_METRICS_URL:-http://haf-stats-postgrest:3001/metrics}" \
  "${HAF_STATS_SERVER_MAXCONN:-32}" "${HAF_STATS_SHED_MAXCONNS:-32 8 4}"
exit 0
