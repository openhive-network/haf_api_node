#! /bin/sh
# Load-shed poller — the single writer of the shed level.
#
# Runs as one long-lived background process (started by docker_entrypoint.sh)
# so all hysteresis state lives in ordinary variables in one sequential loop;
# the stateless agent-check scripts just read the published level via
# shed_functions.sh. Publishing is atomic (write temp file + mv), and the
# file is rewritten every poll so readers can use its mtime as a liveness
# signal for the poller itself.
#
# Overload = signal A OR signal B (see shed_functions.sh):
#   A: hivemind postgrest has >= SHED_OVERLOAD_ACTIVE active queries AND the
#      oldest is >= SHED_OVERLOAD_AGE_S old (a backlog, not a brief burst),
#      OR total non-idle backends >= SHED_OVERLOAD_TOTAL_ACTIVE.
#   B: any pgbouncer pool saturated server-side, or any client waiting.
# Errors in a signal make it count as "not overloaded" (fail-open): a broken
# probe must never shed load.
#
# The level tightens one notch after SHED_CONFIRMATIONS consecutive
# overloaded polls and loosens one notch after SHED_COOLDOWN consecutive
# quiet polls, so it steps 0 -> 1 -> 2 and back rather than flapping.
#
# SHED_ARMED (default false) = log-only mode: decisions are computed and
# logged, but the published level is pinned to 0 so no shedding occurs.

. "$(dirname "$0")/shed_functions.sh"

SHED_POLL_INTERVAL="${SHED_POLL_INTERVAL:-5}"
SHED_CONFIRMATIONS="${SHED_CONFIRMATIONS:-2}"
SHED_COOLDOWN="${SHED_COOLDOWN:-3}"
# IMPORTANT: scale these to the deployment's ACTUAL postgrest pool sizes.
# SHED_OVERLOAD_ACTIVE should be ~80% of hivemind's PGRST_DB_POOL (default
# pool 10 -> 8); SHED_OVERLOAD_TOTAL_ACTIVE should sit above the server's
# normal busy concurrency (roughly 65% of the sum of all postgrest pools).
# If a deployment raises the pools (e.g. hivemind 30), raise these too or
# normal load will read as overload.
SHED_OVERLOAD_ACTIVE="${SHED_OVERLOAD_ACTIVE:-8}"
SHED_OVERLOAD_AGE_S="${SHED_OVERLOAD_AGE_S:-2}"
SHED_OVERLOAD_TOTAL_ACTIVE="${SHED_OVERLOAD_TOTAL_ACTIVE:-25}"
SHED_ARMED="${SHED_ARMED:-false}"
SHED_MAX_LEVEL=2

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) shed_poller: $1" >&2
}

publish_level() {
  echo "$1" > "${SHED_LEVEL_FILE}.tmp" && mv "${SHED_LEVEL_FILE}.tmp" "$SHED_LEVEL_FILE"
}

level=0
over_count=0
under_count=0

log "started: interval=${SHED_POLL_INTERVAL}s armed=${SHED_ARMED} confirmations=${SHED_CONFIRMATIONS} cooldown=${SHED_COOLDOWN} thresholds: hivemind_active>=${SHED_OVERLOAD_ACTIVE}&oldest>=${SHED_OVERLOAD_AGE_S}s, total_nonidle>=${SHED_OVERLOAD_TOTAL_ACTIVE}, pgbouncer=$([ -n "${POSTGRES_URL_PGBOUNCER:-}" ] && echo enabled || echo disabled)"
publish_level 0

while true; do
  overloaded=0
  reason=""

  # Signal A: pg_stat_activity
  activity=$(overload_activity_signal)
  if [ -n "$activity" ]; then
    hivemind_active=${activity%%|*}
    rest=${activity#*|}
    hivemind_oldest=${rest%%|*}
    total_nonidle=${rest#*|}
    if [ "${hivemind_active:-0}" -ge "$SHED_OVERLOAD_ACTIVE" ] \
       && [ "${hivemind_oldest:-0}" -ge "$SHED_OVERLOAD_AGE_S" ]; then
      overloaded=1
      reason="hivemind pool backlog (active=${hivemind_active} oldest=${hivemind_oldest}s)"
    elif [ "${total_nonidle:-0}" -ge "$SHED_OVERLOAD_TOTAL_ACTIVE" ]; then
      overloaded=1
      reason="total non-idle backends=${total_nonidle}"
    fi
  fi

  # Signal B: pgbouncer SHOW POOLS (only if a URL is configured)
  if [ "$overloaded" -eq 0 ]; then
    pgbouncer=$(overload_pgbouncer_signal)
    if [ -n "$pgbouncer" ]; then
      saturated=${pgbouncer%%|*}
      waiting=${pgbouncer#*|}
      if [ "${saturated:-0}" -ge 1 ]; then
        overloaded=1
        reason="pgbouncer saturated pools=${saturated}"
      elif [ "${waiting:-0}" -ge 1 ]; then
        overloaded=1
        reason="pgbouncer cl_waiting=${waiting}"
      fi
    fi
  fi

  # Hysteresis: step the level one notch at a time
  if [ "$overloaded" -eq 1 ]; then
    over_count=$((over_count + 1))
    under_count=0
    if [ "$over_count" -ge "$SHED_CONFIRMATIONS" ] && [ "$level" -lt "$SHED_MAX_LEVEL" ]; then
      level=$((level + 1))
      over_count=0
      log "TIGHTEN to level ${level}: ${reason}"
    fi
  else
    under_count=$((under_count + 1))
    over_count=0
    if [ "$under_count" -ge "$SHED_COOLDOWN" ] && [ "$level" -gt 0 ]; then
      level=$((level - 1))
      under_count=0
      log "LOOSEN to level ${level}"
    fi
  fi

  if [ "$SHED_ARMED" = "true" ]; then
    publish_level "$level"
  else
    # Log-only mode: keep computing/logging, but never actually shed. The
    # agent scripts also emit a bare "up" while disarmed, so HAProxy is never
    # told to cap anything (safe even against an unchanged haproxy config).
    # Log the maxconn hivemind WOULD be capped to, to make the effect concrete.
    if [ "$level" -gt 0 ] || [ "$overloaded" -eq 1 ]; then
      would=$(SHED_LEVEL_FILE=/dev/null; set -- ${HIVEMIND_SHED_MAXCONNS:-64 12 6}; \
              case "$level" in 1) echo "${2}";; 2) echo "${3}";; *) echo "${1}";; esac)
      log "log-only (SHED_ARMED=false): computed level=${level} (would cap hivemind maxconn -> ${would})${reason:+ [${reason}]}"
    fi
    publish_level 0
  fi

  sleep "$SHED_POLL_INTERVAL"
done
