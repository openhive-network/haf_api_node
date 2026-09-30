# shellcheck shell=sh
. "$(dirname "$0")/format_seconds.sh"

# Upper bound (seconds) on each HAF query below. Nothing else bounds psql: a
# database that stops answering without closing the socket would otherwise
# hang the check indefinitely, and since nc forks one child per agent
# connection, 11 scripts polled every 10s leave stuck psql children -- and
# their pgbouncer client slots (max_client_conn) -- piling up. Same default
# as HTTP_CHECK_TIMEOUT in check_http_sync_age.sh, and well under the 10s
# agent-inter. Set via haproxy.yaml.
PSQL_CHECK_TIMEOUT="${PSQL_CHECK_TIMEOUT:-5}"

# Calculate time offset if EXPECTED_BLOCK_TIME is set (for CI environments)
# This allows healthchecks to work with historical blockchain data
calculate_time_offset() {
  if [ -n "${EXPECTED_BLOCK_TIME:-}" ]; then
    # Convert EXPECTED_BLOCK_TIME to epoch seconds
    EXPECTED_EPOCH=$(date +%s -d "${EXPECTED_BLOCK_TIME}")
    CURRENT_EPOCH=$(date +%s)
    # Calculate how far in the past we're operating
    TIME_OFFSET=$((CURRENT_EPOCH - EXPECTED_EPOCH))
  else
    TIME_OFFSET=0
  fi
}

# Apply time offset to age calculations
adjust_age_for_ci() {
  _age="$1"
  if [ "$TIME_OFFSET" -gt 0 ]; then
    # Subtract the offset to get the "real" age relative to expected time
    echo $((_age - TIME_OFFSET))
  else
    echo "$_age"
  fi
}

# haf_query <sql>: run one query against $POSTGRES_URL under
# PSQL_CHECK_TIMEOUT. Prints the single result value and returns psql's
# status (124/143 when timeout had to kill it).
haf_query() {
  timeout "$PSQL_CHECK_TIMEOUT" psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="$1"
}

# haf_query_failed <status>: report a failed or timed-out query and exit.
# Every exit from check_haf_lib must print a line. The agent scripts run
# under set -e, so an unguarded VAR=$(psql ...) that fails exits with no
# output; HAProxy logs an empty agent reply as "Layer7 invalid response" and
# ignores it (the server keeps its previous state), so that is a poll that
# says nothing rather than a DOWN -- but it hides the failure.
haf_query_failed() {
  case "$1" in
    124|143) echo "down #HAF query timed out after ${PSQL_CHECK_TIMEOUT}s" ;;
    *)       echo "down #HAF query failed" ;;
  esac
  exit 3
}

check_haf_lib() {
  calculate_time_offset

  INSTANCE_READY=$(haf_query "SELECT hive.is_instance_ready();") || haf_query_failed "$?"
  if [ "$INSTANCE_READY" != t ]; then
    echo "down #HAF not in sync"
    exit 1
  fi
  LAST_IRREVERSIBLE_BLOCK_AGE=$(haf_query "select extract('epoch' from now() - created_at)::integer from hafd.blocks where num = (select consistent_block from hafd.hive_state)") || haf_query_failed "$?"

  # Adjust age for CI environments
  ADJUSTED_AGE=$(adjust_age_for_ci "$LAST_IRREVERSIBLE_BLOCK_AGE")

  if [ "$ADJUSTED_AGE" -gt 60 ]; then
    age_string=$(format_seconds "$LAST_IRREVERSIBLE_BLOCK_AGE")
    if [ "$TIME_OFFSET" -gt 0 ]; then
      echo "down #HAF LIB over a minute old ($age_string, adjusted from CI offset)"
    else
      echo "down #HAF LIB over a minute old ($age_string)"
    fi
    exit 2
  fi
}
