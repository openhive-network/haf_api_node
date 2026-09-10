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
