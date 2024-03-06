#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] [--public-snapshot] snapshot-name"
}

OPTIONS=$(getopt -o he: --long env-file:,help,zpool:,top-level-dataset:,public-snapshot -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""
PUBLIC_SNAPSHOT=0

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
    --public-snapshot)
      PUBLIC_SNAPSHOT=1
      shift
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
    echo "argument to tell this script what datasets to snapshot."
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

echo "Snapshotting the data set using snapshot name $SNAPSHOT_NAME:"
echo "zpool:             $ZPOOL"
echo "  mounted on:      $ZPOOL_MOUNT_POINT"
echo "top-level dataset: $TOP_LEVEL_DATASET"
echo "  mounted on:      $TOP_LEVEL_DATASET_MOUNTPOINT"
echo ""
echo "This will unmount the HAF datasets, take a snapshot, then remount them."

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
check_dataset_is_unmountable "${TOP_LEVEL_DATASET_MOUNTPOINT}"
echo "All datasets appear unmountable"

if [ $PUBLIC_SNAPSHOT -eq 1 ]; then
  stdbuf -o0 echo ""
  stdbuf -o0 echo "Moving log files out of the dataset because this is a public snapshot... "
  (cd "${TOP_LEVEL_DATASET_MOUNTPOINT}" && \
   tar cvf /tmp/snapshot_zfs_datasets_saved_files_$$.tar $(ls -d logs p2p docker_entrypoint.log 2>/dev/null) && \
   rm -r logs/*/* p2p/* docker_entrypoint.log)
  stdbuf -o0 echo "Done saving off log files"
fi

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
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}"

stdbuf -o0 echo -n "Taking snapshot..."
zfs snap -r "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}"
echo " done"

remount() {
  stdbuf -o0 echo -n "Re-mounting $1..."
  zfs mount "$1"
  echo " done"
}

remount "${ZPOOL}/${TOP_LEVEL_DATASET}"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
remount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

if [ $PUBLIC_SNAPSHOT -eq 1 ]; then
  echo ""
  stdbuf -o0 echo "Restoring log files..."
  (cd "${TOP_LEVEL_DATASET_MOUNTPOINT}" && \
   tar xvf /tmp/snapshot_zfs_datasets_saved_files_$$.tar &&
   rm /tmp/snapshot_zfs_datasets_saved_files_$$.tar)
  stdbuf -o0 echo "Done restoring log files."
fi


zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/logs@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal@${SNAPSHOT_NAME}"
