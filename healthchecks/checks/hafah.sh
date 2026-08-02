#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

# Full-path liveness: /version is rewritten to the get_version DB function,
# so this round-trips rewriter -> postgrest -> pgbouncer -> postgres and
# catches a wedged postgrest that direct SQL checks can't see.
check_http_alive "hafah" "${HAFAH_HEALTH_URL:-http://hafah-postgrest-rewriter:80/version}"

shed_up "${HAFAH_SHED_MAXCONNS:-48 10 5}"
exit 0
