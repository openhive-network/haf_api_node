# shellcheck shell=sh
# The ZFS dataset layout of a HAF datadir, sourced by create_zfs_datasets.sh (which creates it)
# and repair_permissions.sh (which checks a datadir against it).
#
# zfs_dataset_layout prints one line per dataset, parents before children:
#   <dataset relative to $ZPOOL/$TOP_LEVEL_DATASET, "." for the top level> <required|optional> <property=value>...
# Optional datasets are created like the others but are not reported when absent.

zfs_dataset_layout() {
  echo ". required atime=off compression=lz4"

  # uncompressed: blocks in the block_log are already compressed by hived
  echo "blockchain required atime=off compression=off"

  # uncompressed, for the shared_memory.bin file and WAL.
  # AFAIK we haven't done studies on whether compression helps shared_memory.bin.
  echo "shared_memory required atime=off compression=off"

  # an unmountable dataset to serve as the parent for pgdata & tablespaces
  echo "haf_db_store required atime=off compression=lz4 canmount=off"

  # several sites recommend 8k blocks for optimizing postgres on zfs, but we have found that it
  # kills compression ratios for haf_block_log, so the PostgreSQL datasets keep the default 128k
  # recordsize (consider also recordsize=16k, logbias=throughput)

  # everything in PostgreSQL except for HAF (system tables and the like).  Having this directory
  # uncompressed improved performance in tests, and it's not very big
  echo "haf_db_store/pgdata required atime=off compression=off canmount=on"

  # the write-ahead logs, simply to reduce the size of snapshots of other datasets
  echo "haf_db_store/pgdata/pg_wal required atime=off compression=off canmount=on"

  # the main HAF database itself
  echo "haf_db_store/tablespace required atime=off compression=lz4 canmount=on"

  # logs (hived and postgresql, for now)
  echo "logs required atime=off compression=lz4 canmount=on"

  # parent for hivesense components (compressed for config files), only used with hivesense
  echo "hivesense optional atime=off compression=lz4 canmount=on"

  # ollama models are already compressed, so no ZFS compression
  echo "hivesense/ollama optional atime=off compression=off canmount=on"
}
