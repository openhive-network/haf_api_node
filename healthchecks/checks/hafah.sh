#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# hafah has no app context; its /sync-status reports HAF's irreversible block
# through the full rewriter -> postgrest -> DB path, so this both exercises
# the real request path and re-checks LIB age end-to-end.
check_sync_status "hafah" 60 "${HAFAH_HEALTH_URL:-http://hafah-postgrest-rewriter:80/sync-status}"

shed_up "${HAFAH_SHED_MAXCONNS:-48 10 5}"
exit 0
