sudo sysctl -w vm.dirty_bytes=12000000000 #12GB
sudo sysctl -w vm.dirty_background_bytes=5000000000 #5GB
sudo sysctl -w vm.dirty_expire_centisecs=300000 #400000 #default 3000 #default causes too much writing
sudo sysctl -w vm.dirty_writeback_centisecs=50000 #500 #360000 #default 500
sudo sysctl -w vm.swappiness=0 #a swappiness of zero is not sufficient to prevent writeback of dirty pages
