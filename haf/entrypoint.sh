#!/bin/bash
# Entrypoint of the haf container (haf_base.yaml): sizes PostgreSQL's shared_buffers and
# effective_cache_size from the RAM the container may use (postgresql_memory.sh), writes them to
# haf_postgresql_conf.d/zz-memory.conf, then runs the HAF image's own entrypoint.
#
# The file is rewritten at every start, so it follows the host's RAM and POSTGRESQL_SHARED_BUFFERS_GB.
# PostgreSQL reads haf_postgresql_conf.d in file-name order and the last setting wins: "zz-memory.conf"
# sorts after pgtune.conf, zfs.conf and custom_postgres.conf, so it replaces the 16GB that older
# pgtune.conf copies in existing datadirs still carry.
#
# PostgreSQL keeps huge_pages = try.  Once it accepts connections, a background job logs
# huge_pages_status and how the huge pages the host reserved (reserve_huge_pages.sh) compare with the
# shared memory PostgreSQL needed.
#
# effective_cache_size assumes the ZFS ARC limit postgresql_memory.sh computes, which the host has
# to apply (memory_plan.sh --apply).  The container cannot measure the host's other services, so it
# plans with ZFS_ARC_MAX_GB or HAF_OTHER_SERVICES_GB from .env when set, and otherwise with the
# fixed safety margin.  The entrypoint logs a warning, without failing the start, when the runtime
# zfs_arc_max is larger than the plan; without an override, larger than any plan memory_plan.sh
# makes (other services at their minimum), so a limit it applied is not warned about.  The
# boot-time value in the host's /etc/modprobe.d is not visible here, memory_plan.sh compares that one.

set -euo pipefail

# shellcheck source=../postgresql_memory.sh
. /home/hived/haf_api_node/postgresql_memory.sh

CONF_DIR=/home/hived/datadir/haf_postgresql_conf.d
CONF_FILE="$CONF_DIR/zz-memory.conf"

total_kb=$(pg_memory_total_kb /)
shared_buffers_gb=$(pg_shared_buffers_gb "$total_kb" "${POSTGRESQL_SHARED_BUFFERS_GB:-}")
arc_max_gb=$(pg_zfs_arc_limit_gb "$total_kb" "$shared_buffers_gb" "${HAF_OTHER_SERVICES_GB:-}" "${ZFS_ARC_MAX_GB:-}")
effective_cache_size_gb=$(pg_effective_cache_size_gb "$total_kb" "$shared_buffers_gb" "$arc_max_gb")
echo "effective_cache_size = ${effective_cache_size_gb}GB: shared_buffers + the ZFS ARC limit memory_plan.sh sets"

if ! sudo -n test -d "$CONF_DIR"; then
  sudo -n mkdir -p "$CONF_DIR"
  sudo -n chown postgres:postgres "$CONF_DIR"
fi
sudo -n tee "$CONF_FILE" > /dev/null <<EOF
# Written by haf_api_node's haf/entrypoint.sh at every haf container start; edits are overwritten.
# Set POSTGRESQL_SHARED_BUFFERS_GB in .env to choose shared_buffers yourself.
shared_buffers = ${shared_buffers_gb}GB
effective_cache_size = ${effective_cache_size_gb}GB
EOF
sudo -n chown postgres:postgres "$CONF_FILE"
echo "Wrote $CONF_FILE"

if [ -r /sys/module/zfs/parameters/zfs_arc_max ]; then
  if arc_report=$(pg_zfs_arc_check / "$total_kb" "$shared_buffers_gb" "$(cat /sys/module/zfs/parameters/zfs_arc_max)" "${HAF_OTHER_SERVICES_GB:-$PG_OTHER_SERVICES_MIN_GB}" "${ZFS_ARC_MAX_GB:-}"); then
    echo "$arc_report"
  else
    echo "WARNING: $arc_report. To see the host's plan, run on the host in the haf_api_node directory: sudo ./memory_plan.sh; to apply it now and at every boot: sudo ./memory_plan.sh --apply --persist; to keep a limit set by hand, set ZFS_ARC_MAX_GB in .env"
  fi
fi

# report_huge_pages EXPECTED_HUGE_PAGES HUGE_PAGE_KB waits until PostgreSQL accepts connections,
# then logs whether its shared memory is on huge pages
report_huge_pages() {
  local result status needed total free rsvd
  until result=$(sudo -n -u postgres psql -XAtc "SELECT current_setting('huge_pages_status'), current_setting('shared_memory_size_in_huge_pages')" 2> /dev/null); do
    sleep 10
  done
  IFS='|' read -r status needed <<< "$result"
  total=$(awk '/^HugePages_Total:/ { print $2 }' /proc/meminfo)
  free=$(awk '/^HugePages_Free:/ { print $2 }' /proc/meminfo)
  rsvd=$(awk '/^HugePages_Rsvd:/ { print $2 }' /proc/meminfo)
  echo "huge_pages_status = $status: PostgreSQL's shared memory needs $needed huge pages of ${2}kB; the host has HugePages_Total $total, HugePages_Free $free, HugePages_Rsvd $rsvd; reserve_huge_pages.sh reserves $1"
  if [ "$status" != on ] && [ "$total" -gt 0 ]; then
    echo "WARNING: PostgreSQL uses 4kB pages while $total huge pages are reserved and unused: reserve at least $needed (reserve_huge_pages.sh) or release them"
  elif [ "$needed" -gt "$1" ]; then
    echo "WARNING: reserve_huge_pages.sh's $1 huge pages are fewer than the $needed PostgreSQL needs"
  fi
}

huge_page_kb=$(pg_huge_page_size_kb /)
report_huge_pages "$(pg_huge_pages_count "$shared_buffers_gb" "$huge_page_kb")" "$huge_page_kb" &

exec /home/hived/docker_entrypoint.sh "$@"
