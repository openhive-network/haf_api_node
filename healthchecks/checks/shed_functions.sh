#! /bin/sh
# Shared functions for agent-check load shedding.
#
# The shed level is computed by a single background process (shed_poller.sh)
# and published atomically to $SHED_LEVEL_FILE. Agent-check scripts are pure
# readers: they map the current level to a per-app maxconn value and append
# it to their "up" response line. HAProxy applies "maxconn:<n>" from an agent
# response as the server's dynamic maxconn, so a raised level bounds the
# concurrency we forward to that backend while excess requests queue briefly
# and then shed with a fast 503 (see "timeout queue" in the haproxy configs).
#
# Levels: 0 = normal, 1 = reduced, 2 = floor. Fail-open: if the level file is
# missing or stale (poller died), readers behave as level 0 and no shedding
# occurs.

SHED_LEVEL_FILE="${SHED_LEVEL_FILE:-/run/shed.level}"
# Consider the published level stale after this many seconds (poller default
# interval is 5s, so 30s means several missed polls).
SHED_LEVEL_MAX_AGE="${SHED_LEVEL_MAX_AGE:-30}"

######### Level readers (used by the agent-check scripts) #########

# Print the current shed level (0/1/2). Fails open to 0.
shed_level() {
  level=$(cat "$SHED_LEVEL_FILE" 2>/dev/null) || { echo 0; return; }
  case "$level" in
    0|1|2) ;;
    *) echo 0; return ;;
  esac
  mtime=$(stat -c %Y "$SHED_LEVEL_FILE" 2>/dev/null) || { echo 0; return; }
  now=$(date +%s)
  if [ $((now - mtime)) -gt "$SHED_LEVEL_MAX_AGE" ]; then
    echo 0
  else
    echo "$level"
  fi
}

# shed_maxconn "<normal> <reduced> <floor>" — print the maxconn for the
# current shed level, e.g. shed_maxconn "64 12 6".
shed_maxconn() {
  # shellcheck disable=SC2086 # word-split "<normal> <reduced> <floor>" into $1 $2 $3
  set -- $1
  case "$(shed_level)" in
    1) echo "${2:-$1}" ;;
    2) echo "${3:-${2:-$1}}" ;;
    *) echo "$1" ;;
  esac
}

# shed_up "<normal> <reduced> <floor>" — print the agent-check "up" response
# line for a postgrest backend. It carries a "maxconn:<n>" directive ONLY when
# shedding is armed; when disarmed it emits a bare "up".
#
# This matters because HAProxy applies a "maxconn:" from an agent response even
# when the server line has no configured maxconn, and the value is sticky. So a
# bare "up" is what lets you run the detector in pure log-only mode — including
# against an UNCHANGED haproxy config (upgrade only the healthchecks image):
# the poller still logs every shed decision, but HAProxy never caps anything,
# so behavior is identical to before. Actual shedding requires SHED_ARMED=true.
shed_up() {
  if [ "${SHED_ARMED:-false}" = "true" ]; then
    echo "up maxconn:$(shed_maxconn "$1")"
  else
    echo "up"
  fi
}

######### Pool-metric caps (used by the agent-check scripts) #########
#
# Each postgrest-backed agent check sizes its own backend's cap from that
# app's live postgrest pool, read from the postgrest admin server's /metrics
# (no pool connection needed):
#   normal: ceil(pgrst_db_pool_max * POOL_CAP_FACTOR), never below pool_max + 1
#   tight:  pgrst_db_pool_max, after POOL_CAP_CONFIRMATIONS consecutive polls
#           with pgrst_db_pool_waiting > 0 or a rise in
#           pgrst_db_pool_timeouts_total; back to normal after
#           POOL_CAP_COOLDOWN consecutive quiet polls.
# Fail-open: if /metrics can't be read or parsed, the static cap (the app's
# *_SERVER_MAXCONN) is used, so a broken probe never sheds.
#
# POOL_CAP_MODE: off = don't read /metrics; log (default) = compute and log
# the cap every poll but advertise exactly what shed_up would; on = advertise
# "maxconn:<cap>" (the lower of the pool cap and the shed-level value when
# SHED_ARMED=true).
#
# The agent scripts are forked per poll (nc -e), so the hysteresis state lives
# in one small file per app under POOL_CAP_STATE_DIR. HAProxy runs one agent
# check per server at a time, so each file has a single writer.

POOL_CAP_MODE="${POOL_CAP_MODE:-log}"
POOL_CAP_FACTOR="${POOL_CAP_FACTOR:-1.5}"
POOL_CAP_CONFIRMATIONS="${POOL_CAP_CONFIRMATIONS:-2}"
POOL_CAP_COOLDOWN="${POOL_CAP_COOLDOWN:-3}"
POOL_CAP_STATE_DIR="${POOL_CAP_STATE_DIR:-/run/poolcap}"
# The agent's stdout is the HAProxy socket (and nc may hand it stderr too),
# so log lines go to the entrypoint's stderr, i.e. the container log.
POOL_CAP_LOG="${POOL_CAP_LOG:-/proc/1/fd/2}"

_pool_cap_log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pool_cap: $1" >> "$POOL_CAP_LOG" 2>/dev/null || true
}

# _pool_metrics <metrics_url> — print "pool_max waiting timeouts_total" as
# integers (postgrest reports floats such as "12.0"), or nothing if the
# endpoint can't be read or pool_max is missing / not positive.
_pool_metrics() {
  wget -q --timeout="${HTTP_CHECK_TIMEOUT:-5}" -O - "$1" 2>/dev/null \
    | awk '
        /^#/ { next }
        { n = $1; sub(/\{.*/, "", n) }
        n == "pgrst_db_pool_max"            { max = int($NF + 0); seen = 1 }
        n == "pgrst_db_pool_waiting"        { waiting = int($NF + 0) }
        n == "pgrst_db_pool_timeouts_total" { timeouts = int($NF + 0) }
        END { if (seen && max > 0) print max, waiting + 0, timeouts + 0 }'
}

# _pool_normal_cap <pool_max> — ceil(pool_max * POOL_CAP_FACTOR), at least
# pool_max + 1. A non-numeric or non-positive factor falls back to 1.5.
_pool_normal_cap() {
  awk -v m="$1" -v f="$POOL_CAP_FACTOR" 'BEGIN {
    if (f !~ /^[0-9]*\.?[0-9]+$/ || f + 0 <= 0) f = 1.5
    c = m * f; ci = int(c); if (ci < c) ci++
    if (ci < m + 1) ci = m + 1
    print ci }'
}

# pool_cap <name> <metrics_url> <static_maxconn> — update <name>'s hysteresis
# state from one /metrics read and print the cap for this poll; prints
# <static_maxconn> when the metrics can't be read (state is left untouched).
pool_cap() {
  _pc_metrics=$(_pool_metrics "$2")
  if [ -z "$_pc_metrics" ]; then
    _pool_cap_log "$1 metrics unreadable ($2), fail-open cap=$3 mode=$POOL_CAP_MODE"
    echo "$3"
    return
  fi
  # shellcheck disable=SC2086 # word-split "max waiting timeouts" into $1..$3
  set -- "$1" "$3" $_pc_metrics
  _pc_name=$1 _pc_max=$3 _pc_waiting=$4 _pc_timeouts=$5

  _pc_state="$POOL_CAP_STATE_DIR/$_pc_name"
  _pc_tight=0 _pc_over=0 _pc_under=0 _pc_prev_timeouts=""
  if [ -r "$_pc_state" ]; then
    read -r _pc_tight _pc_over _pc_under _pc_prev_timeouts < "$_pc_state" || true
  fi
  case "$_pc_tight$_pc_over$_pc_under$_pc_prev_timeouts" in
    *[!0-9]*) _pc_tight=0 _pc_over=0 _pc_under=0 _pc_prev_timeouts="" ;;
  esac

  _pc_reason=""
  if [ "$_pc_waiting" -gt 0 ]; then
    _pc_reason="waiting=$_pc_waiting"
  fi
  # A lower total than last poll means postgrest restarted, not pressure.
  if [ -n "$_pc_prev_timeouts" ] && [ "$_pc_timeouts" -gt "$_pc_prev_timeouts" ]; then
    _pc_reason="${_pc_reason:+$_pc_reason }timeouts+$((_pc_timeouts - _pc_prev_timeouts))"
  fi

  if [ -n "$_pc_reason" ]; then
    _pc_over=$((_pc_over + 1)) _pc_under=0
    if [ "$_pc_tight" -eq 0 ] && [ "$_pc_over" -ge "$POOL_CAP_CONFIRMATIONS" ]; then
      _pc_tight=1 _pc_over=0
      _pool_cap_log "$_pc_name TIGHTEN to pool_max=$_pc_max: $_pc_reason"
    fi
  else
    _pc_under=$((_pc_under + 1)) _pc_over=0
    if [ "$_pc_tight" -eq 1 ] && [ "$_pc_under" -ge "$POOL_CAP_COOLDOWN" ]; then
      _pc_tight=0 _pc_under=0
      _pool_cap_log "$_pc_name LOOSEN to normal"
    fi
  fi

  mkdir -p "$POOL_CAP_STATE_DIR" 2>/dev/null || true
  { echo "$_pc_tight $_pc_over $_pc_under $_pc_timeouts" > "$_pc_state.$$" \
      && mv "$_pc_state.$$" "$_pc_state"; } 2>/dev/null \
    || _pool_cap_log "$_pc_name cannot write state $_pc_state; hysteresis restarts every poll"

  if [ "$_pc_tight" -eq 1 ]; then
    _pc_cap=$_pc_max
  else
    _pc_cap=$(_pool_normal_cap "$_pc_max")
  fi
  _pool_cap_log "$_pc_name cap=$_pc_cap pool_max=$_pc_max waiting=$_pc_waiting timeouts_total=$_pc_timeouts tight=$_pc_tight mode=$POOL_CAP_MODE"
  echo "$_pc_cap"
}

# pool_cap_up <name> <metrics_url> <static_maxconn> "<normal> <reduced> <floor>"
# — print the agent-check "up" line for a postgrest backend. With
# POOL_CAP_MODE=on it carries "maxconn:<n>", n being the pool cap, or the
# lower of it and the shed-level value when SHED_ARMED=true. With off or log
# it is exactly shed_up's line (log mode still computes and logs the cap).
#
# HAProxy keeps the last agent-set maxconn after the agent stops sending one,
# so going from on back to off/log leaves the last cap in force until HAProxy
# reloads (or "set maxconn server <backend>/<server> <n>" on the admin socket).
pool_cap_up() {
  case "$POOL_CAP_MODE" in
    on)
      _pcu_cap=$(pool_cap "$1" "$2" "$3")
      if [ "${SHED_ARMED:-false}" = "true" ]; then
        _pcu_shed=$(shed_maxconn "$4")
        [ "$_pcu_shed" -lt "$_pcu_cap" ] && _pcu_cap=$_pcu_shed
      fi
      echo "up maxconn:$_pcu_cap"
      ;;
    log)
      pool_cap "$1" "$2" "$3" > /dev/null
      shed_up "$4"
      ;;
    *)
      shed_up "$4"
      ;;
  esac
}

######### Overload signals (used by shed_poller.sh) #########

# Signal A: postgres-side view of the hivemind postgrest pool plus overall
# activity, via the existing haf_admin connection ($POSTGRES_URL).
# Prints "hivemind_active|hivemind_oldest_age_s|total_nonidle" or nothing on error.
overload_activity_signal() {
  psql "$POSTGRES_URL" --quiet --no-align --tuples-only --field-separator='|' 2>/dev/null <<SQL
SELECT
  count(*) FILTER (WHERE application_name = '${HIVEMIND_POSTGREST_APPNAME:-hive-mind-postgrest}'
                     AND state = 'active') AS hivemind_active,
  COALESCE(EXTRACT(epoch FROM (now() - min(query_start)
             FILTER (WHERE application_name = '${HIVEMIND_POSTGREST_APPNAME:-hive-mind-postgrest}'
                       AND state = 'active')))::integer, 0) AS hivemind_oldest_age_s,
  count(*) FILTER (WHERE state != 'idle') AS total_nonidle
FROM pg_stat_activity
WHERE pid != pg_backend_pid();
SQL
}

# Signal B: pgbouncer's view, via SHOW POOLS on the admin pseudo-database
# ($POSTGRES_URL_PGBOUNCER, e.g. postgresql://stats@pgbouncer:6432/pgbouncer).
# Prints "saturated_pools|cl_waiting_total" or nothing if unconfigured/on error.
# Column positions (modern pgbouncer SHOW POOLS):
#   1 db, 2 user, 3 cl_active, 4 cl_waiting, ..., 7 sv_active, ..., 10 sv_idle
# A pool with sv_active > 0 and sv_idle == 0 is saturated server-side; this
# catches the hivemind hot-pool case where postgrest holds the queue
# internally and cl_waiting stays at zero while postgres throughput is at
# the wall (same trigger as scripts/spike_recorder.sh).
overload_pgbouncer_signal() {
  [ -n "${POSTGRES_URL_PGBOUNCER:-}" ] || return 0
  psql "$POSTGRES_URL_PGBOUNCER" --quiet --no-align --tuples-only --field-separator='|' \
       --command='SHOW POOLS;' 2>/dev/null \
    | awk -F'|' '
        NF >= 10 && $7+0 > 0 && $10+0 == 0 { saturated++ }
        NF >= 5                            { waiting += $4 }
        END { print saturated+0 "|" waiting+0 }'
}
