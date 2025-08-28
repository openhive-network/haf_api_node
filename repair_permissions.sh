#!/bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename]"
  echo "  Repairs ownership and permissions for all HAF directories"
  echo "  --env-file=filename  Use specified environment file instead of .env"
}

if ! OPTIONS=$(getopt -o he: --long env-file:,help,zpool:,top-level-dataset: -n "$0" -- "$@"); then
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

if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
  if [ -n "$ENV_FILE" ]; then
    echo "Reading $ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  elif [ -f .env ]; then
    echo "Reading configuration from .env"
    # shellcheck disable=SC1091
    . ./.env
  else
    echo "You must either provide an --env-file argument or both a --zpool and --top-level-dataset"
    echo "argument to tell this script where to repair permissions."
    exit 1
  fi
fi

if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
  echo "Your environment file must define the ZPOOL and TOP_LEVEL_DATASET environment variables"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

[ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"

echo "Repairing permissions for HAF directories"
echo "Top-level dataset: $TOP_LEVEL_DATASET"
echo "  mounted on:      $TOP_LEVEL_DATASET_MOUNTPOINT"
echo ""

# Default ownership for most directories
# 1000:100 is hived:users inside the container
echo "Setting ownership for general HAF directories..."
chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT"

# PostgreSQL-specific ownership
# 105:109 is postgres:postgres inside the container
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store" ]; then
  echo "Setting ownership for PostgreSQL directories..."
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"
fi

# PostgreSQL configuration directory
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d" ]; then
  echo "Setting ownership for PostgreSQL configuration..."
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi

# Log directories with specific ownership
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs" ]; then
  echo "Setting ownership for log directories..."
  chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs"
  
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql" ]; then
    chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
  fi
  
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger" ]; then
    chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
  fi
fi

# Hivesense directories (if they exist)
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense" ]; then
  echo "Setting ownership for hivesense directories..."
  
  # Ollama needs root:root as it runs as root by default
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama" ]; then
    echo "  Setting ollama directory to root:root..."
    chown -R 0:0 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama"
  fi
  
  # PCA and config directories use standard hived user
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca" ]; then
    echo "  Setting pca directory to hived user..."
    chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
  fi
  
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config" ]; then
    echo "  Setting config directory to hived user..."
    chown -R 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"
  fi
  
  # Set the parent directory
  chown 1000:100 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense"
fi

echo "Permission repair complete!"