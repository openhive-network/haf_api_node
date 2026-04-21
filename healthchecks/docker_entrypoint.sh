#! /bin/sh

nc -lk -p 7001 -e /checks/hived.sh &
nc -lk -p 7002 -e /checks/hivemind.sh &
nc -lk -p 7003 -e /checks/hafah.sh &
nc -lk -p 7004 -e /checks/hafbe_btracker.sh &
nc -lk -p 7005 -e /checks/hafbe.sh &
nc -lk -p 7009 -e /checks/hafbe_reptracker.sh &
nc -lk -p 7011 -e /checks/hivesense.sh &
nc -lk -p 7013 -e /checks/nft_tracker.sh &
nc -lk -p 7014 -e /checks/status.sh &
nc -lk -p 7015 -e /checks/proxy_whitelist.sh &

wait
