#!/bin/sh

set -e

# Use create_directories.sh to set up the directory structure
# This also calls repair_permissions.sh to set proper ownership
/haf-api-node/create_directories.sh --data-dir="${TOP_LEVEL_DATASET_MOUNTPOINT}"

echo "Starting dockerd..."

exec dockerd-entrypoint.sh "$@"