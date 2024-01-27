#brain dead script that needs improvement, but useful for me
. ./.env
sudo rm -rf ${HAF_LOG_DIRECTORY}/postgresql/*
sudo rm -rf ${HAF_DATA_DIRECTORY}/haf_db_store/*
rm -rf ${HAF_DATA_DIRECTORY}/blockchain/haf_wal/*
rm ${HAF_SHM_DIRECTORY}/shared_memory.bin
