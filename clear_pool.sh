#brain dead script that needs improvement, but useful for me
. ./.env
sudo rm -rf ${HAF_LOG_DIRECTORY}/postgresql/*
sudo rm -rf ${HAF_DATA_DIRECTORY}/haf_db_store/*
rm -rf ${HAF_SHM_DIRECTORY}/shared_memory.bin ${HAF_SHM_DIRECTORY}/haf_wal/*
