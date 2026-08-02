#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# hafbe's /sync-status reports the LEAST block across all of its HAF contexts
# (hafbe_app, hafbe_bal, reptracker_app), so this single full-path call
# replaces the separate reptracker + hafbe/btracker SQL age checks.
check_sync_status "hafbe" 60 "${HAFBE_HEALTH_URL:-http://block-explorer-postgrest-rewriter:80/sync-status}"

shed_up "${HAFBE_SHED_MAXCONNS:-32 8 4}"
exit 0
