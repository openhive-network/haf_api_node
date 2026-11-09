#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes the app probes.
check_haf_lib

# hafah has no app context; its sync-status function reports HAF's
# irreversible block, so beyond postgrest liveness this re-checks LIB age as
# the app reports it.
check_sync_status "hafah" 60 "${HAFAH_LIVE_URL:-http://hafah-postgrest:3001/live}" \
  "$POSTGRES_URL_HAFAH" hafah_endpoints.get_sync_status "hafah_endpoints, public"

shed_up "${HAFAH_SHED_MAXCONNS:-48 10 5}"
exit 0
