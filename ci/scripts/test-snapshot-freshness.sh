#!/usr/bin/env bash
#
# Test the shared_memory.bin freshness check snapshot_zfs_datasets.sh runs before a snapshot
# (shared_memory_freshness.sh) on fixture datadirs: a node stopped cleanly whose shared memory
# lived on a tmpfs (shared_memory.bin's mtime 15 minutes before the shutdown) passes, and a
# shared_memory.bin left over from an earlier run, a run with no clean shutdown, or a block_log
# written after the logged shutdown is refused.  No root or ZFS needed.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
LOGS=logs/hived/default
export TZ=UTC

fail() {
  echo "FAIL: $*"
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# datadir NAME SHARED_MEMORY_MTIME BLOCK_LOG_MTIME: a datadir with those file times and an empty
# hived log directory; prints its path
datadir() {
  local dir="$WORK/$1"
  mkdir -p "$dir/shared_memory/comments-rocksdb-storage" "$dir/blockchain" "$dir/$LOGS"
  : > "$dir/shared_memory/shared_memory.bin"
  : > "$dir/blockchain/block_log"
  touch -d "$2" "$dir/shared_memory/shared_memory.bin"
  touch -d "$3" "$dir/blockchain/block_log"
  echo "$dir"
}

# log_start FILE TIME / log_flush FILE TIME LIB: append a run's database open / clean shutdown to
# a hived log file, as hived logs them (with an API request quoting the shutdown line in between)
log_start() {
  printf '%s\n' \
    "${2}.100  chain_plugin.cpp:2142  plugin_startup       ] Database opening..." \
    "${2}.101  database.cpp:164  pre_open             ] Opening/creating shared memory from /home/hived/shm_dir" \
    "${2}.300  condenser_api.cpp:855  broadcast_transactio ] condenser_api_impl.broadcast_transaction.args.at(0) {\"body\":\"] Database flushed at last irreversible block: 1\"}" \
    >> "$1"
}

log_flush() {
  printf '%s\n' \
    "${2}.142  rocksdb_storage_provider.cpp:106  shutdownDb           ] \`COMMENT\` RocksDB database has been shutdowned." \
    "${2}.144  database.cpp:309  close                ] Database flushed at last irreversible block: $3" \
    "${2}.198  database.cpp:313  close                ] Database is closed" \
    "${2}.199  chain_plugin.cpp:1976  plugin_shutdown      ] database closed successfully" \
    >> "$1"
}

run_check() {
  sh -c '. "$1/shared_memory_freshness.sh"; check_shared_memory_freshness "$2"' sh "$REPO_DIR" "$1" 2>&1
}

# check NAME EXPECTED_RC DATADIR PATTERN...: runs the check under sh and expects its exit code and
# each (extended regex) pattern in its output
check() {
  local name="$1" expected="$2" dir="$3" output rc=0 pattern
  shift 3
  output=$(run_check "$dir") || rc=$?
  [ "$rc" -eq "$expected" ] || fail "$name: exit $rc, expected $expected: $output"
  for pattern in "$@"; do
    grep -qE -- "$pattern" <<< "$output" || fail "$name: no /$pattern/ in: $output"
  done
  if [ "$expected" -eq 0 ] && grep -q Warning <<< "$output"; then
    fail "$name: printed a warning: $output"
  fi
  echo "ok - $name"
}

dir=$(datadir tmpfs-clean "2026-11-12 03:30:32" "2026-11-12 03:45:42")
log_start "$dir/$LOGS/default.log" 2026-11-12T01:02:03
log_flush "$dir/$LOGS/default.log" 2026-11-12T03:45:47 110896093
check "clean shutdown, shared memory on tmpfs" 0 "$dir" \
  "from hived's log in $dir/$LOGS" \
  "last run opened the database: +2026-11-12T01:02:03$" \
  "clean shutdown: +2026-11-12T03:45:47, database flushed at last irreversible block 110896093" \
  "shared_memory.bin modified: +2026-11-12T03:30:32" \
  "newest write in blockchain/: +2026-11-12T03:45:42"

dir=$(datadir rotated "2026-11-12 03:30:32" "2026-11-12 03:45:42")
log_start "$dir/$LOGS/default.log.20261110T000000" 2026-11-10T08:00:00
log_flush "$dir/$LOGS/default.log.20261110T000000" 2026-11-10T09:00:00 110000000
log_start "$dir/$LOGS/default.log.20261111T000000" 2026-11-11T22:00:00
log_flush "$dir/$LOGS/default.log" 2026-11-12T03:45:47 110896093
check "run started in a rotated log file" 0 "$dir" \
  "last run opened the database: +2026-11-11T22:00:00$" "block 110896093"

dir=$(datadir start-rotated-out "2026-11-12 03:30:32" "2026-11-12 03:45:42")
log_flush "$dir/$LOGS/default.log" 2026-11-12T03:45:47 110896093
check "run started before the oldest kept log" 0 "$dir" \
  "last run opened the database: +not in the kept log files" \
  "mtime is not checked against it"

dir=$(datadir stale "2026-11-10 09:00:00" "2026-11-12 03:45:42")
log_start "$dir/$LOGS/default.log" 2026-11-10T08:00:00
log_flush "$dir/$LOGS/default.log" 2026-11-10T09:00:00 110000000
log_start "$dir/$LOGS/default.log" 2026-11-11T12:00:00
log_flush "$dir/$LOGS/default.log" 2026-11-12T03:45:47 110896093
check "shared_memory.bin from an earlier run" 1 "$dir" \
  "Warning: shared_memory.bin was last modified at 2026-11-10T09:00:00, before hived's last run opened the database at 2026-11-11T12:00:00: it is not the state that run flushed at block 110896093"

dir=$(datadir unclean "2026-11-12 03:45:40" "2026-11-12 03:45:42")
log_start "$dir/$LOGS/default.log" 2026-11-11T12:00:00
log_flush "$dir/$LOGS/default.log" 2026-11-12T01:00:00 110893000
log_start "$dir/$LOGS/default.log" 2026-11-12T01:05:00
check "no clean shutdown after the last database open" 1 "$dir" \
  "clean shutdown: +none logged since" \
  "Warning: hived's last run \(database opened at 2026-11-12T01:05:00\) logged no clean shutdown"

dir=$(datadir later-run "2026-11-12 03:45:40" "2026-11-12 05:00:00")
log_start "$dir/$LOGS/default.log" 2026-11-11T12:00:00
log_flush "$dir/$LOGS/default.log" 2026-11-12T03:45:47 110896093
check "block_log written after the logged shutdown" 1 "$dir" \
  "Warning: blockchain/ was written at 2026-11-12T05:00:00, more than 5 minutes after hived's last logged clean shutdown at 2026-11-12T03:45:47"

dir=$(datadir no-log-current "2026-11-12 03:45:40" "2026-11-12 03:45:42")
check "no hived log, mtimes close" 0 "$dir" "freshness by mtime: no hived database open or clean shutdown logged"

dir=$(datadir no-log-stale "2026-11-12 03:30:32" "2026-11-12 03:45:42")
check "no hived log, mtimes apart" 1 "$dir" \
  "shared_memory.bin modified: +2026-11-12T03:30:32" \
  "Warning: The shared_memory.bin file was not written to within 5 minutes .*\(910s apart\)"

dir=$(datadir empty-blockchain "2026-11-12 03:30:32" "2026-11-12 03:45:42")
rm "$dir/blockchain/block_log"
check "no files in blockchain/" 2 "$dir" "Warning: No files found in the blockchain directory"
