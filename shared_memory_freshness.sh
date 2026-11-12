# shellcheck shell=sh
# Whether a datadir's shared_memory.bin is the state hived left at its last clean shutdown,
# sourced by snapshot_zfs_datasets.sh.
#
# hived writes shared_memory.bin through a shared mapping, and such writes don't reliably update
# the file's mtime: on a tmpfs it can stay at a time early in the run, and a copy moved into the
# dataset keeps it.  So the evidence comes from hived's own log under logs/hived/default (rotated
# files included) when it has any:
#   - the last run that opened the database must have logged
#     "Database flushed at last irreversible block: N" (its clean shutdown);
#   - nothing in blockchain/ may have been written more than 5 minutes after that shutdown (a later
#     run the log doesn't describe);
#   - shared_memory.bin must have been modified since that run opened the database (a file left
#     over from an earlier run is older).
# With no such log, it falls back to comparing shared_memory.bin's mtime with the newest write in
# blockchain/.
#
# check_shared_memory_freshness DATADIR prints the source it used and the values it compared, and
# returns 0 when shared_memory.bin is current, 1 when a check failed (each failure printed as a
# "Warning:" line), and 2 when blockchain/ holds no files.

_SHM_FRESHNESS_SLACK=300

# hived's log lines are "<ISO time, UTC>  <file>:<line>  <function>  ] <message>"; anchoring the
# message at "] " and the end of the line keeps API request payloads that quote it from matching.
_SHM_RUN_START='\] Database opening\.\.\.$'
_SHM_RUN_FLUSH='\] Database flushed at last irreversible block: [0-9]+$'

_shm_epoch() {
  date -u -d "$(echo "$1" | tr T ' ')" +%s
}

_shm_time() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S'
}

_shm_newest_write() {
  find "$1" -type f -exec stat -c %Y {} + 2>/dev/null | sort -n | tail -1
}

# Prints "<start> <flush> <lib>" for the last hived run in the log files of directory $1: when it
# opened the database, when it logged its clean shutdown and at which last irreversible block, each
# "-" when not logged.  Rotated files (default.log.<time>) sort chronologically before default.log.
_shm_last_run() {
  set -- "$1"/default.log.* "$1"/default.log
  grep -h -E "$_SHM_RUN_START|$_SHM_RUN_FLUSH" "$@" 2>/dev/null | awk '
    index($0, "] Database opening...") { start = substr($0, 1, 19); flush = ""; lib = ""; next }
    { flush = substr($0, 1, 19); lib = $NF }
    END { print (start == "" ? "-" : start), (flush == "" ? "-" : flush), (lib == "" ? "-" : lib) }'
}

check_shared_memory_freshness() {
  _shm_file="$1/shared_memory/shared_memory.bin"
  _shm_log_dir="$1/logs/hived/default"
  _shm_mtime=$(stat -c %Y "$_shm_file")
  _shm_chain_write=$(_shm_newest_write "$1/blockchain")
  if [ -z "$_shm_chain_write" ]; then
    echo "Warning: No files found in the blockchain directory"
    return 2
  fi

  _shm_failed=0
  read -r _shm_start _shm_flush _shm_lib <<EOF
$(_shm_last_run "$_shm_log_dir")
EOF

  if [ "$_shm_start" = - ] && [ "$_shm_flush" = - ]; then
    echo "Checking shared_memory.bin freshness by mtime: no hived database open or clean shutdown logged in $_shm_log_dir"
    echo "  shared_memory.bin modified:    $(_shm_time "$_shm_mtime")"
    echo "  newest write in blockchain/:   $(_shm_time "$_shm_chain_write")"
    _shm_diff=$((_shm_chain_write - _shm_mtime))
    if [ "$_shm_diff" -gt "$_SHM_FRESHNESS_SLACK" ] || [ "$_shm_diff" -lt "-$_SHM_FRESHNESS_SLACK" ]; then
      echo "Warning: The shared_memory.bin file was not written to within 5 minutes of the last write to a file in the blockchain directory (${_shm_diff}s apart)."
      _shm_failed=1
    fi
    return "$_shm_failed"
  fi

  echo "Checking shared_memory.bin freshness from hived's log in $_shm_log_dir:"
  if [ "$_shm_start" = - ]; then
    echo "  last run opened the database:  not in the kept log files"
  else
    echo "  last run opened the database:  $_shm_start"
  fi
  if [ "$_shm_flush" = - ]; then
    echo "  clean shutdown:                none logged since"
  else
    echo "  clean shutdown:                $_shm_flush, database flushed at last irreversible block $_shm_lib"
  fi
  echo "  shared_memory.bin modified:    $(_shm_time "$_shm_mtime")"
  echo "  newest write in blockchain/:   $(_shm_time "$_shm_chain_write")"

  if [ "$_shm_flush" = - ]; then
    echo "Warning: hived's last run (database opened at $_shm_start) logged no clean shutdown, so shared_memory.bin may not have been flushed."
    return 1
  fi
  _shm_flush_epoch=$(_shm_epoch "$_shm_flush")
  if [ "$_shm_chain_write" -gt $((_shm_flush_epoch + _SHM_FRESHNESS_SLACK)) ]; then
    echo "Warning: blockchain/ was written at $(_shm_time "$_shm_chain_write"), more than 5 minutes after hived's last logged clean shutdown at $_shm_flush: a later run is missing from the log."
    _shm_failed=1
  fi
  if [ "$_shm_start" = - ]; then
    echo "  (the start of that run has rotated out of the log, so shared_memory.bin's mtime is not checked against it)"
  elif [ "$_shm_mtime" -lt "$(_shm_epoch "$_shm_start")" ]; then
    echo "Warning: shared_memory.bin was last modified at $(_shm_time "$_shm_mtime"), before hived's last run opened the database at $_shm_start: it is not the state that run flushed at block $_shm_lib."
    _shm_failed=1
  fi
  return "$_shm_failed"
}
