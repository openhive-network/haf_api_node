#! /bin/sh

# Single-writer load-shed poller: computes the shared shed level the agent
# check scripts read via shed_functions.sh (see checks/shed_poller.sh)
/checks/shed_poller.sh &
POLLER=$!
PIDS=$POLLER

listen() {
  nc -lk -p "$1" -e "$2" &
  PIDS="$PIDS $!"
}

listen 7001 /checks/hived.sh
listen 7002 /checks/hivemind.sh
listen 7003 /checks/hafah.sh
listen 7004 /checks/hafbe_btracker.sh
listen 7005 /checks/hafbe.sh
listen 7009 /checks/hafbe_reptracker.sh
listen 7011 /checks/hivesense.sh
listen 7013 /checks/nft_tracker.sh
listen 7014 /checks/status.sh
listen 7015 /checks/proxy_whitelist.sh
listen 7016 /checks/haf_stats.sh
listen 7017 /checks/haf_fyp.sh

# As PID 1 without docker-init, the shell would otherwise ignore SIGTERM.
# The poller only acts on TERM once its foreground sleep/psql returns, so
# signal that child too.
trap 'kill -TERM $PIDS 2>/dev/null; pkill -TERM -P "$POLLER"; wait; exit 0' TERM INT

wait
