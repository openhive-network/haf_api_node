#!/usr/bin/env bash
#
# Test memory_plan.sh on a fixture host (MEMORY_PLAN_ROOT): hbt5's 125GB with shared_buffers 62GB
# and about 8GB of other services in cgroup v2 (haf project containers, a foreign container and
# processes outside containers, beside 60GB of page cache and shared memory that do not count).
# Checks the plan and its per-container breakdown, that the plan alone changes nothing, the
# HAF_OTHER_SERVICES_GB and ZFS_ARC_MAX_GB overrides, and --apply: a hand-set zfs_arc_max in
# modprobe.d is kept without --force, replaced with it, and the huge pages are left alone while
# haf runs.  docker and reserve_huge_pages.sh are stand-ins.  No root needed.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
GiB=1073741824

fail() {
  echo "FAIL: $*"
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# the scripts, with a reserve_huge_pages.sh that only logs how it was called
BIN="$WORK/haf_api_node"
mkdir -p "$BIN" "$WORK/stub"
cp "$REPO_DIR/memory_plan.sh" "$REPO_DIR/postgresql_memory.sh" "$BIN/"
cat > "$BIN/reserve_huge_pages.sh" << EOF
#!/bin/sh
echo "reserve_huge_pages.sh \$*" >> "$WORK/reserve.log"
EOF
cat > "$WORK/stub/docker" << EOF
#!/bin/sh
# docker ps -q --filter ...: the running haf container; docker ps --format: every container
case "\$*" in
  *-q*) cat "$WORK/haf-running" 2> /dev/null ;;
  *) cat "$WORK/containers" ;;
esac
EOF
chmod +x "$BIN/reserve_huge_pages.sh" "$WORK/stub/docker"
export PATH="$WORK/stub:$PATH"

ROOT="$WORK/root"
CG="$ROOT/sys/fs/cgroup"

# cgroup DIR USED FILE: a cgroup using USED bytes outside page cache and shared memory, and FILE in them
cgroup() {
  mkdir -p "$CG/$1"
  echo $(($2 + $3)) > "$CG/$1/memory.current"
  printf 'anon %s\nfile %s\nkernel 0\n' "$2" "$3" > "$CG/$1/memory.stat"
}

# reset: hbt5 with no override, nothing in modprobe.d, zfs_arc_max 0, no huge pages, haf stopped
reset() {
  rm -rf "$ROOT" "$WORK/reserve.log" "$WORK/haf-running" "$BIN/.env"
  mkdir -p "$ROOT/proc/sys/vm" "$ROOT/sys/module/zfs/parameters" "$ROOT/etc/modprobe.d" "$CG"
  printf 'MemTotal:       131822380 kB\nMemAvailable:   60000000 kB\nHugepagesize:       2048 kB\n' > "$ROOT/proc/meminfo"
  echo 0 > "$ROOT/proc/sys/vm/nr_hugepages"
  echo 0 > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
  echo 2.2.2-0ubuntu9 > "$ROOT/sys/module/zfs/version"
  echo "memory cpu" > "$CG/cgroup.controllers"
  # haf: 5GB of hived and PostgreSQL's backends beside a 60GB page cache and shared segment;
  # hivemind 1GB; the front-end haproxy (another project) 1GB; 0.5GB of system services and 0.5GB
  # of user processes: 8GB of other services, 1GB of them outside containers
  cgroup system.slice/docker-aaaa.scope $((5 * GiB)) $((60 * GiB))
  cgroup system.slice/docker-bbbb.scope $((GiB)) $((GiB / 2))
  cgroup system.slice/docker-cccc.scope $((GiB)) 0
  cgroup system.slice $((7 * GiB + GiB / 2)) $((60 * GiB + GiB / 2))
  cgroup user.slice $((GiB / 2)) $((2 * GiB))
  printf 'aaaa haf-world-haf-1 haf\nbbbb haf-world-hivemind-1 haf\ncccc haproxy-front-1 front\n' > "$WORK/containers"
  printf 'PROJECT_NAME=haf\n' > "$BIN/.env"
}

# plan NAME ARGS...: run memory_plan.sh, output in $WORK/out; fails the test when it fails
plan() {
  local name=$1
  shift
  MEMORY_PLAN_ROOT="$ROOT" POSTGRESQL_SHARED_BUFFERS_GB='' HAF_OTHER_SERVICES_GB='' ZFS_ARC_MAX_GB='' PROJECT_NAME='' \
    "$BIN/memory_plan.sh" --sample-seconds 0 "$@" > "$WORK/out" 2>&1 || fail "$name: exited $? ($(cat "$WORK/out"))"
}

# expect NAME PATTERN: the last run's output has a line matching PATTERN (grep -E)
expect() {
  grep -qE -- "$2" "$WORK/out" || fail "$1: no line matching '$2' in:"$'\n'"$(cat "$WORK/out")"
}

state() {
  cat "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
  cat "$ROOT"/etc/modprobe.d/*.conf 2> /dev/null || true
  cat "$WORK/reserve.log" 2> /dev/null || true
}

reset
printf 'options zfs zfs_arc_max=%s\n' $((42 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
before=$(state)
plan "plan"
expect "plan" "^  RAM +125GB +measurement"
expect "plan" "^  shared_buffers +62GB +formula: 50% of 125GB RAM$"
expect "plan" "^  shared segment +66GB +formula"
expect "plan" "^  other services +10GB +measurement: 8\.0GB peak over 0s \+ 25%, at least 4GB$"
expect "plan" "^  ZFS ARC limit +35GB +formula: 125GB RAM - 66GB shared segment - 2GB kernel - 12GB dirty pages - 10GB other services$"
expect "plan" "^  huge pages +33792 +formula"
expect "plan" "^  effective_cache_size +97GB +formula"
expect "plan" "^  \* haf-world-haf-1 +5\.0GB$"
expect "plan" "^  \* haf-world-hivemind-1 +1\.0GB$"
expect "plan" "^    haproxy-front-1 +1\.0GB$"
expect "plan" "^    \(processes outside containers\) +1\.0GB$"
expect "plan" "^    total +8\.0GB$"
expect "plan" "^  zfs_arc_max \(at boot\)  45097156608 \(42\.0GB\)"
# the haf container's start-up check, against the plan: ZFS 2.2's default is half of RAM
expect "plan" "^  ZFS ARC limit 63GB \(zfs_arc_max = 0, ZFS's default .* 24GB kernel, dirty-page and other-services reserves = 153GB, .* is 35GB"
expect "plan" "--apply keeps the boot-time 45097156608, taken as set by hand"
expect "plan" "^Nothing was changed"
[ "$(state)" = "$before" ] || fail "plan: changed the host"
echo "ok: plan with the per-service breakdown, nothing changed"

# HAF_OTHER_SERVICES_GB replaces the measurement; ZFS_ARC_MAX_GB the result
reset
echo HAF_OTHER_SERVICES_GB=20 >> "$BIN/.env"
plan "HAF_OTHER_SERVICES_GB"
expect "HAF_OTHER_SERVICES_GB" "^  other services +20GB +override: HAF_OTHER_SERVICES_GB \(measured 8\.0GB, not used\)$"
expect "HAF_OTHER_SERVICES_GB" "^  ZFS ARC limit +25GB +formula: .* - 20GB other services$"
echo ZFS_ARC_MAX_GB=42 >> "$BIN/.env"
plan "ZFS_ARC_MAX_GB"
expect "ZFS_ARC_MAX_GB" "^  ZFS ARC limit +42GB +override: ZFS_ARC_MAX_GB \(the formula gives 25GB\)$"
expect "ZFS_ARC_MAX_GB" "^  effective_cache_size +104GB"
echo "ok: HAF_OTHER_SERVICES_GB and ZFS_ARC_MAX_GB overrides"

# no cgroup v2 hierarchy: the fixed safety margin
reset
rm "$CG/cgroup.controllers"
plan "unmeasured"
expect "unmeasured" "^  other services +10GB +not measured \(no cgroup v2 hierarchy"
expect "unmeasured" "10GB safety margin$"
echo "ok: no cgroup v2: the fixed safety margin"

# hbt5's hand-set 42GB in modprobe.d is kept, with the runtime limit, without --force
reset
printf '# set by hand after swapping\noptions zfs zfs_arc_max=%s\n' $((42 * GiB)) > "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf"
echo $((42 * GiB)) > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
plan "--apply --persist, hand-set" --apply --persist
expect "--apply --persist, hand-set" "Kept zfs_arc_max=45097156608 \(42\.0GB\) in .*modprobe.d, which differs from the plan's 37580963840 \(35\.0GB\): taken as set by hand"
grep -q "^options zfs zfs_arc_max=45097156608$" "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf" || fail "hand-set: modprobe.d changed"
grep -q "^# set by hand after swapping$" "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf" || fail "hand-set: modprobe.d comment lost"
[ "$(cat "$ROOT/sys/module/zfs/parameters/zfs_arc_max")" = 45097156608 ] || fail "hand-set: runtime zfs_arc_max changed"
[ "$(cat "$WORK/reserve.log")" = "reserve_huge_pages.sh --persist" ] || fail "hand-set: huge pages not reserved"
echo "ok: --apply --persist keeps a hand-set zfs_arc_max"

# ZFS_ARC_MAX_GB matching it: the plan is the hand-set value, nothing to replace
echo ZFS_ARC_MAX_GB=42 >> "$BIN/.env"
plan "--apply --persist, ZFS_ARC_MAX_GB=42" --apply --persist
expect "--apply --persist, ZFS_ARC_MAX_GB=42" "zfs_arc_max is already 45097156608"
expect "--apply --persist, ZFS_ARC_MAX_GB=42" "At boot: zfs_arc_max=45097156608 in .* already"
echo "ok: ZFS_ARC_MAX_GB matching the hand-set value"

# --force replaces it, now and at boot
reset
printf 'options zfs zfs_prefetch_disable=1 zfs_arc_max=%s\n' $((42 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
plan "--apply --persist --force" --apply --persist --force
expect "--apply --persist --force" "zfs_arc_max: changed from 0 to 37580963840"
expect "--apply --persist --force" "zfs.conf: zfs_arc_max changed from 45097156608 to 37580963840"
[ "$(cat "$ROOT/etc/modprobe.d/zfs.conf")" = "options zfs zfs_prefetch_disable=1 zfs_arc_max=37580963840" ] || fail "--force: modprobe.d has '$(cat "$ROOT/etc/modprobe.d/zfs.conf")'"
[ "$(cat "$ROOT/sys/module/zfs/parameters/zfs_arc_max")" = 37580963840 ] || fail "--force: runtime zfs_arc_max not set"
echo "ok: --force replaces a hand-set zfs_arc_max"

# nothing in modprobe.d: --persist writes it; without --persist only the runtime limit is set
reset
plan "--apply" --apply
[ "$(cat "$ROOT/sys/module/zfs/parameters/zfs_arc_max")" = 37580963840 ] || fail "--apply: runtime zfs_arc_max not set"
[ -z "$(ls "$ROOT/etc/modprobe.d")" ] || fail "--apply without --persist wrote modprobe.d"
expect "--apply" "At boot: ZFS's default of .*more than 37580963840"
[ "$(cat "$WORK/reserve.log")" = "reserve_huge_pages.sh " ] || fail "--apply: reserve_huge_pages.sh called as '$(cat "$WORK/reserve.log")'"
plan "--apply --persist, new file" --apply --persist
grep -q "^options zfs zfs_arc_max=37580963840$" "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf" || fail "--persist: no haf-zfs-arc-max.conf"
echo "ok: --apply, and --persist writing a new modprobe.d file"

# while haf runs, a changed huge page reservation is left alone; --arc-only never touches it
reset
echo aaaa > "$WORK/haf-running"
plan "--apply, haf running" --apply --persist
expect "--apply, haf running" "vm.nr_hugepages is 0, the plan 33792, but haf is running: not changed"
[ ! -e "$WORK/reserve.log" ] || fail "haf running: reserve_huge_pages.sh called"
rm "$WORK/haf-running"
plan "--apply --arc-only" --apply --arc-only
[ ! -e "$WORK/reserve.log" ] || fail "--arc-only: reserve_huge_pages.sh called"
echo "ok: huge pages left alone while haf runs and with --arc-only"

for args in "--persist" "--force" "--arc-only" "--sample-seconds x" "--bogus"; do
  # shellcheck disable=SC2086 # split the arguments
  if MEMORY_PLAN_ROOT="$ROOT" "$BIN/memory_plan.sh" $args > /dev/null 2>&1; then
    fail "'$args' accepted"
  fi
done
echo "ok: bad arguments refused"

echo "All memory_plan.sh tests passed"
