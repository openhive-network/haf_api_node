#!/usr/bin/env bash
#
# Test that repair_permissions.sh leaves a data directory that is not on ZFS as before: it exits 0,
# prints no ZFS check, and runs no zfs command (a zfs on PATH that fails and leaves a marker when
# called), with and without --fix-zfs and with ZPOOL/TOP_LEVEL_DATASET set as a .env would set them.
# No root needed: id and chown are stubbed.  Skips (exit 0) when the work directory is itself on ZFS.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)

fail() {
  echo "FAIL: $*"
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ "$(stat -f -c %T "$WORK" 2>/dev/null)" = zfs ]; then
  echo "SKIP repair-permissions: $WORK is on ZFS"
  exit 0
fi

mkdir -p "$WORK/bin" "$WORK/datadir/haf_db_store" "$WORK/datadir/logs/postgresql"
cat > "$WORK/bin/zfs" <<EOF
#!/bin/sh
echo "zfs \$*" >> "$WORK/zfs-called"
exit 1
EOF
cat > "$WORK/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$WORK/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/"*

run() {
  local name="$1" output rc=0
  shift
  output=$(env PATH="$WORK/bin:$PATH" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "$name: exit $rc: $output"
  [ ! -e "$WORK/zfs-called" ] || fail "$name: ran $(cat "$WORK/zfs-called")"
  if grep -qi zfs <<< "$output"; then
    fail "$name: printed a ZFS check: $output"
  fi
  [ "$(tail -1 <<< "$output")" = "Permission repair complete!" ] || fail "$name: unexpected output: $output"
  echo "ok - $name"
}

run "data-dir" sh "$REPO_DIR/repair_permissions.sh" --data-dir="$WORK/datadir"
run "data-dir with --fix-zfs" sh "$REPO_DIR/repair_permissions.sh" --data-dir="$WORK/datadir" --fix-zfs
run "zpool and dataset from the environment" env ZPOOL=haf-pool TOP_LEVEL_DATASET=haf-datadir \
  TOP_LEVEL_DATASET_MOUNTPOINT="$WORK/datadir" sh "$REPO_DIR/repair_permissions.sh" --fix-zfs
