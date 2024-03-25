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
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory"
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}"
echo "All datasets appear unmountable"

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

unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}"

rollback() {
  stdbuf -o0 echo -n "Rolling back $1..."
  zfs rollback "$1@$SNAPSHOT_NAME"
  echo " done"
}

rollback "${ZPOOL}/${TOP_LEVEL_DATASET}"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
rollback "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

remount() {
  stdbuf -o0 echo -n "Re-mounting $1..."
  zfs mount "$1"
  echo " done"
}

remount "${ZPOOL}/${TOP_LEVEL_DATASET}"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/shared_memory" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/logs" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
