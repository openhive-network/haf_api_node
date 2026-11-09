#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes the app probes.
check_haf_lib

# hafbe's /sync-status reports the LEAST block across all of its HAF contexts
# (hafbe_app, hafbe_bal, reptracker_app), so this single check
# replaces the separate reptracker + hafbe/btracker SQL age checks.
check_sync_status "hafbe" 60 "${HAFBE_LIVE_URL:-http://block-explorer-postgrest:3001/live}" \
  "$POSTGRES_URL_HAFBE" hafbe_endpoints.get_hafbe_sync_status "hafbe_endpoints, hafbe_bal, reptracker_app"

shed_up "${HAFBE_SHED_MAXCONNS:-32 8 4}"
exit 0
