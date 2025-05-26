#brain dead script that needs improvement, but useful for me
. ./.env
sudo rm -rf ${HAF_LOG_DIRECTORY:-${TOP_LEVEL_DATASET_MOUNTPOINT}/logs}/postgresql/*
sudo rm -rf ${HAF_DATA_DIRECTORY:-${TOP_LEVEL_DATASET_MOUNTPOINT}}/haf_db_store/*
rm -rf ${HAF_SHM_DIRECTORY:-${TOP_LEVEL_DATASET_MOUNTPOINT}/state/shared_memory}/shared_memory.bin ${HAF_WAL_DIRECTORY:-${TOP_LEVEL_DATASET_MOUNTPOINT}/state/haf_wal}/* ${TOP_LEVEL_DATASET_MOUNTPOINT}/state/rocksdb/*
