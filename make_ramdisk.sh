#another braindead script for me
sudo mkdir -p /mnt/haf_shared_mem
sudo mount -t tmpfs -o size=8G ramfs /mnt/haf_shared_mem
sudo chmod 777 /mnt/haf_shared_mem
