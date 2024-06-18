#!/bin/sh

set -e

/haf-api-node/prepare-stack-data-directory.sh "${TOP_LEVEL_DATASET_MOUNTPOINT}"

# If PostgreSQL data directory already exists, reset its permissions
[ -d "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store"  ] && chown -R 105:109 "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_db_store"
[ -d "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_postgresql_conf.d"  ] && chown -R 105:109 "${TOP_LEVEL_DATASET_MOUNTPOINT}/haf_postgresql_conf.d"

echo "Starting dockerd..."

exec dockerd-entrypoint.sh "$@"