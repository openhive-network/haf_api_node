#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

REPTRACKER_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_REPTRACKER" --quiet --no-align --tuples-only --command="select extract('epoch' from hive.get_app_current_block_age('reptracker_app'))::integer")
# Adjust age for CI environments (TIME_OFFSET is set by check_haf_lib)
REPTRACKER_ADJUSTED_AGE=$(adjust_age_for_ci "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE")
if [ "$REPTRACKER_ADJUSTED_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE")
  if [ "$TIME_OFFSET" -gt 0 ]; then
    echo "down #reptracker_app block over a minute old ($age_string, adjusted from CI offset)"
  else
    echo "down #reptracker_app block over a minute old ($age_string)"
  fi
  exit 3
fi

# Check hivemind's sync age through the real request path (rewriter ->
# postgrest -> pgbouncer -> postgres) rather than via direct SQL, so a
# wedged postgrest server or rewriter also takes the backend down. The
# rewriter's catch-all sends this to hivemind's JSON-RPC handler in the DB;
# hive.db_head_state returns hivemind_app's last-imported block time.
check_http_alive "hivemind" "${HIVEMIND_HEALTH_URL:-http://hivemind-postgrest-rewriter:80/}" \
  '{"jsonrpc":"2.0","id":0,"method":"hive.db_head_state","params":{}}'
HIVEMIND_HEAD_TIME=$(echo "$HTTP_CHECK_RESPONSE" | sed 's/^.*"db_head_time": *"\([^"]*\)".*$/\1/')
check_http_block_time "hivemind" 60 "$HIVEMIND_HEAD_TIME"

shed_up "${HIVEMIND_SHED_MAXCONNS:-64 12 6}"
exit 0
