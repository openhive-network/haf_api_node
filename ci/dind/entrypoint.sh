#!/bin/sh

set -e

echo "Creating HAF's mountpoint at ${TOP_LEVEL_DATASET_MOUNTPOINT}..."

mkdir -p "${TOP_LEVEL_DATASET_MOUNTPOINT}/blockchain"
mkdir -p "${TOP_LEVEL_DATASET_MOUNTPOINT}/shared_memory/haf_wal"
mkdir -p "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/caddy"
mkdir -p "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/pgbadger"
mkdir -p "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/postgresql"

chown -R 1000:100 "${TOP_LEVEL_DATASET_MOUNTPOINT}"
# If PostgreSQL data directory already exists, reset its permissions
[ -d "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store"  ] && chown -R 105:109 "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store"
[ -d "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_postgresql_conf.d"  ] && chown -R 105:109 "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_postgresql_conf.d"

echo "Starting dockerd..."

exec dockerd-entrypoint.sh "$@"