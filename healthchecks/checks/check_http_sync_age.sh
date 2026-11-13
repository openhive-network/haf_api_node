#! /bin/sh
# Helpers for the agent checks of the postgrest-backed apps.
#
# Liveness and sync age come from separate sources, and neither takes a
# connection from the app's postgrest pool. Under heavy traffic that pool
# (PGRST_DB_POOL, a handful of connections) is legitimately saturated; a probe
# that had to wait for a slot timed out, the agent answered "down", and HAProxy
# answered every request with an instant 503 until the next poll -- overload
# turned into an outage (hivesense, 2026-11-08/09). A saturated-but-alive app
# must stay up and shed load through HAProxy's queue limits instead.
#
#  - liveness: postgrest's admin server (/live on PGRST_ADMIN_SERVER_PORT)
#    answers without a database connection, so it catches a dead or hung
#    postgrest process.
#  - sync age: the same SQL function the app's /sync-status endpoint runs,
#    called with psql over pgbouncer as the app's own role.
#
# Not covered: a postgrest that is alive but cannot get a database
# connection. The app then answers 5xx/504, which HAProxy's queue limits and
# error counters already bound. The rewriter is covered by HAProxy's TCP
# check on the server line.
#
# Source this after check_haf_lib.sh: it relies on PSQL_CHECK_TIMEOUT and the
# TIME_OFFSET / adjust_age_for_ci CI-offset machinery defined there (and set
# up by the check_haf_lib call).

. "$(dirname "$0")/format_seconds.sh"

HTTP_CHECK_TIMEOUT="${HTTP_CHECK_TIMEOUT:-5}"

# check_postgrest_live <name> <live_url>
#
# Go down (exit 10) unless the postgrest admin server's /live answers 2xx
# within HTTP_CHECK_TIMEOUT.
check_postgrest_live() {
  wget -q --timeout="$HTTP_CHECK_TIMEOUT" -O /dev/null "$2" 2>/dev/null || {
    echo "down #$1 postgrest not live"
    exit 10
  }
}

# check_sync_status <name> <threshold_seconds> <live_url> <postgres_url> <function> <search_path>
#
# read_sync_status, then go down if the app's last processed block is older
# than the threshold.
check_sync_status() {
  read_sync_status "$1" "$3" "$4" "$5" "$6"
  check_http_block_time "$1" "$2" "$_block_time"
}

# read_sync_status <name> <live_url> <postgres_url> <function> <search_path>
#
# Check the app's postgrest liveness, then call its sync-status SQL function
# (schema-qualified, no arguments; returns {"last_block_num": N,
# "last_block_time": "YYYY-MM-DDTHH:MM:SS"} as json or as a row) and set
# _block_num and _block_time from it. Goes down if postgrest is not live, the
# query fails, or the app has no block time to judge.
# <search_path> is what postgrest sets for the app (PGRST_DB_SCHEMA, then
# PGRST_DB_EXTRA_SEARCH_PATH), since the function may rely on it. The
# function fails fast during HAF massive sync, which correctly reads as
# down here -- though the check_haf_lib gate in every agent script runs
# first and normally catches that case.
#
# A null last_block_time is reported in two distinct ways: with block 0 (or
# no number at all) the app context exists but has not processed anything
# yet; with a real block number the app's sync-status lookup could not find
# the timestamp of its own current block. The latter was seen with
# sync_status() implementations that joined hafd.blocks only: a forking
# context's freshly processed head block still sits in hafd.blocks_reversible
# for a few hundred ms before OBI makes it irreversible, so ~1 in 80 probes
# came back without a time and the backend flapped (fixed app-side in
# reputation_tracker!228, balance_tracker!396, haf_block_explorer!512).
read_sync_status() {
  _name="$1"
  check_postgrest_live "$_name" "$2"
  # One query string is one transaction, so SET LOCAL and the call share a
  # server connection under pgbouncer's transaction pooling. to_json of the
  # FROM alias yields the object whether the function returns json or a row.
  _sync_status=$(timeout "$PSQL_CHECK_TIMEOUT" psql "$3" --quiet --no-align --tuples-only \
      --command="BEGIN; SET LOCAL search_path TO $5; SELECT to_json(s) FROM $4() s LIMIT 1; COMMIT") || {
    case "$?" in
      124|143) echo "down #$_name sync-status query timed out after ${PSQL_CHECK_TIMEOUT}s" ;;
      *)       echo "down #$_name sync-status query failed" ;;
    esac
    exit 16
  }
  _block_num=$(echo "$_sync_status" | sed -n 's/.*"last_block_num"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
  _block_time=$(echo "$_sync_status" | sed -n 's/.*"last_block_time"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$_block_time" ]; then
    if [ -z "$_block_num" ] || [ "$_block_num" -eq 0 ]; then
      # block 0 / null: app context exists but no block processed yet
      echo "down #$_name has no processed block yet"
      exit 14
    fi
    # a block number without a timestamp: report what was actually observed
    echo "down #$_name block $_block_num has no timestamp in sync-status"
    exit 15
  fi
}

# check_http_block_time <name> <threshold_seconds> <block_time_string>
#
# Compute the age of a block timestamp in API format (e.g.
# "2026-07-13T14:22:15" or "2026-07-13 14:22:15", UTC) and go down if it
# exceeds the threshold, honoring the CI time offset the same way the
# psql-based age checks do.
check_http_block_time() {
  _name="$1"
  _threshold="$2"
  _time_string="$3"
  # busybox date parses "YYYY.MM.DD-HH:MM:SS"; accept both "T" and space
  # separated timestamps
  _epoch=$(date -u +%s -d "$(echo "$_time_string" | sed 's/^\([0-9]\{4\}\)-\([0-9][0-9]\)-\([0-9][0-9]\)[T ]/\1.\2.\3-/')" 2>/dev/null) || _epoch=""
  if [ -z "$_epoch" ]; then
    echo "down #$_name returned unparseable block time"
    exit 12
  fi
  _age=$(( $(date -u +%s) - _epoch ))
  _adjusted_age=$(adjust_age_for_ci "$_age")
  if [ "$_adjusted_age" -gt "$_threshold" ]; then
    age_string=$(format_seconds "$_age")
    if [ "$TIME_OFFSET" -gt 0 ]; then
      echo "down #$_name block too old ($age_string, adjusted from CI offset)"
    else
      echo "down #$_name block too old ($age_string)"
    fi
    exit 13
  fi
}
