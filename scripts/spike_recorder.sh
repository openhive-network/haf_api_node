#!/usr/bin/env bash
#
# Spike recorder — captures pgbouncer pool state, pg_stat_activity, and
# blocking-lock data when the stack looks busy. Designed to run as a
# long-lived background process on the host that owns the docker stack.
#
# Heartbeat (one terse line per poll) is always appended; full snapshots
# (per-backend query text, locks-not-granted detail) are written only
# while the "spike" condition is armed, so quiet hours stay cheap.
#
# Usage:
#   scripts/spike_recorder.sh --prefix hafrc14 --log-dir /var/log/haf-spikes
#
# Defaults: auto-detect prefix from running containers, write to
# /var/log/haf-spikes, poll every 10s. Spike trigger: >= 15 non-idle
# pg_stat_activity rows OR any pgbouncer cl_waiting > 0 OR any
# pgbouncer pool with sv_idle == 0 while sv_active > 0 (saturation).

set -euo pipefail

INTERVAL=10
THRESHOLD_ACTIVITY=15
THRESHOLD_WAITERS=1
COOLDOWN=3              # polls below threshold before disarming
SIZE_LOG_EVERY_N_POLLS=30  # sample table sizes every 30 polls = 5 min at 10s
LOG_DIR=/var/log/haf-spikes
PREFIX=""

# Tables whose disk size we track over time. Useful when vacuum_truncate is
# disabled on them — confirms the table size plateaus rather than growing
# unboundedly (which would mean dead-tuple slots aren't being reused).
SIZED_TABLES=("hafd.hive_state"
              "hafd.contexts"
              "hafd.operations_reversible"
              "hafd.transactions_reversible"
              "hafd.account_operations_reversible")

usage() {
    cat <<EOF
Usage: $0 [options]

  --prefix NAME         compose project prefix (e.g. hafrc14). Auto-detected if omitted.
  --log-dir DIR         where to write heartbeat + spike logs (default: $LOG_DIR)
  --interval SECONDS    poll interval (default: $INTERVAL)
  --threshold-activity N   non-idle backend count that arms a spike (default: $THRESHOLD_ACTIVITY)
  --threshold-waiters N    pgbouncer cl_waiting count that arms a spike (default: $THRESHOLD_WAITERS)
  --cooldown N          consecutive below-threshold polls to disarm (default: $COOLDOWN)
  -h, --help            show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --threshold-activity) THRESHOLD_ACTIVITY="$2"; shift 2 ;;
        --threshold-waiters) THRESHOLD_WAITERS="$2"; shift 2 ;;
        --cooldown) COOLDOWN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$PREFIX" ]; then
    PREFIX=$(docker ps --format '{{.Names}}' | grep -E -- '-haf-1$' | head -1 | sed 's/-haf-1$//')
    if [ -z "$PREFIX" ]; then
        echo "could not auto-detect prefix; pass --prefix" >&2
        exit 1
    fi
fi

PG_CONT="${PREFIX}-haf-1"
PGB_CONT="${PREFIX}-pgbouncer-1"

mkdir -p "$LOG_DIR"

heartbeat_log() { echo "${LOG_DIR}/heartbeat-$(date -u +%Y%m%d).log"; }
sizes_log()     { echo "${LOG_DIR}/table-sizes-$(date -u +%Y%m%d).log"; }

# Sample disk size + tuple counts for the SIZED_TABLES set. Appends one
# pipe-delimited row per table per call. Header (if absent) added on first call.
log_table_sizes() {
    local out
    out="$(sizes_log)"
    if [ ! -f "$out" ]; then
        echo "timestamp|table|heap_bytes|total_bytes|n_live_tup|n_dead_tup" > "$out"
    fi
    docker exec -i "$PG_CONT" psql -U postgres -t -A -F'|' haf_block_log <<SQL 2>/dev/null >> "$out" || true
SELECT
  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  s.schemaname || '.' || s.relname,
  pg_relation_size(c.oid),
  pg_total_relation_size(c.oid),
  s.n_live_tup,
  s.n_dead_tup
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE (s.schemaname || '.' || s.relname) IN (
  '$(IFS=','; echo "${SIZED_TABLES[*]}" | sed "s/,/','/g")'
)
ORDER BY s.relname;
SQL
}

# pg_stat_activity quick-summary: counts non-idle backends and longest-running query age.
quick_activity() {
    docker exec -i "$PG_CONT" psql -U postgres -t -A -F'|' haf_block_log <<'SQL' 2>/dev/null || echo "ERR|0|0|0"
SELECT
  'OK',
  count(*) FILTER (WHERE state != 'idle' AND pid != pg_backend_pid()) AS active,
  COALESCE(EXTRACT(epoch FROM (now() - min(query_start) FILTER (WHERE state != 'idle' AND pid != pg_backend_pid())))::int, 0) AS oldest_age_s,
  (SELECT count(*) FROM pg_locks WHERE NOT granted) AS waiting_locks
FROM pg_stat_activity;
SQL
}

# pgbouncer SHOW POOLS — single row per (db,user). cl_waiting is the queue depth.
quick_pgbouncer() {
    docker exec "$PGB_CONT" psql -h 127.0.0.1 -p 6432 -U pgbouncer -t -A -F'|' pgbouncer -c 'SHOW POOLS;' 2>/dev/null || echo ""
}

# Sum cl_waiting across all (db,user) pools. Column 4 is cl_waiting in standard
# pgbouncer SHOW POOLS output: database|user|cl_active|cl_waiting|sv_active|...
sum_waiters() {
    quick_pgbouncer | awk -F'|' 'NF >= 5 { s += $4 } END { print s+0 }'
}

# Detect any pool that is fully saturated server-side: sv_idle == 0 AND
# sv_active > 0. This catches the hivemind hot-pool case where postgrest
# holds the queue internally and pgbouncer's cl_waiting stays at zero, but
# the underlying postgres throughput is at the wall.
# Modern pgbouncer SHOW POOLS columns:
#   1 db, 2 user, 3 cl_active, 4 cl_waiting,
#   5 cl_active_cancel_req, 6 cl_waiting_cancel_req,
#   7 sv_active, 8 sv_active_cancel, 9 sv_being_canceled,
#   10 sv_idle, 11 sv_used, 12 sv_tested, 13 sv_login,
#   14 maxwait, 15 maxwait_us, 16 pool_mode, 17 load_balance_hosts
saturated_pools() {
    quick_pgbouncer | awk -F'|' 'NF >= 10 && $7+0 > 0 && $10+0 == 0 { c++ } END { print c+0 }'
}

# Full snapshot — only called while armed.
full_snapshot() {
    local out="$1"
    {
        echo "=========================================="
        echo "snapshot at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "=========================================="

        echo
        echo "--- pgbouncer SHOW POOLS ---"
        docker exec "$PGB_CONT" psql -h 127.0.0.1 -p 6432 -U pgbouncer -x pgbouncer -c 'SHOW POOLS;' 2>&1 || true

        echo
        echo "--- pgbouncer SHOW STATS ---"
        docker exec "$PGB_CONT" psql -h 127.0.0.1 -p 6432 -U pgbouncer -x pgbouncer -c 'SHOW STATS;' 2>&1 || true

        echo
        echo "--- pg_stat_activity by (state, wait_event_type, wait_event) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT state, wait_event_type, wait_event, application_name, count(*)
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY 1,2,3,4
ORDER BY count(*) DESC;
SQL

        echo
        echo "--- non-idle queries (oldest first, top 40) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT pid,
       (now() - query_start)::interval(0) AS age,
       state, wait_event_type, wait_event, application_name,
       LEFT(regexp_replace(query, '\s+', ' ', 'g'), 200) AS query
FROM pg_stat_activity
WHERE state != 'idle' AND pid != pg_backend_pid()
ORDER BY query_start
LIMIT 40;
SQL

        echo
        echo "--- pg_locks NOT granted (waiters) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT l.pid, l.locktype, l.mode, l.relation::regclass AS rel,
       (now() - a.query_start)::interval(0) AS waiting_for,
       LEFT(regexp_replace(a.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE NOT l.granted
ORDER BY a.query_start;
SQL

        echo
        echo "--- blocking pairs (who holds what the waiters need) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT blocked.pid AS blocked_pid,
       blocking.pid AS blocking_pid,
       blocked.application_name AS blocked_app,
       blocking.application_name AS blocking_app,
       (now() - blocking.query_start)::interval(0) AS blocking_age,
       LEFT(regexp_replace(blocking.query, '\s+', ' ', 'g'), 160) AS blocking_query
FROM pg_stat_activity blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bp(pid)
JOIN pg_stat_activity blocking ON blocking.pid = bp.pid;
SQL

        echo
        echo "--- active vacuum/analyze (pg_stat_progress_vacuum + autovacuum workers) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT pid, datname, relid::regclass AS relation, phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count, max_dead_tuple_bytes, dead_tuple_bytes
FROM pg_stat_progress_vacuum;
SQL
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT pid, backend_type, application_name,
       (now() - backend_start)::interval(0) AS up_for,
       (now() - query_start)::interval(0) AS query_age,
       state, wait_event_type, wait_event,
       LEFT(query, 160) AS query
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker'
   OR query ILIKE '%vacuum%'
   OR query ILIKE '%analyze%';
SQL

        echo
        echo "--- pg_stat_statements top by mean+max time (planner-regression sniff) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT calls,
       ROUND(mean_exec_time::numeric, 1) AS mean_ms,
       ROUND(max_exec_time::numeric, 1) AS max_ms,
       ROUND((max_exec_time / NULLIF(mean_exec_time,0))::numeric, 1) AS max_over_mean,
       ROUND(stddev_exec_time::numeric, 1) AS stddev_ms,
       LEFT(regexp_replace(query, '\s+', ' ', 'g'), 200) AS query
FROM pg_stat_statements
WHERE calls > 50
ORDER BY (mean_exec_time * calls) DESC
LIMIT 15;
SQL

        echo
        echo "--- recent autovacuum activity on hivemind tables (last 30 min) ---"
        docker exec -i "$PG_CONT" psql -U postgres haf_block_log <<'SQL' 2>&1 || true
SELECT relname,
       last_autovacuum, last_vacuum, last_autoanalyze,
       autovacuum_count, vacuum_count, n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'hivemind_app'
  AND (last_autovacuum > now() - interval '30 minutes'
       OR last_vacuum    > now() - interval '30 minutes'
       OR last_autoanalyze > now() - interval '30 minutes')
ORDER BY GREATEST(COALESCE(last_autovacuum, 'epoch'),
                  COALESCE(last_vacuum, 'epoch'),
                  COALESCE(last_autoanalyze, 'epoch')) DESC
LIMIT 15;
SQL

        echo
    } >> "$out"
}

armed=0
disarm_countdown=0
spike_log=""
size_poll_counter=0

echo "spike_recorder started: prefix=$PREFIX log_dir=$LOG_DIR interval=${INTERVAL}s threshold_activity=${THRESHOLD_ACTIVITY} threshold_waiters=${THRESHOLD_WAITERS} size_sample=${SIZE_LOG_EVERY_N_POLLS}p"

# Sample table sizes immediately so we have a starting point.
log_table_sizes

while true; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    IFS='|' read -r status active oldest_age waiting_locks <<<"$(quick_activity)"
    waiters=$(sum_waiters)
    saturated=$(saturated_pools)
    : "${active:=0}"; : "${oldest_age:=0}"; : "${waiting_locks:=0}"; : "${waiters:=0}"; : "${saturated:=0}"

    line="$ts active=${active} oldest_age_s=${oldest_age} locks_waiting=${waiting_locks} pgb_cl_waiting=${waiters} pgb_saturated_pools=${saturated} status=${status:-?}"
    echo "$line" >> "$(heartbeat_log)"

    over_threshold=0
    if [ "${active:-0}" -ge "$THRESHOLD_ACTIVITY" ] \
       || [ "${waiters:-0}" -ge "$THRESHOLD_WAITERS" ] \
       || [ "${saturated:-0}" -ge 1 ]; then
        over_threshold=1
    fi

    if [ "$over_threshold" -eq 1 ]; then
        if [ "$armed" -eq 0 ]; then
            armed=1
            spike_log="${LOG_DIR}/spike-$(date -u +%Y%m%dT%H%M%SZ).log"
            echo "$ts ARMED — writing $spike_log" >> "$(heartbeat_log)"
        fi
        disarm_countdown=$COOLDOWN
        full_snapshot "$spike_log"
    elif [ "$armed" -eq 1 ]; then
        disarm_countdown=$((disarm_countdown - 1))
        if [ "$disarm_countdown" -le 0 ]; then
            armed=0
            echo "$ts DISARMED" >> "$(heartbeat_log)"
            spike_log=""
        else
            full_snapshot "$spike_log"
        fi
    fi

    size_poll_counter=$((size_poll_counter + 1))
    if [ "$size_poll_counter" -ge "$SIZE_LOG_EVERY_N_POLLS" ]; then
        log_table_sizes
        size_poll_counter=0
    fi

    sleep "$INTERVAL"
done
