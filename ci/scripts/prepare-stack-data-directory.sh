#!/bin/sh

set -e

HAF_MOUNTPOINT="${1:?"Please pass a valid path for the stack's data directory to this script as its first argument"}"

echo "Creating HAF's mountpoint at ${HAF_MOUNTPOINT}..."

mkdir -p "${HAF_MOUNTPOINT}/blockchain"
mkdir -p "${HAF_MOUNTPOINT}/shared_memory/haf_wal"
mkdir -p "${HAF_MOUNTPOINT}/logs/caddy"
mkdir -p "${HAF_MOUNTPOINT}/logs/pgbadger"
mkdir -p "${HAF_MOUNTPOINT}/logs/postgresql"

chown -R 1000:100 "${HAF_MOUNTPOINT}"