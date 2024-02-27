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

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  if [ ! -z "$ENV_FILE" ]; then
    echo reading $ENV_FILE
    . $ENV_FILE
  elif [ -f .env ]; then
    echo reading configuration from .env
    . ./.env
  else
    echo "You must either provide an --env-file argument or both a --zpool and --top-level-dataset"
    echo "argument to tell this script what to create."
    exit 1
  fi
fi

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  echo "Your environment file must define the ZPOOL and TOP_LEVEL_DATASET environment variables"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
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
# several sites recommend 8k blocks for optimizing postgres on zfs, but we have found that it
# kills compression ratios for haf_block_log, so we've decided to leave it at the default 128k
zfs_postgres_options="" # or "-o recordsize=8k -o recordsize=16k", consider also "-o logbias=throughput"
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
# note: this is disabled, I'm not sure we really care about the size of the snapshots of other datasets, we
# only care about the total size, and I'm not sure this gives us any benefit
zfs create $zfs_common_options $zfs_uncompressed_options $zfs_postgres_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/pgdata/pg_wal"

# create a dataset for the main HAF database itself
zfs create $zfs_common_options $zfs_compressed_options $zfs_postgres_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/haf_db_store/tablespace"

# create a dataset for logs (hived and postgresql, for now)
zfs create $zfs_common_options $zfs_compressed_options -o canmount=on "${ZPOOL}/${TOP_LEVEL_DATASET}/logs"

# 1000:100 is hived:users inside the container
chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT"

# 105:109 is postgres:postgres inside the container
chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"

mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp pgtune.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp zfs.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp logging.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
# 105:109 is postgres:postgres inside the container
chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"

mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/caddy"
# 1000:100 is hived:users inside the container
chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs"
# 105:109 is postgres:postgres inside the container
chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql" "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
