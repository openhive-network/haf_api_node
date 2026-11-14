# shellcheck shell=sh
# PostgreSQL memory sizing for a HAF node, sourced by haf/entrypoint.sh (which writes the result to
# haf_postgresql_conf.d/zz-memory.conf each time the haf container starts) and reduce_writebacks.sh
# (which limits the ZFS ARC around it), so both work from the same shared_buffers.
#
# Sizes are whole GiB, which PostgreSQL calls GB:
#   shared_buffers       POSTGRESQL_SHARED_BUFFERS_GB when set; otherwise 40% of RAM rounded down,
#                        capped at 64GB, and at least 1GB (the floor applies below 2.5GB of RAM)
#   zfs_arc_max          RAM - (shared_buffers + PostgreSQL's shared segment overhead
#                        + kernel overhead + max dirty pages + safety margin), at least 20GB
#   effective_cache_size shared_buffers + zfs_arc_max, at most RAM
#
# PostgreSQL's shared segment is larger than shared_buffers (buffer descriptors, lock tables,
# wal_buffers): 48GB of buffers made a 50425MB segment, so 5% of shared_buffers, rounded up, is
# reserved for it.

PG_SHARED_BUFFERS_PERCENT=40
PG_SHARED_BUFFERS_MAX_GB=64
PG_SHARED_BUFFERS_MIN_GB=1
PG_SHARED_SEGMENT_OVERHEAD_PERCENT=5
PG_KERNEL_OVERHEAD_GB=2          # kernel slab, pagetables, etc.
PG_MAX_DIRTY_GB=12               # reduce_writebacks.sh's vm.dirty_bytes
PG_SAFETY_MARGIN_GB=10           # free memory for bursts, containers
PG_ZFS_ARC_MIN_GB=20

_PGM_KB_PER_GB=1048576

# pg_memory_total_kb ROOT prints the RAM this process may use, in kB: MemTotal from
# ROOT/proc/meminfo, or the cgroup (v2 or v1) memory limit under ROOT/sys/fs/cgroup when that is
# lower ("/" for the running system).  Inside a container that is the host's RAM unless the
# container is memory-limited.
pg_memory_total_kb() {
  _pgm_total_kb=$(awk '/^MemTotal:/ { print $2 }' "${1%/}/proc/meminfo")
  _pgm_limit=
  if [ -r "${1%/}/sys/fs/cgroup/memory.max" ]; then
    _pgm_limit=$(cat "${1%/}/sys/fs/cgroup/memory.max")
  elif [ -r "${1%/}/sys/fs/cgroup/memory/memory.limit_in_bytes" ]; then
    _pgm_limit=$(cat "${1%/}/sys/fs/cgroup/memory/memory.limit_in_bytes")
  fi
  case $_pgm_limit in
    '' | *[!0-9]*) ;;
    *)
      if [ $((_pgm_limit / 1024)) -lt "$_pgm_total_kb" ]; then
        _pgm_total_kb=$((_pgm_limit / 1024))
      fi
      ;;
  esac
  echo "$_pgm_total_kb"
}

# pg_shared_buffers_gb TOTAL_KB [OVERRIDE_GB] prints shared_buffers in GB, and on stderr how it was
# chosen.  A non-empty OVERRIDE_GB (POSTGRESQL_SHARED_BUFFERS_GB) wins; it must be a whole number of
# GB, at least 1, or the function prints an error and returns 1.
pg_shared_buffers_gb() {
  if [ -n "${2:-}" ]; then
    case $2 in
      *[!0-9]* | 0*)
        echo "Error: POSTGRESQL_SHARED_BUFFERS_GB must be a whole number of GB (at least 1), got '$2'" >&2
        return 1
        ;;
    esac
    echo "shared_buffers = ${2}GB, from POSTGRESQL_SHARED_BUFFERS_GB" >&2
    echo "$2"
    return 0
  fi

  _pgm_ram_gb=$(($1 / _PGM_KB_PER_GB))
  _pgm_sb_gb=$(($1 * PG_SHARED_BUFFERS_PERCENT / 100 / _PGM_KB_PER_GB))
  if [ "$_pgm_sb_gb" -gt "$PG_SHARED_BUFFERS_MAX_GB" ]; then
    echo "shared_buffers = ${PG_SHARED_BUFFERS_MAX_GB}GB: ${PG_SHARED_BUFFERS_PERCENT}% of ${_pgm_ram_gb}GB RAM is ${_pgm_sb_gb}GB, capped at ${PG_SHARED_BUFFERS_MAX_GB}GB" >&2
    _pgm_sb_gb=$PG_SHARED_BUFFERS_MAX_GB
  elif [ "$_pgm_sb_gb" -lt "$PG_SHARED_BUFFERS_MIN_GB" ]; then
    echo "shared_buffers = ${PG_SHARED_BUFFERS_MIN_GB}GB: ${PG_SHARED_BUFFERS_PERCENT}% of ${_pgm_ram_gb}GB RAM is below the ${PG_SHARED_BUFFERS_MIN_GB}GB floor" >&2
    _pgm_sb_gb=$PG_SHARED_BUFFERS_MIN_GB
  else
    echo "shared_buffers = ${_pgm_sb_gb}GB: ${PG_SHARED_BUFFERS_PERCENT}% of ${_pgm_ram_gb}GB RAM" >&2
  fi
  echo "$_pgm_sb_gb"
}

# pg_shared_segment_gb SHARED_BUFFERS_GB prints the memory PostgreSQL's shared segment takes for
# those buffers, overhead included, in GB.
pg_shared_segment_gb() {
  echo $(($1 + ($1 * PG_SHARED_SEGMENT_OVERHEAD_PERCENT + 99) / 100))
}

# pg_zfs_arc_max_gb TOTAL_KB SHARED_BUFFERS_GB prints the ZFS ARC limit in GB.
pg_zfs_arc_max_gb() {
  _pgm_arc_gb=$(($1 / _PGM_KB_PER_GB - $(pg_shared_segment_gb "$2") - PG_KERNEL_OVERHEAD_GB - PG_MAX_DIRTY_GB - PG_SAFETY_MARGIN_GB))
  if [ "$_pgm_arc_gb" -lt "$PG_ZFS_ARC_MIN_GB" ]; then
    _pgm_arc_gb=$PG_ZFS_ARC_MIN_GB
  fi
  echo "$_pgm_arc_gb"
}

# pg_effective_cache_size_gb TOTAL_KB SHARED_BUFFERS_GB prints effective_cache_size in GB.
pg_effective_cache_size_gb() {
  _pgm_ecs_gb=$(($2 + $(pg_zfs_arc_max_gb "$1" "$2")))
  if [ "$_pgm_ecs_gb" -gt $(($1 / _PGM_KB_PER_GB)) ]; then
    _pgm_ecs_gb=$(($1 / _PGM_KB_PER_GB))
  fi
  echo "$_pgm_ecs_gb"
}
