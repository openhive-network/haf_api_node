#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] [--public-snapshot] [--temp-dir=dir] [--swap-logs-with-dataset=dataset] snapshot-name"
  echo "  --public-snapshot         move log files to /tmp before taking the snapshot, then"
  echo "                            restore them afterwards"
  echo "  --temp-dir                use a different temp directory (use if /tmp isn't big enough)"
  echo "  --swap-logs-with-dataset  with extremely large log files, it's too slow to copy/restore log files."
  echo "                            Use this if you want to maintain a separate dataset for logs that always"
  echo "                            stays empty.  Before the snapshot, we swap the logs dataset with the empty"
  echo "                            dataset, then swap back afterwards.  That way the large logs files aren't"
  echo "                            of the snapshots.  This is a lot faster, but makes managing datasets more"
  echo "                            complicated, so only use it if you really need to"
}

OPTIONS=$(getopt -o he:pt:l: --long env-file:,help,zpool:,top-level-dataset:,public-snapshot,temp-dir:,swap-logs-with-dataset: -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""
PUBLIC_SNAPSHOT=0
SWAP_LOGS_DATASET=""
TMPDIR=/tmp

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
    --public-snapshot|-p)
      PUBLIC_SNAPSHOT=1
      shift
      ;;
    --temp-dir|-t)
      TMPDIR="$2"
      shift 2
      ;;
    --swap-logs-with-dataset|-l)
      SWAP_LOGS_DATASET="$2"
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
if [ ! -z "${SWAP_LOGS_DATASET}" ]; then
  check_dataset_is_unmountable "${SWAP_LOGS_DATASET}"
fi

echo "All datasets appear unmountable"

if [ $PUBLIC_SNAPSHOT -eq 1 ]; then
  stdbuf -o0 echo ""
  stdbuf -o0 echo "Moving log files out of the dataset because this is a public snapshot... "

  LOGS_DIR="logs"
  LOGS_DIR_FOR_RM="logs"
  if [ ! -z "${SWAP_LOGS_DATASET}" ]; then
    LOGS_DIR=""
    LOGS_DIR_FOR_RM="does_not_exist_123456789"
  fi

  (cd "${TOP_LEVEL_DATASET_MOUNTPOINT}" && \
   tar cvf $TMPDIR/snapshot_zfs_datasets_saved_files_$$.tar $(ls -d $LOGS_DIR p2p docker_entrypoint.log 2>/dev/null) && \
   rm -rf ${LOGS_DIR_FOR_RM}/*/* p2p/* docker_entrypoint.log)

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

rename() {
  stdbuf -o0 echo -n "Renaming $1 to $2..."
  zfs rename "$1" "$2"
  echo " done"
}

unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
unmount "${ZPOOL}/${TOP_LEVEL_DATASET}"

if [ ! -z "${SWAP_LOGS_DATASET}" ]; then
  echo "Swapping logs dataset"
  rename "${ZPOOL}/${TOP_LEVEL_DATASET}/logs" "${ZPOOL}/temp-saved-logs"
  rename "${SWAP_LOGS_DATASET}" "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
  echo -n "Done swapping logs dataset"
fi

stdbuf -o0 echo -n "Taking snapshot..."
zfs snap -r "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}"
echo " done"

if [ ! -z "${SWAP_LOGS_DATASET}" ]; then
  echo "Restoring logs dataset"
  rename "${ZPOOL}/${TOP_LEVEL_DATASET}/logs" "${SWAP_LOGS_DATASET}"
  rename "${ZPOOL}/temp-saved-logs" "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"
  echo "Done restoring logs dataset"
fi

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
   tar xvf $TMPDIR/snapshot_zfs_datasets_saved_files_$$.tar &&
   rm $TMPDIR/snapshot_zfs_datasets_saved_files_$$.tar)
  stdbuf -o0 echo "Done restoring log files."
fi


zfs list "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/logs@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata@${SNAPSHOT_NAME}" \
         "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal@${SNAPSHOT_NAME}"
