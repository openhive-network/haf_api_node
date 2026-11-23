#!/usr/bin/env bash
#
# Test memory_plan.sh on a fixture host (MEMORY_PLAN_ROOT): hbt5's 125GB with shared_buffers 62GB
# and about 8GB of other services in cgroup v2 (haf project containers, a foreign container and
# processes outside containers, beside 60GB of page cache and shared memory that do not count, and
# with hugetlb accounting the huge pages of the shared segment).
# Checks the plan and its per-container breakdown, that the plan alone changes nothing, the
# HAF_OTHER_SERVICES_GB and ZFS_ARC_MAX_GB overrides, and --apply: a hand-set zfs_arc_max in
# modprobe.d is kept without --force, replaced with it, and the huge pages are left alone while
# haf runs.  On steem-20's 121GB, a stale 83GB zfs_arc_max beside 63GB of huge pages overcommits
# RAM: --apply refuses to keep it (also by way of reduce_writebacks.sh --zfs-only), and
# reserve_huge_pages.sh warns.  A hand-set 32GB there, 0.9GB over only with a transient peak in the
# measured other services, is kept with a warning; with HAF_OTHER_SERVICES_GB covering that peak it
# is refused.  With zfs in the initramfs, its copy of modprobe.d is the boot-time one: steem-20's
# stale 83GB there, beside a hand-edited 32GB in /etc, is reported (by reserve_huge_pages.sh too),
# refused and rebuilt with --force, and --persist rebuilds an initramfs that alone is stale.
# docker, reserve_huge_pages.sh, unmkinitramfs and update-initramfs are stand-ins (the initramfs is
# an uncompressed newc cpio written here, so no initramfs-tools or cpio is needed).  No root needed.

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
# mkinitrd SRC OUT: an uncompressed newc cpio of the tree SRC, as an initramfs is
cat > "$WORK/mkinitrd" << 'EOF'
#!/bin/bash
set -e
out=$2
: > "$out"
pad() {
  while [ $(($(stat -c %s "$out") % 4)) -ne 0 ]; do printf '\0' >> "$out"; done
}
# entry NAME MODE SIZE [FILE]
entry() {
  printf '070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%s\0' 0 "$2" 0 0 1 0 "$3" 0 0 0 0 $((${#1} + 1)) 0 "$1" >> "$out"
  pad
  if [ -n "${4:-}" ]; then cat "$4" >> "$out"; pad; fi
}
cd "$1"
find . -mindepth 1 | sed 's|^\./||' | sort | while read -r path; do
  if [ -d "$path" ]; then
    entry "$path" $((8#40755)) 0
  else
    entry "$path" $((8#100644)) "$(stat -c %s "$path")" "$path"
  fi
done
entry 'TRAILER!!!' 0 0
EOF
# unmkinitramfs INITRD DIR, for the cpio mkinitrd writes
cat > "$WORK/stub/unmkinitramfs" << 'EOF'
#!/bin/bash
set -e
in=$1 off=0
mkdir -p "$2"
field() { echo $((16#${hdr:$1:8})); }
while :; do
  hdr=$(tail -c +$((off + 1)) "$in" | head -c 110)
  [ "${hdr:0:6}" = 070701 ] || { echo "unmkinitramfs: no newc header at $off" >&2; exit 1; }
  mode=$(field 14) size=$(field 54) namesize=$(field 94)
  name=$(tail -c +$((off + 111)) "$in" | head -c $((namesize - 1)))
  off=$(((off + 110 + namesize + 3) / 4 * 4))
  [ "$name" != 'TRAILER!!!' ] || break
  if [ $((mode & 8#170000)) -eq $((8#40000)) ]; then
    mkdir -p "$2/$name"
  else
    mkdir -p "$(dirname "$2/$name")"
    tail -c +$((off + 1)) "$in" | head -c "$size" > "$2/$name"
    off=$(((off + size + 3) / 4 * 4))
  fi
done
EOF
# update-initramfs -u: the initramfs again, with the zfs module and the fixture's modprobe.d
cat > "$WORK/stub/update-initramfs" << EOF
#!/bin/bash
set -e
echo "update-initramfs \$*" >> "$WORK/update-initramfs.log"
rm -rf "$WORK/initrd-tree"
mkdir -p "$WORK/initrd-tree/usr/lib/modules/updates/dkms" "$WORK/initrd-tree/etc"
echo zfs > "$WORK/initrd-tree/usr/lib/modules/updates/dkms/zfs.ko.zst"
cp -r "$WORK/root/etc/modprobe.d" "$WORK/initrd-tree/etc/"
"$WORK/mkinitrd" "$WORK/initrd-tree" "$WORK/root/boot/initrd.img-\$(uname -r)"
EOF
chmod +x "$BIN/reserve_huge_pages.sh" "$WORK/stub/docker" "$WORK/mkinitrd" "$WORK/stub/unmkinitramfs" "$WORK/stub/update-initramfs"
export PATH="$WORK/stub:$PATH"

ROOT="$WORK/root"
CG="$ROOT/sys/fs/cgroup"

# cgroup DIR USED FILE [HUGETLB]: a cgroup using USED bytes outside page cache and shared memory,
# FILE in them and, with hugetlb accounting (memory.stat's hugetlb), HUGETLB in huge pages
cgroup() {
  mkdir -p "$CG/$1"
  echo $(($2 + $3 + ${4:-0})) > "$CG/$1/memory.current"
  printf 'anon %s\nfile %s\nkernel 0\n' "$2" "$3" > "$CG/$1/memory.stat"
  if [ -n "${4:-}" ]; then
    echo "hugetlb $4" >> "$CG/$1/memory.stat"
  fi
}

# reset: hbt5 with no override, nothing in modprobe.d, zfs_arc_max 0, no huge pages, haf stopped
reset() {
  rm -rf "$ROOT" "$WORK/reserve.log" "$WORK/haf-running" "$BIN/.env" "$WORK/update-initramfs.log"
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
  cksum "$INITRD" 2> /dev/null || true
}

INITRD="$ROOT/boot/initrd.img-$(uname -r)"
# initrd ARC_MAX [zfs]: the fixture's initramfs, with zfs_arc_max=ARC_MAX in its modprobe.d and,
# with zfs, the zfs module
initrd() {
  local tree="$WORK/initrd-tree"
  rm -rf "$tree"
  mkdir -p "$tree/etc/modprobe.d" "$tree/usr/lib/modules/kernel/drivers" "$ROOT/boot"
  printf 'options zfs zfs_arc_max=%s\n' "$1" > "$tree/etc/modprobe.d/zfs.conf"
  echo ext4 > "$tree/usr/lib/modules/kernel/drivers/ext4.ko.zst"
  if [ "${2:-}" = zfs ]; then
    mkdir -p "$tree/usr/lib/modules/updates/dkms"
    echo zfs > "$tree/usr/lib/modules/updates/dkms/zfs.ko.zst"
  fi
  "$WORK/mkinitrd" "$tree" "$INITRD"
}

# initrd_arc_max: the zfs_arc_max in the fixture initramfs's modprobe.d
initrd_arc_max() {
  rm -rf "$WORK/unpacked"
  unmkinitramfs "$INITRD" "$WORK/unpacked"
  sed -E 's/.*zfs_arc_max=([0-9]+).*/\1/' "$WORK/unpacked/etc/modprobe.d/zfs.conf"
}

reset
printf 'options zfs zfs_arc_max=%s\n' $((30 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
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
expect "plan" "^  zfs_arc_max \(at boot\)  32212254720 \(30\.0GB\)"
# the haf container's start-up check, against the plan: ZFS 2.2's default is half of RAM
expect "plan" "^  ZFS ARC limit 63GB \(zfs_arc_max = 0, ZFS's default .* 24GB kernel, dirty-page and other-services reserves = 153GB, .* is 35GB"
expect "plan" "^  At boot: ZFS ARC limit 30\.0GB \+ 66\.0GB of huge pages \(33792 x 2048kB\) \+ 24GB kernel, dirty-page and other-services reserves = 120\.0GB, within the 125\.7GB of RAM$"
expect "plan" "--apply keeps the boot-time 32212254720, taken as set by hand"
expect "plan" "^Nothing was changed"
[ "$(state)" = "$before" ] || fail "plan: changed the host"
echo "ok: plan with the per-service breakdown, nothing changed"

# hugetlb accounting (cgroup2's memory_hugetlb_accounting): the haf container's 63GB shared segment
# in huge pages is charged to its memory.current and system.slice's, and counts as neither the
# container's nor the processes outside containers'
reset
cgroup system.slice/docker-aaaa.scope $((5 * GiB)) $((6 * GiB)) $((63 * GiB))
cgroup system.slice $((7 * GiB + GiB / 2)) $((6 * GiB + GiB / 2)) $((63 * GiB))
plan "hugetlb accounting"
expect "hugetlb accounting" "^  other services +10GB +measurement: 8\.0GB peak over 0s \+ 25%, at least 4GB$"
expect "hugetlb accounting" "^  ZFS ARC limit +35GB +formula: 125GB RAM - 66GB shared segment"
expect "hugetlb accounting" "^  \* haf-world-haf-1 +5\.0GB$"
expect "hugetlb accounting" "^    \(processes outside containers\) +1\.0GB$"
expect "hugetlb accounting" "^    total +8\.0GB$"
echo "ok: huge pages charged with hugetlb accounting are not other services"

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
expect "ZFS_ARC_MAX_GB" "The plan overcommits RAM: ZFS ARC limit 42\.0GB \+ 66\.0GB of huge pages .* = 142\.0GB, more than the 125\.7GB of RAM$"
echo "ok: HAF_OTHER_SERVICES_GB and ZFS_ARC_MAX_GB overrides"

# no cgroup v2 hierarchy: the fixed safety margin
reset
rm "$CG/cgroup.controllers"
plan "unmeasured"
expect "unmeasured" "^  other services +10GB +not measured \(no cgroup v2 hierarchy"
expect "unmeasured" "10GB safety margin$"
echo "ok: no cgroup v2: the fixed safety margin"

# a hand-set 30GB in modprobe.d, which fits beside the huge pages, is kept, with the runtime limit,
# without --force
reset
printf '# set by hand after swapping\noptions zfs zfs_arc_max=%s\n' $((30 * GiB)) > "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf"
echo $((30 * GiB)) > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
plan "--apply --persist, hand-set" --apply --persist
expect "--apply --persist, hand-set" "Kept zfs_arc_max=32212254720 \(30\.0GB\) in .*modprobe.d/haf-zfs-arc-max.conf, which differs from the plan's 37580963840 \(35\.0GB\): taken as set by hand"
grep -q "^options zfs zfs_arc_max=32212254720$" "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf" || fail "hand-set: modprobe.d changed"
grep -q "^# set by hand after swapping$" "$ROOT/etc/modprobe.d/haf-zfs-arc-max.conf" || fail "hand-set: modprobe.d comment lost"
[ "$(cat "$ROOT/sys/module/zfs/parameters/zfs_arc_max")" = 32212254720 ] || fail "hand-set: runtime zfs_arc_max changed"
[ "$(cat "$WORK/reserve.log")" = "reserve_huge_pages.sh --persist" ] || fail "hand-set: huge pages not reserved"
echo "ok: --apply --persist keeps a hand-set zfs_arc_max that fits"

# ZFS_ARC_MAX_GB matching it: the plan is the hand-set value, nothing to replace
echo ZFS_ARC_MAX_GB=30 >> "$BIN/.env"
plan "--apply --persist, ZFS_ARC_MAX_GB=30" --apply --persist
expect "--apply --persist, ZFS_ARC_MAX_GB=30" "zfs_arc_max is already 32212254720"
expect "--apply --persist, ZFS_ARC_MAX_GB=30" "At boot: zfs_arc_max=32212254720 in .* already"
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

# steem-20: 121GB, shared_buffers 60GB in 63GB of huge pages reserved at boot, and a stale
# zfs_arc_max of 83GB in modprobe.d (the plan's is 34GB)
steem20() {
  reset
  printf 'MemTotal:       127000000 kB\nMemAvailable:   40000000 kB\nHugepagesize:       2048 kB\n' > "$ROOT/proc/meminfo"
  echo 32256 > "$ROOT/proc/sys/vm/nr_hugepages"
  echo 89120571392 > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
  printf 'options zfs zfs_arc_max=89120571392\n' > "$ROOT/etc/modprobe.d/zfs.conf"
}
# --apply's refusal counts the fixed 10GB safety margin as other services, not the measured 10GB
OVERCOMMIT="ZFS ARC limit 83\.0GB \+ 63\.0GB of huge pages \(32256 x 2048kB\) \+ 24GB kernel, dirty-page and safety reserves = 170\.0GB, more than the 121\.1GB of RAM"
steem20
before=$(state)
plan "steem-20 plan"
expect "steem-20 plan" "^  ZFS ARC limit +34GB +formula: 121GB RAM - 63GB shared segment"
expect "steem-20 plan" "\[WARNING\].* At boot: ZFS ARC limit 83\.0GB \+ 63\.0GB of huge pages \(32256 x 2048kB\) \+ 24GB kernel, dirty-page and other-services reserves = 170\.0GB, more than the 121\.1GB of RAM$"
expect "steem-20 plan" "--apply refuses to keep the boot-time 89120571392, which overcommits RAM"
[ "$(state)" = "$before" ] || fail "steem-20 plan: changed the host"

# plan_refused NAME COMMAND...: COMMAND exits non-zero naming the file and both values, and changes
# nothing
plan_refused() {
  local name=$1
  shift
  if MEMORY_PLAN_ROOT="$ROOT" POSTGRESQL_SHARED_BUFFERS_GB='' HAF_OTHER_SERVICES_GB='' ZFS_ARC_MAX_GB='' PROJECT_NAME='' \
    "$@" > "$WORK/out" 2>&1; then
    fail "$name: kept the stale zfs_arc_max ($(cat "$WORK/out"))"
  fi
  expect "$name" "\[ERROR\].* Refusing to keep zfs_arc_max=89120571392 \(83\.0GB\) in .*/etc/modprobe\.d/zfs\.conf, which differs from the plan's 36507222016 \(34\.0GB\): $OVERCOMMIT$"
  expect "$name" "sudo .* --apply --persist --force; to make another value the plan: ZFS_ARC_MAX_GB in .env$"
  [ "$(state)" = "$before" ] || fail "$name: changed the host"
}
plan_refused "steem-20 --apply --arc-only --persist" "$BIN/memory_plan.sh" --sample-seconds 0 --apply --arc-only --persist
plan_refused "steem-20 --apply" "$BIN/memory_plan.sh" --sample-seconds 0 --apply
# reduce_writebacks.sh --zfs-only runs memory_plan.sh --apply --arc-only (without root here: its
# own root check is all it would add)
cp "$REPO_DIR/reduce_writebacks.sh" "$BIN/"
sed -i 's/^    check_root "\$@"$/    : check_root/' "$BIN/reduce_writebacks.sh"
plan_refused "steem-20 reduce_writebacks.sh --zfs-only --persist" "$BIN/reduce_writebacks.sh" --zfs-only --persist
echo "ok: steem-20's stale zfs_arc_max overcommits RAM: reported, and refused by --apply"

plan "steem-20 --force" --apply --arc-only --persist --force
expect "steem-20 --force" "zfs.conf: zfs_arc_max changed from 89120571392 to 36507222016"
plan "steem-20 fixed"
expect "steem-20 fixed" "^  At boot: ZFS ARC limit 34\.0GB \+ 63\.0GB of huge pages .* = 121\.0GB, within the 121\.1GB of RAM$"
if grep -q "overcommit" "$WORK/out"; then fail "steem-20 fixed: still reports an overcommit"; fi
echo "ok: steem-20 with the plan's zfs_arc_max: no overcommit"

# a hand-set 32GB, with a transient 1.9GB sandbox in the sample: the measured 9.9GB peak gives 13GB
# of other services, 0.9GB over RAM; with the 10GB safety margin it fits, so --apply keeps it
steem20
printf 'options zfs zfs_arc_max=%s\n' $((32 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
echo $((32 * GiB)) > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
cgroup system.slice/docker-dddd.scope $((GiB * 19 / 10)) 0
cgroup system.slice $((7 * GiB + GiB / 2 + GiB * 19 / 10)) $((60 * GiB + GiB / 2))
echo 'dddd aidev-sandbox-1 sandbox' >> "$WORK/containers"
NEAR="ZFS ARC limit 32\.0GB \+ 63\.0GB of huge pages \(32256 x 2048kB\) \+ 27GB kernel, dirty-page and other-services reserves = 122\.0GB, more than the 121\.1GB of RAM"
before=$(state)
plan "steem-20 32GB plan"
expect "steem-20 32GB plan" "^  other services +13GB +measurement: 9\.9GB peak"
expect "steem-20 32GB plan" "\[WARNING\].* At boot: $NEAR$"
expect "steem-20 32GB plan" "--apply keeps the boot-time 34359738368, taken as set by hand, .*: it overcommits RAM only with the measured other services, not with the 10GB safety margin$"
plan "steem-20 32GB --apply --arc-only" --apply --arc-only
expect "steem-20 32GB --apply --arc-only" "\[WARNING\].* At boot: $NEAR$"
expect "steem-20 32GB --apply --arc-only" "Kept zfs_arc_max=34359738368 \(32\.0GB\) in .*/zfs\.conf, which differs from the plan's .*: taken as set by hand"
[ "$(state)" = "$before" ] || fail "steem-20 32GB --apply --arc-only: changed the host"
echo "ok: steem-20's hand-set 32GB, over RAM only with the measured other services: kept with a warning"

# HAF_OTHER_SERVICES_GB=13 is a configured figure: --apply refuses the same 32GB on it
echo HAF_OTHER_SERVICES_GB=13 >> "$BIN/.env"
if MEMORY_PLAN_ROOT="$ROOT" POSTGRESQL_SHARED_BUFFERS_GB='' ZFS_ARC_MAX_GB='' PROJECT_NAME='' \
  "$BIN/memory_plan.sh" --sample-seconds 0 --apply --arc-only > "$WORK/out" 2>&1; then
  fail "steem-20 32GB, HAF_OTHER_SERVICES_GB=13: kept ($(cat "$WORK/out"))"
fi
expect "steem-20 32GB, HAF_OTHER_SERVICES_GB=13" "\[ERROR\].* Refusing to keep zfs_arc_max=34359738368 \(32\.0GB\) .*: $NEAR$"
[ "$(state)" = "$before" ] || fail "steem-20 32GB, HAF_OTHER_SERVICES_GB=13: changed the host"
echo "ok: steem-20's hand-set 32GB, over RAM with HAF_OTHER_SERVICES_GB: refused"

# reserve_huge_pages.sh warns about the stale boot-time limit beside its reservation
RHP="$WORK/reserve"
mkdir -p "$RHP"
cp "$REPO_DIR/reserve_huge_pages.sh" "$REPO_DIR/postgresql_memory.sh" "$RHP/"
# reserve NAME: run reserve_huge_pages.sh --dry-run, output in $WORK/out; fails the test when it fails
reserve() {
  MEMORY_PLAN_ROOT="$ROOT" POSTGRESQL_SHARED_BUFFERS_GB='' HAF_OTHER_SERVICES_GB='' "$RHP/reserve_huge_pages.sh" --dry-run > "$WORK/out" 2>&1 \
    || fail "$1: exited $? ($(cat "$WORK/out"))"
}
steem20
reserve "reserve_huge_pages.sh"
expect "reserve_huge_pages.sh" "\[WARNING\].* At boot: ZFS ARC limit 83\.0GB \+ 63\.0GB of huge pages \(32256 x 2048kB\) \+ 24GB kernel, dirty-page and safety reserves = 170\.0GB, more than the 121\.1GB of RAM \(zfs_arc_max=89120571392 in .*/zfs\.conf\)$"
printf 'options zfs zfs_arc_max=%s\n' $((34 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
reserve "reserve_huge_pages.sh, fixed"
if grep -q "WARNING" "$WORK/out"; then fail "reserve_huge_pages.sh, fixed: warns ($(cat "$WORK/out"))"; fi
echo "ok: reserve_huge_pages.sh warns about a boot-time zfs_arc_max that overcommits RAM"

# steem-20 now: 32GB set by hand in /etc/modprobe.d after the boot, while the initramfs that loads
# zfs still carries the 83GB it was built with
steem20
printf 'options zfs zfs_arc_max=%s\n' $((32 * GiB)) > "$ROOT/etc/modprobe.d/zfs.conf"
echo $((32 * GiB)) > "$ROOT/sys/module/zfs/parameters/zfs_arc_max"
initrd 89120571392 zfs
[ "$(initrd_arc_max)" = 89120571392 ] || fail "initramfs fixture: read back '$(initrd_arc_max)'"
before=$(state)
plan "steem-20 stale initramfs"
expect "steem-20 stale initramfs" "^  zfs_arc_max \(at boot\)  89120571392 \(83\.0GB\), from the initramfs .*/boot/initrd\.img-$(uname -r)$"
expect "steem-20 stale initramfs" "^  zfs_arc_max \(/etc\)     34359738368 \(32\.0GB\), from .*/etc/modprobe\.d$"
expect "steem-20 stale initramfs" "\[WARNING\].* At boot: ZFS ARC limit 83\.0GB \+ 63\.0GB of huge pages .* = 170\.0GB, more than the 121\.1GB of RAM$"
expect "steem-20 stale initramfs" "\[WARNING\].* zfs_arc_max differs between the initramfs .* \(89120571392\) and .*/etc/modprobe\.d \(34359738368\): the zfs module gets the initramfs's at the next boot$"
expect "steem-20 stale initramfs" "\[WARNING\].* To make the plan's 36507222016 the boot-time limit in both: sudo .* --apply --arc-only --persist --force$"
expect "steem-20 stale initramfs" "--apply refuses to keep the boot-time 89120571392, which overcommits RAM"
[ "$(state)" = "$before" ] || fail "steem-20 stale initramfs: changed the host"
reserve "reserve_huge_pages.sh, stale initramfs"
expect "reserve_huge_pages.sh, stale initramfs" "\[WARNING\].* At boot: ZFS ARC limit 83\.0GB \+ 63\.0GB of huge pages .* = 170\.0GB, more than the 121\.1GB of RAM \(zfs_arc_max=89120571392 in .*/boot/initrd\.img-$(uname -r) \(etc/modprobe\.d/zfs\.conf\)\)$"
[ "$(state)" = "$before" ] || fail "reserve_huge_pages.sh, stale initramfs: changed the host"
if MEMORY_PLAN_ROOT="$ROOT" POSTGRESQL_SHARED_BUFFERS_GB='' HAF_OTHER_SERVICES_GB='' ZFS_ARC_MAX_GB='' PROJECT_NAME='' \
  "$BIN/memory_plan.sh" --sample-seconds 0 --apply --arc-only --persist > "$WORK/out" 2>&1; then
  fail "steem-20 stale initramfs --apply: kept 83GB ($(cat "$WORK/out"))"
fi
expect "steem-20 stale initramfs --apply" "\[ERROR\].* Refusing to keep zfs_arc_max=89120571392 \(83\.0GB\) in .*/boot/initrd\.img-.* \(etc/modprobe\.d/zfs\.conf\), which differs from the plan's 36507222016"
[ "$(state)" = "$before" ] || fail "steem-20 stale initramfs --apply: changed the host"
plan "steem-20 stale initramfs --force" --apply --arc-only --persist --force
expect "steem-20 stale initramfs --force" "zfs\.conf: zfs_arc_max changed from 34359738368 to 36507222016"
expect "steem-20 stale initramfs --force" "Updated .*/boot/initrd\.img-"
[ "$(cat "$WORK/update-initramfs.log")" = "update-initramfs -u" ] || fail "--force: update-initramfs not run once"
[ "$(initrd_arc_max)" = 36507222016 ] || fail "--force: the initramfs has $(initrd_arc_max)"
plan "steem-20 initramfs rebuilt"
expect "steem-20 initramfs rebuilt" "^  zfs_arc_max \(at boot\)  36507222016 \(34\.0GB\), from the initramfs "
if grep -qE "overcommit|differs|\(/etc\)" "$WORK/out"; then fail "steem-20 initramfs rebuilt: $(cat "$WORK/out")"; fi
reserve "reserve_huge_pages.sh, initramfs rebuilt"
if grep -q "WARNING" "$WORK/out"; then fail "reserve_huge_pages.sh, initramfs rebuilt: warns ($(cat "$WORK/out"))"; fi
echo "ok: steem-20's stale initramfs: reported as the boot-time value (also by reserve_huge_pages.sh), refused, rebuilt with --force"

# /etc/modprobe.d already holds the plan, only the initramfs is stale: --persist rebuilds it
steem20
printf 'options zfs zfs_arc_max=36507222016\n' > "$ROOT/etc/modprobe.d/zfs.conf"
initrd 89120571392 zfs
plan "stale initramfs only" --apply --arc-only --persist
expect "stale initramfs only" "At boot: zfs_arc_max=36507222016 in .*/etc/modprobe\.d already"
expect "stale initramfs only" "Updated .*/boot/initrd\.img-"
[ "$(initrd_arc_max)" = 36507222016 ] || fail "stale initramfs only: the initramfs has $(initrd_arc_max)"
rm "$WORK/update-initramfs.log"
plan "initramfs current" --apply --arc-only --persist
expect "initramfs current" "At boot: zfs_arc_max=36507222016 in the initramfs .* already"
[ ! -e "$WORK/update-initramfs.log" ] || fail "initramfs current: update-initramfs run"
echo "ok: --persist rebuilds an initramfs whose zfs_arc_max alone differs from the plan"

# an initramfs without the zfs module: /etc/modprobe.d is what the module reads, whatever the
# initramfs's copy says
steem20
printf 'options zfs zfs_arc_max=36507222016\n' > "$ROOT/etc/modprobe.d/zfs.conf"
initrd 89120571392
plan "initramfs without zfs"
expect "initramfs without zfs" "^  zfs_arc_max \(at boot\)  36507222016 \(34\.0GB\), from .*/etc/modprobe\.d$"
if grep -qE "differs|\(/etc\)|initramfs" "$WORK/out"; then fail "initramfs without zfs: $(cat "$WORK/out")"; fi
plan "initramfs without zfs --persist" --apply --arc-only --persist
expect "initramfs without zfs --persist" "The zfs module is not in .*/boot/initrd\.img-.*: it reads .*/etc/modprobe\.d"
[ ! -e "$WORK/update-initramfs.log" ] || fail "initramfs without zfs: update-initramfs run"
printf 'options zfs zfs_arc_max=%s\n' 89120571392 > "$ROOT/etc/modprobe.d/zfs.conf"
initrd 36507222016
reserve "reserve_huge_pages.sh, initramfs without zfs"
expect "reserve_huge_pages.sh, initramfs without zfs" "\[WARNING\].* At boot: .* = 170\.0GB, more than the 121\.1GB of RAM \(zfs_arc_max=89120571392 in .*/etc/modprobe\.d/zfs\.conf\)$"
echo "ok: an initramfs without zfs: /etc/modprobe.d is the boot-time source"

for args in "--persist" "--force" "--arc-only" "--sample-seconds x" "--bogus"; do
  # shellcheck disable=SC2086 # split the arguments
  if MEMORY_PLAN_ROOT="$ROOT" "$BIN/memory_plan.sh" $args > /dev/null 2>&1; then
    fail "'$args' accepted"
  fi
done
echo "ok: bad arguments refused"

echo "All memory_plan.sh tests passed"
