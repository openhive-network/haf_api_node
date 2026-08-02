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
