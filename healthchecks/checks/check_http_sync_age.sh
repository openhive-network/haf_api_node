#! /bin/sh
# Helpers for health checks that probe through the postgrest layer.
#
# The psql-based checks talk to the database directly (via pgbouncer), so a
# wedged postgrest server or rewriter is invisible to them. These helpers
# exercise the real request path instead: rewriter -> postgrest -> pgbouncer
# -> postgres. Only endpoints that are DB round-trips are useful here (e.g.
# hivemind's catch-all rewrites every request to /rpc/home, hafah /version ->
# /rpc/get_version, reputation-tracker /last-synced-block ->
# /rpc/get_rep_last_synced_block).
#
# Source this after check_haf_lib.sh: check_http_block_time relies on the
# TIME_OFFSET / adjust_age_for_ci CI-offset machinery defined there (and set
# up by the check_haf_lib call).

. "$(dirname "$0")/format_seconds.sh"

HTTP_CHECK_TIMEOUT="${HTTP_CHECK_TIMEOUT:-5}"

# check_http_alive <name> <url> [post_data]
#
# Fetch the URL through the app's postgrest rewriter (POST with a JSON body
# if post_data is given, GET otherwise). Prints "down #<name> ..." and exits
# on connection failure, timeout, non-2xx status (busybox wget returns
# non-zero on HTTP errors), or a JSON-RPC error in the body. On success the
# response body is left in $HTTP_CHECK_RESPONSE for further inspection.
check_http_alive() {
  _name="$1"
  _url="$2"
  _post_data="${3:-}"
  if [ -n "$_post_data" ]; then
    HTTP_CHECK_RESPONSE=$(wget -q --timeout="$HTTP_CHECK_TIMEOUT" -O - \
        --header='Content-Type: application/json' \
        --post-data "$_post_data" "$_url" 2>/dev/null)
  else
    HTTP_CHECK_RESPONSE=$(wget -q --timeout="$HTTP_CHECK_TIMEOUT" -O - "$_url" 2>/dev/null)
  fi || {
    echo "down #$_name API unresponsive"
    exit 10
  }
  if echo "$HTTP_CHECK_RESPONSE" | grep -q '"error":'; then
    echo "down #$_name API returned an error"
    exit 11
  fi
}


# check_sync_status <name> <threshold_seconds> <url>
#
# Probe an app's /sync-status endpoint (the uniform HAF-app sync/health API:
# {"last_block_num": N, "last_block_time": "YYYY-MM-DDTHH:MM:SS"}) through
# its postgrest rewriter, and go down if the app's last processed block is
# older than the threshold. One call covers both "postgrest path works" and
# "app is synced". Requires app images that ship /sync-status (2026-08
# develop or later); the endpoint fails fast with an error during HAF
# massive sync, which correctly reads as down here — though the psql
# check_haf_lib gate in every agent script runs first and normally catches
# that case before any HTTP probe is made.
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
check_sync_status() {
  _name="$1"
  _threshold="$2"
  _url="$3"
  check_http_alive "$_name" "$_url"
  _block_num=$(echo "$HTTP_CHECK_RESPONSE" | sed -n 's/.*"last_block_num"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
  _block_time=$(echo "$HTTP_CHECK_RESPONSE" | sed -n 's/.*"last_block_time"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
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
  check_http_block_time "$_name" "$_threshold" "$_block_time"
}

# check_http_block_time <name> <threshold_seconds> <block_time_string>
#
# Compute the age of a block timestamp returned over the API (e.g.
# hivemind's db_head_time "2026-07-13 14:22:15", UTC) and go down if it
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
