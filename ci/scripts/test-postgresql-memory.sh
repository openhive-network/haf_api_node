#!/usr/bin/env bash
#
# Test the PostgreSQL memory sizing the haf container and reduce_writebacks.sh share
# (postgresql_memory.sh) on fixture /proc/meminfo and cgroup files: hosts of 2GB, 64GB, 121GB and
# 256GB, the POSTGRESQL_SHARED_BUFFERS_GB override (and how it is read from .env), a memory-limited
# container, the huge page reservation for the shared segment, the ZFS ARC limit check the haf
# entrypoint warns with, and reading and replacing zfs_arc_max in modprobe.d.  No root needed.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../postgresql_memory.sh
. "$REPO_DIR/postgresql_memory.sh"

fail() {
  echo "FAIL: $*"
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# host NAME MEMTOTAL_KB [CGROUP_FILE CGROUP_VALUE]: a fixture root with that MemTotal and,
# optionally, a cgroup memory limit file (relative to sys/fs/cgroup); prints its path
host() {
  local root="$WORK/$1"
  mkdir -p "$root/proc" "$root/sys/fs/cgroup/memory"
  printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\nHugepagesize:       2048 kB\n' "$2" > "$root/proc/meminfo"
  if [ $# -gt 2 ]; then
    echo "$4" > "$root/sys/fs/cgroup/$3"
  fi
  echo "$root"
}

# expect NAME ROOT OVERRIDE SHARED_BUFFERS ARC_MAX EFFECTIVE_CACHE_SIZE LOG_PATTERN
expect() {
  local total_kb sb arc ecs log
  total_kb=$(pg_memory_total_kb "$2")
  sb=$(pg_shared_buffers_gb "$total_kb" "$3" 2> "$WORK/log")
  log=$(cat "$WORK/log")
  arc=$(pg_zfs_arc_max_gb "$total_kb" "$sb")
  ecs=$(pg_effective_cache_size_gb "$total_kb" "$sb")
  [ "$sb" = "$4" ] || fail "$1: shared_buffers ${sb}GB, expected ${4}GB"
  [ "$arc" = "$5" ] || fail "$1: zfs_arc_max ${arc}GB, expected ${5}GB"
  [ "$ecs" = "$6" ] || fail "$1: effective_cache_size ${ecs}GB, expected ${6}GB"
  [[ "$log" =~ $7 ]] || fail "$1: logged '$log', expected a match for '$7'"
  echo "ok: $1: shared_buffers ${sb}GB, zfs_arc_max ${arc}GB, effective_cache_size ${ecs}GB ($log)"
}

# steem-20's MemTotal (121GB): 50% is 60.6GB; the segment takes 60 + 3, the ARC the rest of 121 - 24
expect "121GB host" "$(host h121 127065876)" "" 60 34 94 "^shared_buffers = 60GB: 50% of 121GB RAM$"
# 125.7GB: 50% is 62.9GB; the segment takes 62 + 4
expect "125GB host" "$(host h125 131822380)" "" 62 35 97 "^shared_buffers = 62GB: 50% of 125GB RAM$"
# 50% of 251GB is 125GB, over the cap
expect "256GB host" "$(host h256 263842412)" "" 64 159 223 "capped at 64GB"
# 62GB RAM: 31GB; the ARC formula comes out at 5GB, below its 20GB minimum
expect "64GB host" "$(host h64 65777000)" "" 31 20 51 "^shared_buffers = 31GB: 50% of 62GB RAM$"
# 50% of 1.9GB is under 1GB: the floor, and effective_cache_size no more than RAM
expect "2GB host" "$(host h2 2000000)" "" 1 20 1 "below the 1GB floor"
expect "121GB host, override" "$(host h121o 127065876)" 32 32 63 95 "from POSTGRESQL_SHARED_BUFFERS_GB"

# a memory-limited container sizes from its limit; an unlimited one ("max" in cgroup v2, a huge
# number in v1) from MemTotal
expect "cgroup v2 limit 32GB" "$(host v2limit 127065876 memory.max 34359738368)" "" 16 20 32 "50% of 32GB RAM"
expect "cgroup v2 unlimited" "$(host v2max 127065876 memory.max max)" "" 60 34 94 "50% of 121GB RAM"
expect "cgroup v1 unlimited" "$(host v1max 127065876 memory/memory.limit_in_bytes 9223372036854771712)" "" 60 34 94 "50% of 121GB RAM"

for bad in 16GB 0 -4 4.5; do
  if pg_shared_buffers_gb 127065876 "$bad" > /dev/null 2> "$WORK/log"; then
    fail "override '$bad' accepted"
  fi
  grep -q "must be a whole number of GB" "$WORK/log" || fail "override '$bad': no error logged"
  echo "ok: override '$bad' refused"
done

# huge pages hold the shared segment the ARC formula reserves: 48GB + 5% rounded up = 51GB.
# steem-20's PostgreSQL reported shared_memory_size_in_huge_pages = 25217 for 48GB of buffers, so
# 26112 covers it.
expect_huge_pages() {
  local count
  count=$(pg_huge_pages_count "$2" "$3")
  [ "$count" = "$4" ] || fail "$1: $count huge pages, expected $4"
  echo "ok: $1: $count huge pages"
}
huge_page_kb=$(pg_huge_page_size_kb "$WORK/h121")
[ "$huge_page_kb" = 2048 ] || fail "Hugepagesize read as '$huge_page_kb', expected 2048"
expect_huge_pages "48GB, 2MB pages" 48 "$huge_page_kb" 26112
expect_huge_pages "48GB, 1GB pages" 48 1048576 51
expect_huge_pages "60GB (121GB host), 2MB pages" 60 2048 32256
expect_huge_pages "1GB floor, 2MB pages" 1 2048 1024
expect_huge_pages "64GB cap, 2MB pages" 64 2048 34816

# expect_override NAME ENV_VALUE ENV_FILE_LINE EXPECTED
expect_override() {
  local value
  printf 'PROJECT_NAME=haf\n%s\n' "$3" > "$WORK/.env"
  value=$(POSTGRESQL_SHARED_BUFFERS_GB="$2" pg_shared_buffers_override "$WORK/.env")
  [ "$value" = "$4" ] || fail "$1: override read as '$value', expected '$4'"
  echo "ok: $1: override '$value'"
}
expect_override ".env plain" "" "POSTGRESQL_SHARED_BUFFERS_GB=32" 32
expect_override ".env quoted, commented" "" "  POSTGRESQL_SHARED_BUFFERS_GB=\"40\"  # tuned" 40
expect_override ".env commented out" "" "# POSTGRESQL_SHARED_BUFFERS_GB=48" ""
expect_override "environment wins" 24 "POSTGRESQL_SHARED_BUFFERS_GB=32" 24
[ -z "$(POSTGRESQL_SHARED_BUFFERS_GB='' pg_shared_buffers_override "$WORK/missing.env")" ] || fail "missing .env: override not empty"
echo "ok: missing .env: no override"

# zfs ROOT VERSION: give a fixture root a loaded zfs module of that version
zfs() {
  mkdir -p "$1/sys/module/zfs/parameters"
  echo "$2" > "$1/sys/module/zfs/version"
}
GiB=1073741824

# ZFS's limit for zfs_arc_max = 0 on steem-20's 127065876kB: half of it before 2.3, all but 1GB after
zfs "$WORK/h121" 2.2.2-0ubuntu9
[ "$(pg_zfs_arc_default_bytes "$WORK/h121")" = 65057728512 ] || fail "ZFS 2.2 default: $(pg_zfs_arc_default_bytes "$WORK/h121")"
zfs "$WORK/h121" 2.4.4-1
[ "$(pg_zfs_arc_default_bytes "$WORK/h121")" = 129041715200 ] || fail "ZFS 2.4 default: $(pg_zfs_arc_default_bytes "$WORK/h121")"
rm "$WORK/h121/sys/module/zfs/version"
[ "$(pg_zfs_arc_default_bytes "$WORK/h121")" = 129041715200 ] || fail "unknown ZFS version: not the newer default"
# 5/8 of RAM is more than all but 1GB below 2.67GB
zfs "$WORK/h2" 2.3.0
[ "$(pg_zfs_arc_default_bytes "$WORK/h2")" = 1280000000 ] || fail "ZFS 2.3 default, 2GB host: $(pg_zfs_arc_default_bytes "$WORK/h2")"
echo "ok: ZFS's default ARC limit"

# expect_arc NAME ROOT SHARED_BUFFERS ZFS_ARC_MAX STATUS LOG_PATTERN
expect_arc() {
  local total_kb log rc=0
  total_kb=$(pg_memory_total_kb "$2")
  log=$(pg_zfs_arc_check "$2" "$total_kb" "$3" "$4") || rc=$?
  [ "$rc" = "$5" ] || fail "$1: returned $rc, expected $5 ($log)"
  [[ "$log" =~ $6 ]] || fail "$1: logged '$log', expected a match for '$6'"
  echo "ok: $1: $log"
}
zfs "$WORK/h121" 2.4.4-1
# steem-20 after a reboot: modprobe.d's 83GB beside 60GB of buffers (63GB segment) and 24GB of reserves
expect_arc "121GB host, boot-time 83GB" "$WORK/h121" 60 89120571392 1 \
  "^ZFS ARC limit 83GB \\(zfs_arc_max = 89120571392\\) \\+ PostgreSQL's 63GB shared segment \\(shared_buffers 60GB\\) \\+ 24GB kernel, dirty-page and safety reserves = 170GB, more than the 121GB of RAM; the limit for this shared_buffers is 34GB \\(zfs_arc_max = 36507222016\\)$"
# the 32GB set by hand on steem-20, and exactly the formula's 34GB
expect_arc "121GB host, runtime 32GB" "$WORK/h121" 60 $((32 * GiB)) 0 "^ZFS ARC limit 32GB \\(zfs_arc_max = 34359738368\\) is within the 34GB"
expect_arc "121GB host, formula's limit" "$WORK/h121" 60 36507222016 0 "is within the 34GB \\(zfs_arc_max = 36507222016\\)"
expect_arc "121GB host, one byte over" "$WORK/h121" 60 36507222017 1 "^ZFS ARC limit 35GB .* 122GB, more than"
expect_arc "121GB host, override 32GB" "$WORK/h121" 32 $((60 * GiB)) 0 "within the 63GB"
expect_arc "121GB host, ZFS default" "$WORK/h121" 60 0 1 "^ZFS ARC limit 121GB \\(zfs_arc_max = 0, ZFS's default of 129041715200 bytes\\)"
# below about 93GB of RAM the formula's 20GB minimum passes, though it does not fit
zfs "$WORK/h64" 2.4.4-1
expect_arc "64GB host, 20GB minimum" "$WORK/h64" 31 $((20 * GiB)) 0 "within the 20GB"
expect_arc "64GB host, 21GB" "$WORK/h64" 31 $((21 * GiB)) 1 "more than the 62GB of RAM"

# modprobe.d: the last "options zfs" line setting zfs_arc_max wins; comments and other modules don't count
MODPROBE="$WORK/modprobe.d"
mkdir -p "$MODPROBE"
[ -z "$(pg_modprobe_zfs_arc_max "$MODPROBE")" ] || fail "empty modprobe.d: a zfs_arc_max read"
printf '# options zfs zfs_arc_max=1\noptions spl spl_kmem_cache_slab_limit=0 zfs_arc_max=2\n' > "$MODPROBE/a.conf"
printf 'options zfs zfs_prefetch_disable=1 zfs_arc_max=89120571392 zfs_arc_min=4294967296\n' > "$MODPROBE/zfs.conf"
printf 'options zfs zfs_arc_max=12\n' > "$MODPROBE/zfs.conf.dpkg-old"
[ "$(pg_modprobe_zfs_arc_max "$MODPROBE")" = 89120571392 ] || fail "modprobe.d: read '$(pg_modprobe_zfs_arc_max "$MODPROBE")'"
printf 'options\tzfs\tzfs_arc_max=34359738368\n' > "$MODPROBE/zz.conf"
[ "$(pg_modprobe_zfs_arc_max "$MODPROBE")" = 34359738368 ] || fail "modprobe.d: later file not read last"
rm "$MODPROBE/zz.conf"
echo "ok: modprobe.d zfs_arc_max read"

changed=$(pg_modprobe_set_zfs_arc_max "$MODPROBE" 36507222016 haf-zfs-arc-max.conf)
[ "$changed" = "$MODPROBE/zfs.conf: 89120571392" ] || fail "modprobe.d replace reported '$changed'"
[ "$(cat "$MODPROBE/zfs.conf")" = "options zfs zfs_prefetch_disable=1 zfs_arc_max=36507222016 zfs_arc_min=4294967296" ] \
  || fail "modprobe.d replace left '$(cat "$MODPROBE/zfs.conf")'"
grep -q '^# options zfs zfs_arc_max=1$' "$MODPROBE/a.conf" || fail "modprobe.d replace changed a comment"
grep -q 'zfs_arc_max=12$' "$MODPROBE/zfs.conf.dpkg-old" || fail "modprobe.d replace changed a file modprobe ignores"
[ ! -e "$MODPROBE/haf-zfs-arc-max.conf" ] || fail "modprobe.d replace also wrote a new file"
[ "$(pg_modprobe_zfs_arc_max "$MODPROBE")" = 36507222016 ] || fail "modprobe.d: replaced value not read back"
echo "ok: modprobe.d zfs_arc_max replaced ($changed)"

rm "$MODPROBE/zfs.conf"
changed=$(pg_modprobe_set_zfs_arc_max "$MODPROBE" 36507222016 haf-zfs-arc-max.conf)
[ -z "$changed" ] || fail "modprobe.d without zfs_arc_max: reported '$changed'"
grep -q '^options zfs zfs_arc_max=36507222016$' "$MODPROBE/haf-zfs-arc-max.conf" || fail "modprobe.d: no file written"
[ "$(pg_modprobe_zfs_arc_max "$MODPROBE")" = 36507222016 ] || fail "modprobe.d: written value not read back"
echo "ok: modprobe.d zfs_arc_max written to a new file"

echo "All PostgreSQL memory sizing tests passed"
