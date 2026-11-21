# shellcheck shell=sh
# PostgreSQL memory sizing for a HAF node, sourced by haf/entrypoint.sh (which writes the result to
# haf_postgresql_conf.d/zz-memory.conf each time the haf container starts), memory_plan.sh (which
# shows the host's whole plan and applies the ZFS ARC limit and the huge page reservation) and
# reserve_huge_pages.sh (which reserves huge pages for PostgreSQL's shared segment), so all of them
# work from the same shared_buffers and ARC limit.
#
# Sizes are whole GiB, which PostgreSQL calls GB:
#   shared_buffers       POSTGRESQL_SHARED_BUFFERS_GB when set; otherwise 50% of RAM rounded down,
#                        capped at 64GB, and at least 1GB (the floor applies below 2GB of RAM)
#   zfs_arc_max          ZFS_ARC_MAX_GB when set; otherwise RAM - (shared_buffers + PostgreSQL's
#                        shared segment overhead + kernel overhead + max dirty pages + other
#                        services), at least 20GB
#   other services       HAF_OTHER_SERVICES_GB when set; otherwise what memory_plan.sh measures,
#                        +25% headroom and at least 4GB; where nothing is measured (the haf
#                        container) a fixed 10GB safety margin
#   effective_cache_size shared_buffers + zfs_arc_max, at most RAM
#   vm.nr_hugepages      the shared segment below, in huge pages
#
# The ZFS ARC limit is not applied by the haf container: memory_plan.sh --apply sets it on the host
# (and --persist writes it to /etc/modprobe.d), and pg_zfs_arc_check below compares the limit in
# force with it.
#
# PostgreSQL's shared segment is larger than shared_buffers (buffer descriptors, lock tables,
# wal_buffers): 48GB of buffers made a 50425MB segment, so 5% of shared_buffers, rounded up, is
# reserved for it.  The huge pages are that same reservation, so the ARC formula counts them once.
# PostgreSQL uses huge pages only when its whole segment fits in them, hence the margin.

PG_SHARED_BUFFERS_PERCENT=50
PG_SHARED_BUFFERS_MAX_GB=64
PG_SHARED_BUFFERS_MIN_GB=1
PG_SHARED_SEGMENT_OVERHEAD_PERCENT=5
PG_KERNEL_OVERHEAD_GB=2          # kernel slab, pagetables, etc.
PG_MAX_DIRTY_GB=12               # reduce_writebacks.sh's vm.dirty_bytes
PG_SAFETY_MARGIN_GB=10           # other services, when they are not measured
PG_OTHER_SERVICES_HEADROOM_PERCENT=25
PG_OTHER_SERVICES_MIN_GB=4       # bursts on a host whose other services measure little
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

# pg_setting NAME ENV_FILE prints the setting NAME (an .env variable): from the environment, else
# from ENV_FILE (the .env next to the host scripts, as sudo does not pass the caller's environment
# through); empty when neither sets it.
pg_setting() {
  eval "_pgm_value=\${$1:-}"
  if [ -n "$_pgm_value" ]; then
    echo "$_pgm_value"
  elif [ -f "$2" ]; then
    _pgm_value=$(grep -E "^[[:space:]]*$1=" "$2" | tail -n 1 || true)
    _pgm_value=${_pgm_value#*=}
    _pgm_value=${_pgm_value%%#*}
    printf '%s\n' "$_pgm_value" | tr -d "\"' \t"
  fi
}

# pg_shared_buffers_override ENV_FILE prints the POSTGRESQL_SHARED_BUFFERS_GB the haf container
# gets (see pg_setting).
pg_shared_buffers_override() {
  pg_setting POSTGRESQL_SHARED_BUFFERS_GB "$1"
}

# pg_check_gb NAME VALUE MIN returns 0 when VALUE is a whole number of GB, at least MIN, and
# otherwise prints an error naming the setting NAME and returns 1.
pg_check_gb() {
  case $2 in
    '' | *[!0-9]* | 0?*) ;;
    *) [ "$2" -lt "$3" ] || return 0 ;;
  esac
  echo "Error: $1 must be a whole number of GB (at least $3), got '$2'" >&2
  return 1
}

# pg_shared_buffers_gb TOTAL_KB [OVERRIDE_GB] prints shared_buffers in GB, and on stderr how it was
# chosen.  A non-empty OVERRIDE_GB (POSTGRESQL_SHARED_BUFFERS_GB) wins; it must be a whole number of
# GB, at least 1, or the function prints an error and returns 1.
pg_shared_buffers_gb() {
  if [ -n "${2:-}" ]; then
    pg_check_gb POSTGRESQL_SHARED_BUFFERS_GB "$2" 1 || return 1
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

# pg_huge_page_size_kb ROOT prints the default huge page size (Hugepagesize in ROOT/proc/meminfo)
# in kB, the size vm.nr_hugepages counts and PostgreSQL's huge_page_size = 0 uses.
pg_huge_page_size_kb() {
  awk '/^Hugepagesize:/ { print $2 }' "${1%/}/proc/meminfo"
}

# pg_huge_pages_count SHARED_BUFFERS_GB HUGE_PAGE_KB prints the vm.nr_hugepages that hold the
# shared segment of those buffers.
pg_huge_pages_count() {
  echo $(($(pg_shared_segment_gb "$1") * _PGM_KB_PER_GB / $2))
}

# pg_other_services_gb MEASURED_KB prints the memory to leave for everything on the host but
# PostgreSQL's shared segment and the ZFS ARC, in GB, from the MEASURED_KB they were seen to use:
# that +25% headroom, rounded up, and at least PG_OTHER_SERVICES_MIN_GB for bursts.
pg_other_services_gb() {
  _pgm_other_gb=$((($1 * (100 + PG_OTHER_SERVICES_HEADROOM_PERCENT) + 100 * _PGM_KB_PER_GB - 1) / (100 * _PGM_KB_PER_GB)))
  if [ "$_pgm_other_gb" -lt "$PG_OTHER_SERVICES_MIN_GB" ]; then
    _pgm_other_gb=$PG_OTHER_SERVICES_MIN_GB
  fi
  echo "$_pgm_other_gb"
}

# pg_zfs_arc_max_gb TOTAL_KB SHARED_BUFFERS_GB [OTHER_SERVICES_GB] prints the ZFS ARC limit the
# formula gives, in GB.  OTHER_SERVICES_GB (pg_other_services_gb, or HAF_OTHER_SERVICES_GB) defaults
# to the fixed PG_SAFETY_MARGIN_GB.
pg_zfs_arc_max_gb() {
  _pgm_arc_gb=$(($1 / _PGM_KB_PER_GB - $(pg_shared_segment_gb "$2") - PG_KERNEL_OVERHEAD_GB - PG_MAX_DIRTY_GB - ${3:-$PG_SAFETY_MARGIN_GB}))
  if [ "$_pgm_arc_gb" -lt "$PG_ZFS_ARC_MIN_GB" ]; then
    _pgm_arc_gb=$PG_ZFS_ARC_MIN_GB
  fi
  echo "$_pgm_arc_gb"
}

# pg_zfs_arc_limit_gb TOTAL_KB SHARED_BUFFERS_GB OTHER_SERVICES_GB ARC_OVERRIDE_GB prints the ZFS
# ARC limit of the plan in GB, and on stderr how it was chosen: a non-empty ARC_OVERRIDE_GB
# (ZFS_ARC_MAX_GB, at least 1) wins, otherwise pg_zfs_arc_max_gb with OTHER_SERVICES_GB (empty: the
# fixed safety margin).  An override that is not a whole number of GB is an error (returns 1).
pg_zfs_arc_limit_gb() {
  if [ -n "$4" ]; then
    pg_check_gb ZFS_ARC_MAX_GB "$4" 1 || return 1
    echo "ZFS ARC limit = ${4}GB, from ZFS_ARC_MAX_GB" >&2
    echo "$4"
    return 0
  fi
  if [ -n "$3" ]; then
    pg_check_gb HAF_OTHER_SERVICES_GB "$3" 0 || return 1
    _pgm_other="${3}GB other services"
  else
    _pgm_other="${PG_SAFETY_MARGIN_GB}GB safety margin"
  fi
  _pgm_arc_gb=$(pg_zfs_arc_max_gb "$1" "$2" "$3")
  _pgm_terms="$(($1 / _PGM_KB_PER_GB))GB RAM - $(pg_shared_segment_gb "$2")GB shared segment - ${PG_KERNEL_OVERHEAD_GB}GB kernel - ${PG_MAX_DIRTY_GB}GB dirty pages - $_pgm_other"
  if [ "$_pgm_arc_gb" -eq "$PG_ZFS_ARC_MIN_GB" ]; then
    echo "ZFS ARC limit = ${_pgm_arc_gb}GB: the minimum, as $_pgm_terms is less" >&2
  else
    echo "ZFS ARC limit = ${_pgm_arc_gb}GB: $_pgm_terms" >&2
  fi
  echo "$_pgm_arc_gb"
}

# pg_effective_cache_size_gb TOTAL_KB SHARED_BUFFERS_GB [ARC_GB] prints effective_cache_size in GB:
# shared_buffers + the ARC limit ARC_GB (default pg_zfs_arc_max_gb's), at most RAM.
pg_effective_cache_size_gb() {
  _pgm_ecs_gb=$(($2 + ${3:-$(pg_zfs_arc_max_gb "$1" "$2")}))
  if [ "$_pgm_ecs_gb" -gt $(($1 / _PGM_KB_PER_GB)) ]; then
    _pgm_ecs_gb=$(($1 / _PGM_KB_PER_GB))
  fi
  echo "$_pgm_ecs_gb"
}

# pg_zfs_arc_default_bytes ROOT prints the ARC limit ZFS uses when zfs_arc_max is 0, in bytes:
# OpenZFS 2.3 and later take all of MemTotal but 1GB or 5/8 of it, whichever is more; earlier
# releases half of it.  The version comes from ROOT/sys/module/zfs/version; when it is unreadable
# the larger, newer default is assumed.
pg_zfs_arc_default_bytes() {
  _pgm_mem=$(($(awk '/^MemTotal:/ { print $2 }' "${1%/}/proc/meminfo") * 1024))
  _pgm_version=$(cat "${1%/}/sys/module/zfs/version" 2> /dev/null || true)
  case $_pgm_version in
    0.* | 1.* | 2.[012] | 2.[012][.-]*)
      echo $((_pgm_mem / 2))
      ;;
    *)
      _pgm_default=$((_pgm_mem - _PGM_KB_PER_GB * 1024))
      if [ $((_pgm_mem * 5 / 8)) -gt "$_pgm_default" ]; then
        _pgm_default=$((_pgm_mem * 5 / 8))
      fi
      echo "$_pgm_default"
      ;;
  esac
}

# pg_zfs_arc_bytes ROOT ZFS_ARC_MAX prints the ARC limit the zfs_arc_max ZFS_ARC_MAX gives, in
# bytes: ZFS_ARC_MAX itself, or pg_zfs_arc_default_bytes when it is 0 or empty.
pg_zfs_arc_bytes() {
  case ${2:-0} in
    0) pg_zfs_arc_default_bytes "$1" ;;
    *) echo "$2" ;;
  esac
}

# pg_zfs_arc_check ROOT TOTAL_KB SHARED_BUFFERS_GB ZFS_ARC_MAX [OTHER_SERVICES_GB [ARC_OVERRIDE_GB]]
# prints one line comparing the ARC limit ZFS_ARC_MAX (bytes; 0 is ZFS's default, see
# pg_zfs_arc_default_bytes) with the plan's limit (pg_zfs_arc_limit_gb) for those shared_buffers.
# It returns 0 when the limit is within it and 1 when it is larger: with ARC_OVERRIDE_GB, larger
# than that override; otherwise when the ARC, PostgreSQL's shared segment and the reserves can add
# up to more than RAM.  On a host where pg_zfs_arc_max_gb's 20GB minimum applies, a limit of that
# minimum passes.  An invalid override is an error (returns 2).
pg_zfs_arc_check() {
  if [ -n "${5:-}" ]; then pg_check_gb HAF_OTHER_SERVICES_GB "$5" 0 || return 2; fi
  if [ -n "${6:-}" ]; then pg_check_gb ZFS_ARC_MAX_GB "$6" 1 || return 2; fi
  _pgm_formula_gb=$(pg_zfs_arc_limit_gb "$2" "$3" "${5:-}" "${6:-}" 2> /dev/null)
  _pgm_formula=$((_pgm_formula_gb * _PGM_KB_PER_GB * 1024))
  if [ "$4" -eq 0 ]; then
    _pgm_arc=$(pg_zfs_arc_default_bytes "$1")
    _pgm_source="zfs_arc_max = 0, ZFS's default of $_pgm_arc bytes"
  else
    _pgm_arc=$4
    _pgm_source="zfs_arc_max = $4"
  fi
  _pgm_arc_gb=$(((_pgm_arc + _PGM_KB_PER_GB * 1024 - 1) / (_PGM_KB_PER_GB * 1024)))
  if [ -n "${6:-}" ]; then
    if [ "$_pgm_arc" -le "$_pgm_formula" ]; then
      echo "ZFS ARC limit ${_pgm_arc_gb}GB ($_pgm_source) is within ZFS_ARC_MAX_GB=${6} (zfs_arc_max = $_pgm_formula)"
      return 0
    fi
    echo "ZFS ARC limit ${_pgm_arc_gb}GB ($_pgm_source) is more than ZFS_ARC_MAX_GB=${6} (zfs_arc_max = $_pgm_formula)"
    return 1
  fi
  if [ "$_pgm_arc" -le "$_pgm_formula" ]; then
    echo "ZFS ARC limit ${_pgm_arc_gb}GB ($_pgm_source) is within the ${_pgm_formula_gb}GB (zfs_arc_max = $_pgm_formula) that RAM leaves beside shared_buffers ${3}GB"
    return 0
  fi
  _pgm_segment_gb=$(pg_shared_segment_gb "$3")
  if [ -n "${5:-}" ]; then
    _pgm_reserves_gb=$((PG_KERNEL_OVERHEAD_GB + PG_MAX_DIRTY_GB + $5))
    _pgm_reserves="${_pgm_reserves_gb}GB kernel, dirty-page and other-services"
  else
    _pgm_reserves_gb=$((PG_KERNEL_OVERHEAD_GB + PG_MAX_DIRTY_GB + PG_SAFETY_MARGIN_GB))
    _pgm_reserves="${_pgm_reserves_gb}GB kernel, dirty-page and safety"
  fi
  echo "ZFS ARC limit ${_pgm_arc_gb}GB ($_pgm_source) + PostgreSQL's ${_pgm_segment_gb}GB shared segment (shared_buffers ${3}GB) + $_pgm_reserves reserves = $((_pgm_arc_gb + _pgm_segment_gb + _pgm_reserves_gb))GB, more than the $(($2 / _PGM_KB_PER_GB))GB of RAM; the limit for this shared_buffers is ${_pgm_formula_gb}GB (zfs_arc_max = $_pgm_formula)"
  return 1
}

# pg_overcommit_check TOTAL_KB ARC_BYTES HUGE_PAGES HUGE_PAGE_KB [OTHER_SERVICES_GB] prints one line
# adding up the ZFS ARC limit ARC_BYTES, HUGE_PAGES reserved huge pages of HUGE_PAGE_KB, and the
# kernel, dirty-page and other-services reserves (OTHER_SERVICES_GB; empty: the fixed safety margin)
# against the RAM TOTAL_KB.  The huge pages hold PostgreSQL's shared segment, so pass at least the
# segment's count.  It returns 0 when they fit in RAM and 1 when they add up to more.
pg_overcommit_check() {
  if [ -n "${5:-}" ]; then
    _pgm_reserves_gb=$((PG_KERNEL_OVERHEAD_GB + PG_MAX_DIRTY_GB + $5))
    _pgm_reserves="kernel, dirty-page and other-services"
  else
    _pgm_reserves_gb=$((PG_KERNEL_OVERHEAD_GB + PG_MAX_DIRTY_GB + PG_SAFETY_MARGIN_GB))
    _pgm_reserves="kernel, dirty-page and safety"
  fi
  _pgm_huge=$(($3 * $4 * 1024))
  _pgm_sum=$(($2 + _pgm_huge + _pgm_reserves_gb * _PGM_KB_PER_GB * 1024))
  _pgm_ram=$(($1 * 1024))
  _pgm_terms=$(awk -v arc="$2" -v huge="$_pgm_huge" -v sum="$_pgm_sum" -v n="$3" -v kb="$4" \
    -v reserves="$_pgm_reserves_gb" -v what="$_pgm_reserves" 'BEGIN {
      g = 1073741824
      printf "ZFS ARC limit %.1fGB + %.1fGB of huge pages (%d x %dkB) + %dGB %s reserves = %.1fGB", arc / g, huge / g, n, kb, reserves, what, sum / g
    }')
  _pgm_ram_gb=$(awk -v ram="$_pgm_ram" 'BEGIN { printf "%.1f", ram / 1073741824 }')
  if [ "$_pgm_sum" -le "$_pgm_ram" ]; then
    echo "$_pgm_terms, within the ${_pgm_ram_gb}GB of RAM"
    return 0
  fi
  echo "$_pgm_terms, more than the ${_pgm_ram_gb}GB of RAM"
  return 1
}

_PGM_MODPROBE_ARC_RE='^[[:space:]]*options[[:space:]]+zfs[[:space:]]+(.*[[:space:]])?zfs_arc_max='

# pg_modprobe_zfs_arc_max DIR prints the zfs_arc_max the zfs module gets when it loads, from the
# "options zfs" lines of DIR/*.conf (/etc/modprobe.d; the last one modprobe reads wins), or nothing
# when none sets it (ZFS's default applies).
pg_modprobe_zfs_arc_max() {
  cat "${1%/}"/*.conf 2> /dev/null | grep -E "$_PGM_MODPROBE_ARC_RE" \
    | sed -E 's/.*[[:space:]]zfs_arc_max=([0-9]*).*/\1/' | tail -n 1 || true
}

# pg_modprobe_zfs_arc_max_file DIR prints the file of DIR/*.conf whose "options zfs" line sets the
# zfs_arc_max pg_modprobe_zfs_arc_max prints, or nothing when none sets it.
pg_modprobe_zfs_arc_max_file() {
  grep -lE "$_PGM_MODPROBE_ARC_RE" "${1%/}"/*.conf 2> /dev/null | tail -n 1 || true
}

# pg_modprobe_set_zfs_arc_max DIR BYTES NEW_FILE sets zfs_arc_max to BYTES in every "options zfs"
# line of DIR/*.conf that sets it, keeping the line's other options, and prints "FILE: OLD_VALUE"
# for each such line.  When no line sets it, it writes DIR/NEW_FILE with one and prints nothing.
pg_modprobe_set_zfs_arc_max() {
  _pgm_found=
  for _pgm_conf in "${1%/}"/*.conf; do
    grep -qE "$_PGM_MODPROBE_ARC_RE" "$_pgm_conf" 2> /dev/null || continue
    _pgm_found=1
    grep -E "$_PGM_MODPROBE_ARC_RE" "$_pgm_conf" | sed -E 's/.*[[:space:]]zfs_arc_max=([0-9]*).*/\1/' \
      | while read -r _pgm_old; do echo "$_pgm_conf: $_pgm_old"; done
    sed -i -E "s/(^[[:space:]]*options[[:space:]]+zfs[[:space:]]+(.*[[:space:]])?zfs_arc_max=)[0-9]*/\\1$2/" "$_pgm_conf"
  done
  if [ -z "$_pgm_found" ]; then
    printf '%s\noptions zfs zfs_arc_max=%s\n' \
      "# Written by haf_api_node's memory_plan.sh --apply --persist: the ZFS ARC limit beside PostgreSQL's shared_buffers" \
      "$2" > "${1%/}/$3"
  fi
}
