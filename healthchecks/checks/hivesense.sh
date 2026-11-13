#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

HIVESENSE_SYNC_THRESHOLD=60

# _hivesense_upstream_block — print the upstream's /sync-status last_block_num
# (HIVESENSE_SYNC_API, the API hivesense-sync pulls embeddings from), or
# nothing if it can't be fetched within HTTP_CHECK_TIMEOUT. busybox wget's
# --timeout is per read, so timeout(1) bounds the whole fetch.
_hivesense_upstream_block() {
  timeout "$HTTP_CHECK_TIMEOUT" wget -q --timeout="$HTTP_CHECK_TIMEOUT" -O - \
      "${HIVESENSE_SYNC_API:-https://api.hive.blog/hivesense-api}/sync-status" 2>/dev/null \
    | sed -n 's/.*"last_block_num"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

# _hivesense_stop_block — print B from "--stop-at-block=B" (or
# "--stop-at-block B") in HIVESENSE_SYNC_ARGS, the block processor's
# arguments, or nothing.
_hivesense_stop_block() {
  echo " ${HIVESENSE_SYNC_ARGS:-} " \
    | sed -n 's/.*[[:space:]]--stop-at-block[=[:space:]][[:space:]]*\([0-9][0-9]*\)[[:space:]].*/\1/p'
}

# _hivesense_frozen_note <last_block_num> — print why a hivesense whose last
# block is older than the threshold is deliberately frozen rather than stuck,
# or nothing if it is not. A sync-chain rebase freezes the generator with
# --stop-at-block and its downstream syncers then drain to that block and idle
# for hours while search keeps serving the frozen embeddings.
#  - sync (hivesense-sync): caught up with the upstream's last block, within
#    the threshold expressed in 3 s blocks. An unreachable upstream gives no
#    note, so the age rule applies.
#  - local (block processor): exactly at its configured stop block.
_hivesense_frozen_note() {
  [ -n "$1" ] || return 0
  case "${HIVESENSE_CONFIGURATION:-sync}" in
    sync)
      _upstream=$(_hivesense_upstream_block)
      if [ -n "$_upstream" ] && [ $((_upstream - $1)) -le $((HIVESENSE_SYNC_THRESHOLD / 3)) ]; then
        echo "hivesense frozen at upstream block $_upstream"
      fi
      ;;
    local)
      _stop=$(_hivesense_stop_block)
      if [ -n "$_stop" ] && [ "$1" -eq "$_stop" ]; then
        echo "hivesense frozen at stop block $_stop"
      fi
      ;;
  esac
}

# HAF gate first (psql) — see hivemind.sh for why this precedes the app probes.
check_haf_lib

# postgrest liveness plus the app's last-block age from the SQL function
# behind /sync-status (hive/hivesense!134; see check_http_sync_age.sh).
# hivesense's last_block_time tracks the head of the embeddings it serves and
# honestly lags during catch-up, so the standard 60s threshold applies --
# except during a deliberate freeze (a sync-chain rebase, see
# doc/hivesense-sync-chain-rebase.md), when the block can be hours old and
# hivesense still serves search correctly: then _hivesense_frozen_note keeps
# it up and says why in the agent's answer.
read_sync_status "hivesense" "${HIVESENSE_LIVE_URL:-http://hivesense-postgrest:3001/live}" \
  "$POSTGRES_URL_HIVESENSE" hivesense_endpoints.get_hivesense_sync_status "hivesense_endpoints, hivesense_app"

_frozen_note=""
# check_http_block_time exits on "down"; the subshell keeps its verdict so a
# freeze can override it.
_age_status=0
_age_verdict=$(check_http_block_time "hivesense" "$HIVESENSE_SYNC_THRESHOLD" "$_block_time") || _age_status=$?
if [ "$_age_status" -ne 0 ]; then
  [ "$_age_status" -eq 13 ] && _frozen_note=$(_hivesense_frozen_note "$_block_num")
  if [ -z "$_frozen_note" ]; then
    echo "$_age_verdict"
    exit "$_age_status"
  fi
fi

# Cap from the live postgrest pool (see pool_cap_up in shed_functions.sh).
_up=$(pool_cap_up "hivesense" "${HIVESENSE_METRICS_URL:-http://hivesense-postgrest:3001/metrics}" \
  "${HIVESENSE_SERVER_MAXCONN:-32}" "${HIVESENSE_SHED_MAXCONNS:-32 8 4}")
echo "$_up${_frozen_note:+ #$_frozen_note}"
exit 0
