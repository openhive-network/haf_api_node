#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql): is_instance_ready + LIB age. This MUST stay ahead of
# any HTTP probe — during HAF massive sync the app endpoints intentionally
# error rather than run unindexed lookups, and this gate reports the real
# reason instead.
check_haf_lib

# Full-path sync checks through each app's postgrest rewriter (uniform
# /sync-status API: one call proves the rewriter->postgrest->DB path AND
# yields the app's last-block timestamp for the age judgment).
check_sync_status "reptracker" 60 "${REPTRACKER_HEALTH_URL:-http://reputation-tracker-postgrest-rewriter:80/sync-status}"
check_sync_status "hivemind" 60 "${HIVEMIND_HEALTH_URL:-http://hivemind-postgrest-rewriter:80/sync-status}"

shed_up "${HIVEMIND_SHED_MAXCONNS:-64 12 6}"
exit 0
