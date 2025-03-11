#!/bin/sh

sudo rm -rf /storage_nvme/hivesense-pool/*
mkdir -p /storage_nvme/hivesense-pool/haf-datadir/shared_memory/haf_wal
mkdir -p /storage_nvme/hivesense-pool/haf-datadir/logs/postgresql
mkdir -p /storage_nvme/hivesense-pool/haf-datadir/blockchain
mkdir -p /storage_nvme/hivesense-pool/haf-datadir/logs/pgbadger
mkdir -p /storage_nvme/hivesense-pool/haf-datadir/logs/caddy
cp /storage_nvme/blocks/block_log_5m/* /storage_nvme/hivesense-pool/haf-datadir/blockchain/

