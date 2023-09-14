#! /bin/sh

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

if [ ! -z "$ENV_FILE" ]; then
  echo reading $ENV_FILE
  source $ENV_FILE
fi

[ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"

echo "zpool:             $ZPOOL"
echo "  mounted on:      $ZPOOL_MOUNT_POINT"
echo "top-level dataset: $TOP_LEVEL_DATASET"
echo "  mounted on:      $TOP_LEVEL_DATASET_MOUNTPOINT"

zfs_common_options="-o atime=off"
zfs_compressed_options="-o compression=lz4"
zfs_uncompressed_options="-o compression=off"
zfs_postgres_options="-o recordsize=8k" # or "-o recordsize=16k", consider also "-o logbias=throughput"
zfs create $zfs_common_options $zfs_compressed_options "${ZPOOL}/${TOP_LEVEL_DATASET}"

# create an uncompressed dataset for the blockchain.  Blocks in it are already compressed, so won't compress further.
# you may also have your shared_memory.bin file in this directory.  AFAIK we haven't done studies on whether compression
# helps shared_memory.bin.
zfs create $zfs_common_options $zfs_uncompressed_options "${ZPOOL}/${TOP_LEVEL_DATASET}/blockchain"

# create an unmountable dataset to serve as the parent for pgdata & tablespaces
zfs create $zfs_common_options $zfs_compressed_options -o canmount=off "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store"

# create a dataset for everything in PostgreSQL except for HAF (system tables and the like).  Having this directory
# uncompressed improved performance in tests, and it's not very big
zfs create $zfs_common_options $zfs_uncompressed_options $zfs_postgres_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata"
# create a dataset for the write-ahead logs, simply to reduce the size of snapshots of other datasets
zfs create $zfs_common_options $zfs_uncompressed_options $zfs_postgres_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

# create a dataset for the main HAF database itself
zfs create $zfs_common_options $zfs_compressed_options $zfs_postgres_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"

# 1000:100 is hived:users inside the container
chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT"

# 105:109 is postgres:postgres inside the container
chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"

mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp pgtune.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp zfs.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
# 105:109 is postgres:postgres inside the container
chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
