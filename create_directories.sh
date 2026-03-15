#!/bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] [--data-dir=path]"
  echo "  Creates directory structure for HAF on non-ZFS filesystems"
  echo "  --env-file=filename  Use specified environment file instead of .env"
  echo "  --data-dir=path      Base directory for HAF data (overrides environment)"
}

if ! OPTIONS=$(getopt -o he:d: --long env-file:,help,data-dir: -n "$0" -- "$@"); then
    print_help
    exit 1
fi

# Don't clear if already set in environment
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT=""

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e)
      ENV_FILE="$2"
      shift 2
      ;;
    --data-dir|-d)
      TOP_LEVEL_DATASET_MOUNTPOINT="$2"
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

if [ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ]; then
  if [ -n "$ENV_FILE" ]; then
    echo "Reading $ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  elif [ -f .env ]; then
    echo "Reading configuration from .env"
    # shellcheck disable=SC1091
    . ./.env
  else
    echo "You must either provide a --data-dir argument or have a .env file"
    echo "that defines TOP_LEVEL_DATASET_MOUNTPOINT"
    exit 1
  fi
fi

# If still not set, try to construct from ZPOOL and TOP_LEVEL_DATASET
if [ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ]; then
  if [ -n "$ZPOOL" ] && [ -n "$TOP_LEVEL_DATASET" ]; then
    [ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
    TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"
  else
    echo "Unable to determine data directory. Please specify --data-dir or ensure"
    echo "your environment file contains TOP_LEVEL_DATASET_MOUNTPOINT or both"
    echo "ZPOOL and TOP_LEVEL_DATASET variables."
    exit 1
  fi
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

echo "Creating HAF directory structure (non-ZFS)"
echo "Data directory: $TOP_LEVEL_DATASET_MOUNTPOINT"
echo ""

# Create main directories
echo "Creating main directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/blockchain"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory/haf_wal"

# Create database directories
echo "Creating database directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/pgdata"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/pgdata/pg_wal"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store/tablespace"

# Create log directories
echo "Creating log directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/caddy"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/haproxy"

# Create configuration directory and copy config files
echo "Creating configuration directory..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"

if [ -f pgtune.conf ]; then
  cp pgtune.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi
if [ -f zfs.conf ]; then
  cp zfs.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi
if [ -f compression.conf ]; then
  cp compression.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi
if [ -f logging.conf ]; then
  cp logging.conf "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi

# Create hivesense directories
echo "Creating hivesense directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"

echo ""
echo "Setting permissions..."

# Run the repair_permissions script to set correct ownership
# Check in the same directory as this script first
SCRIPT_DIR="$(dirname "$0")"
if [ -f "$SCRIPT_DIR/repair_permissions.sh" ]; then
  "$SCRIPT_DIR/repair_permissions.sh" "$@"
elif [ -f ./repair_permissions.sh ]; then
  ./repair_permissions.sh "$@"
else
  echo "Warning: repair_permissions.sh not found. Setting basic permissions..."
  # Basic permission setting if repair_permissions.sh doesn't exist
  # HIVED_UID defaults to 1000, matching hived:users inside the container
  chown -R ${HIVED_UID:-1000}:${HIVED_UID:-1000} "$TOP_LEVEL_DATASET_MOUNTPOINT"
  
  # 105:109 is postgres:postgres inside the container
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
  
  # Ollama needs root:root
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama" ]; then
    chown -R 0:0 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama"
  fi
  
  # PCA and config use hived user
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca" ]; then
    chown -R ${HIVED_UID:-1000}:${HIVED_UID:-1000} "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
  fi
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config" ]; then
    chown -R ${HIVED_UID:-1000}:${HIVED_UID:-1000} "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"
  fi
fi

echo ""
echo "Directory structure created successfully!"
echo ""
echo "Note: This creates directories on your existing filesystem."
echo "For production use with better performance and snapshot capabilities,"
echo "consider using ZFS with create_zfs_datasets.sh instead."