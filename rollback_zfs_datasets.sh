#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] snapshot-name"
}

OPTIONS=$(getopt -o he: --long env-file:,help,zpool:,top-level-dataset: -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e)
      ENV_FILE="$2"
      shift 2
      ;;
    --zpool)
      ZPOOL="$2"
      shift 2
      ;;
    --top-level-dataset)
      TOP_LEVEL_DATASET="$2"
      shift 2
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
  esac
done

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  if [ ! -z "$ENV_FILE" ]; then
    echo reading $ENV_FILE
    . $ENV_FILE
  elif [ -f .env ]; then
    echo reading configuration from .env
    . ./.env
  else
    echo "You must either provide an --env-file argument or both a --zpool and --top-level-dataset"
    echo "argument to tell this script what datasets to rollback."
    exit 1
  fi
fi

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  echo "Your environment file must define the ZPOOL and TOP_LEVEL_DATASET environment variables"
  exit 1
fi

SNAPSHOT_NAME="$1"
if [ -z "$SNAPSHOT_NAME" ]; then
  echo "No snapshot name provided"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

[ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"

check_dataset_is_unmountable() {
  stdbuf -o0 echo -n "Checking $1..."
  if lsof_result=$(lsof -w +f -- $1); then
    echo " error, dataset in use"
    echo "$lsof_result"
    exit 1
  fi
  echo " ok"
}

echo "Verifying that all datasets are unmountable"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store/pgdata/pg_wal"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store/pgdata"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store/tablespace"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/blockchain"
# Check if hivesense datasets exist before checking if they're unmountable
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama" >/dev/null 2>&1; then
  check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/hivesense/ollama"
fi
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense" >/dev/null 2>&1; then
  check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/hivesense"
fi
# Check if comments-rocksdb-storage exists before checking if it's unmountable
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage" >/dev/null 2>&1; then
  check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory/comments-rocksdb-storage"
fi
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}"
echo "All datasets appear unmountable"

# Preflight: verify all datasets are currently mounted
echo "Verifying that all datasets are currently mounted"
check_dataset_is_mounted() {
  local ds="$1"
  if ! zfs list "$ds" >/dev/null 2>&1; then
    return  # dataset doesn't exist, skip
  fi
  local mounted
  mounted=$(zfs get -H -o value mounted "$ds")
  if [ "$mounted" != "yes" ]; then
    echo "ERROR: Dataset $ds is not mounted. Something is wrong — refusing to proceed."
    exit 1
  fi
}
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
check_dataset_is_mounted "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
echo "All datasets are mounted"

# Preflight: verify snapshot exists on all required datasets
echo "Verifying snapshot @${SNAPSHOT_NAME} exists on all datasets..."
missing_snaps=""
check_snapshot_exists() {
  local ds="$1"
  if ! zfs list "$ds" >/dev/null 2>&1; then
    return  # dataset doesn't exist, skip
  fi
  if ! zfs list "${ds}@${SNAPSHOT_NAME}" >/dev/null 2>&1; then
    echo "  MISSING: ${ds}@${SNAPSHOT_NAME}"
    missing_snaps="$missing_snaps ${ds}"
  fi
}
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
check_snapshot_exists "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
if [ -n "$missing_snaps" ]; then
  echo "ERROR: Snapshot @${SNAPSHOT_NAME} is missing on one or more datasets (listed above)."
  echo "Cannot rollback — the snapshot set is incomplete."
  exit 1
fi
echo "All required snapshots found"

# Preflight: check for newer snapshots that would block rollback
echo "Checking for newer snapshots that would block rollback..."
newer_snaps_found=""
check_no_newer_snapshots() {
  local ds="$1"
  if ! zfs list "$ds" >/dev/null 2>&1; then
    return  # dataset doesn't exist, skip
  fi
  # List snapshots created after the target one
  local newer
  newer=$(zfs list -H -o name -t snapshot -s creation "$ds" 2>/dev/null | sed -n "/@${SNAPSHOT_NAME}\$/,\$p" | tail -n +2)
  if [ -n "$newer" ]; then
    echo "$newer" | while read snap; do
      echo "  NEWER: $snap (blocks rollback of ${ds}@${SNAPSHOT_NAME})"
    done
    newer_snaps_found="$newer_snaps_found $newer"
  fi
}
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
check_no_newer_snapshots "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
if [ -n "$newer_snaps_found" ]; then
  echo "ERROR: Newer snapshots exist (listed above). zfs rollback will fail unless they are destroyed first."
  echo "Destroy them manually with: zfs destroy <snapshot-name>"
  exit 1
fi
echo "No newer snapshots found"

echo ""
echo "Rolling back the data set to snapshot name $SNAPSHOT_NAME:"
echo "zpool:             $ZPOOL"
echo "  mounted on:      $ZPOOL_MOUNT_POINT"
echo "top-level dataset: $TOP_LEVEL_DATASET"
echo "  mounted on:      $TOP_LEVEL_DATASET_MOUNTPOINT"
echo "This will unmount the HAF datasets, rollback to the named snapshot, then remount them."
echo "All data on those datasets since the snapshot $SNAPSHOT_NAME will be lost"
stdbuf -o0 echo -n "Hit control-c in the next 5 seconds to abort..."
sleep 5
echo " continuing"

stdbuf -o0 echo -n "syncing filesystems..."
sync; sync; sync
echo " done"
stdbuf -o0 echo -n "dropping caches..."
echo 3 > /proc/sys/vm/drop_caches
echo " done"

unmount() {
  stdbuf -o0 echo -n "Unmounting $1..."
  zfs umount "$1"
  echo " done"
}

remount_if_needed() {
  local ds="$1"
  if ! zfs list "$ds" >/dev/null 2>&1; then
    return  # dataset doesn't exist, skip
  fi
  local mounted
  mounted=$(zfs get -H -o value mounted "$ds" 2>/dev/null || echo "unknown")
  if [ "$mounted" = "yes" ]; then
    return  # already mounted
  fi
  stdbuf -o0 echo -n "Re-mounting $ds..."
  if zfs mount "$ds"; then
    echo " done"
  else
    echo " FAILED (may need manual intervention)"
  fi
}

remount_all() {
  echo "Remounting all datasets..."
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
  remount_if_needed "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
}

DATASETS_UNMOUNTED=0
cleanup() {
  # Disable set -e inside trap to ensure all remounts are attempted
  set +e
  if [ "$DATASETS_UNMOUNTED" -eq 1 ]; then
    echo ""
    echo "ERROR: Script failed with datasets unmounted. Remounting..."
    remount_all
    echo "Datasets remounted."
  fi
}
trap cleanup EXIT

DATASETS_UNMOUNTED=1
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
# Unmount hivesense datasets if they exist
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama" >/dev/null 2>&1; then
  unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
fi
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense" >/dev/null 2>&1; then
  unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
fi
# Unmount comments-rocksdb-storage if it exists
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage" >/dev/null 2>&1; then
  unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
fi
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}"

rollback() {
  stdbuf -o0 echo -n "Rolling back $1..."
  zfs rollback "$1@$SNAPSHOT_NAME"
  echo " done"
}

rollback "${ZPOOL}/${TOP_LEVEL_DATASET}"
# Rollback comments-rocksdb-storage if it exists
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage" >/dev/null 2>&1; then
  rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
fi
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
# Rollback hivesense datasets if they exist
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense" >/dev/null 2>&1; then
  rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
fi
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama" >/dev/null 2>&1; then
  rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
fi
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

remount_all
DATASETS_UNMOUNTED=0

# Build list of datasets to display
DATASET_LIST="${ZPOOL}/${TOP_LEVEL_DATASET}"
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
# Add comments-rocksdb-storage if it exists
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage" >/dev/null 2>&1; then
  DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory/comments-rocksdb-storage"
fi
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
# Add hivesense datasets if they exist
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense" >/dev/null 2>&1; then
  DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense"
fi
if zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama" >/dev/null 2>&1; then
  DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/hivesense/ollama"
fi
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
DATASET_LIST="${DATASET_LIST} ${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

zfs list ${DATASET_LIST}

# ZFS rollback resets file ownership to snapshot state, which may not match
# current container UIDs. Repair permissions to ensure containers can start cleanly.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/repair_permissions.sh" --zpool "$ZPOOL" --top-level-dataset "$TOP_LEVEL_DATASET"
