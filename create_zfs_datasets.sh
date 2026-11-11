#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 --env-file=filename"
}

OPTIONS=$(getopt -o he:s --long env-file:,help,zpool:,top-level-dataset:,skip-empty-snapshot -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""
SKIP_EMPTY_SNAPSHOT=false

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
    --skip-empty-snapshot|-s)
      SKIP_EMPTY_SNAPSHOT=true
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

# shellcheck source=zfs_dataset_layout.sh
. "$(dirname "$0")/zfs_dataset_layout.sh"

# create the datasets with the properties zfs_dataset_layout lists, parents first
zfs_dataset_layout | while read -r relative_dataset _presence properties; do
  dataset="${ZPOOL}/${TOP_LEVEL_DATASET}"
  [ "$relative_dataset" = . ] || dataset="${dataset}/${relative_dataset}"
  create_options=""
  for property in $properties; do
    create_options="$create_options -o $property"
  done
  # shellcheck disable=SC2086 # one word per option
  zfs create $create_options "$dataset"
done

# needs to exist to be bind-mounted, no real reason to make it a dataset of its own though
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory/haf_wal"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory/comments-rocksdb-storage"

# Create hivesense subdirectories
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"

# Copy PostgreSQL configuration files
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp pgtune.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp zfs.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp compression.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
cp logging.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"

# Create log subdirectories
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/caddy"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/haproxy"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/apps"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/monitoring/prometheus"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/monitoring/grafana"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/monitoring/loki"

# Use repair_permissions.sh to set all permissions correctly
echo "Setting permissions..."
./repair_permissions.sh --zpool="$ZPOOL" --top-level-dataset="$TOP_LEVEL_DATASET"

if [ "$SKIP_EMPTY_SNAPSHOT" = false ]; then
  # Create a snapshot called 'empty'
  ./snapshot_zfs_datasets.sh empty
else
  echo "Skipping creation of 'empty' snapshot."
fi
