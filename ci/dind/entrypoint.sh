#!/bin/sh

set -e

# Use create_directories.sh to set up the directory structure
# This also calls repair_permissions.sh to set proper ownership
# Export the variable so create_directories.sh can read it from environment
export TOP_LEVEL_DATASET_MOUNTPOINT="${TOP_LEVEL_DATASET_MOUNTPOINT}"
/haf-api-node/create_directories.sh

echo "Starting dockerd..."

exec dockerd-entrypoint.sh "$@"