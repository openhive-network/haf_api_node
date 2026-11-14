#!/bin/bash
# Entrypoint of the haf container (haf_base.yaml): sizes PostgreSQL's shared_buffers and
# effective_cache_size from the RAM the container may use (postgresql_memory.sh), writes them to
# haf_postgresql_conf.d/zz-memory.conf, then runs the HAF image's own entrypoint.
#
# The file is rewritten at every start, so it follows the host's RAM and POSTGRESQL_SHARED_BUFFERS_GB.
# PostgreSQL reads haf_postgresql_conf.d in file-name order and the last setting wins: "zz-memory.conf"
# sorts after pgtune.conf, zfs.conf and custom_postgres.conf, so it replaces the 16GB that older
# pgtune.conf copies in existing datadirs still carry.

set -euo pipefail

# shellcheck source=../postgresql_memory.sh
. /home/hived/haf_api_node/postgresql_memory.sh

CONF_DIR=/home/hived/datadir/haf_postgresql_conf.d
CONF_FILE="$CONF_DIR/zz-memory.conf"

total_kb=$(pg_memory_total_kb /)
shared_buffers_gb=$(pg_shared_buffers_gb "$total_kb" "${POSTGRESQL_SHARED_BUFFERS_GB:-}")
effective_cache_size_gb=$(pg_effective_cache_size_gb "$total_kb" "$shared_buffers_gb")
echo "effective_cache_size = ${effective_cache_size_gb}GB: shared_buffers + the ZFS ARC limit reduce_writebacks.sh sets"

if ! sudo -n test -d "$CONF_DIR"; then
  sudo -n mkdir -p "$CONF_DIR"
  sudo -n chown postgres:postgres "$CONF_DIR"
fi
sudo -n tee "$CONF_FILE" > /dev/null <<EOF
# Written by haf_api_node's haf/entrypoint.sh at every haf container start; edits are overwritten.
# Set POSTGRESQL_SHARED_BUFFERS_GB in .env to choose shared_buffers yourself.
shared_buffers = ${shared_buffers_gb}GB
effective_cache_size = ${effective_cache_size_gb}GB
EOF
sudo -n chown postgres:postgres "$CONF_FILE"
echo "Wrote $CONF_FILE"

exec /home/hived/docker_entrypoint.sh "$@"
