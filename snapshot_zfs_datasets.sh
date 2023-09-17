#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 --env-file=filename"
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

SNAPSHOT_NAME="$1"
if [ -z "$SNAPSHOT_NAME" ]; then
  echo "No snapshot name provided"
  exit 1
fi

if [ ! -z "$ENV_FILE" ]; then
  echo reading $ENV_FILE
  . $ENV_FILE
fi

[ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"

echo "Snapshotting the data set using snapshot name $SNAPSHOT_NAME:"
echo "zpool:             $ZPOOL"
echo "  mounted on:      $ZPOOL_MOUNT_POINT"
echo "top-level dataset: $TOP_LEVEL_DATASET"
echo "  mounted on:      $TOP_LEVEL_DATASET_MOUNTPOINT"

sync; sync; sync
echo 3 > /proc/sys/vm/drop_caches

zfs umount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
zfs umount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
zfs umount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
zfs umount "${ZPOOL}/${TOP_LEVEL_DATASET}"

zfs snap -r "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}"

zfs mount "${ZPOOL}/${TOP_LEVEL_DATASET}"
zfs mount "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"
zfs mount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"
zfs mount "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
