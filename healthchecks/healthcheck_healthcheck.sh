#! /bin/sh
# All agent-check listeners must be bound
# `-ge`, not an exact count (develop's 9068fb6 had `-eq 10`; 7016, haf_stats, was added
# since). netstat prints one line per listening SOCKET -- one per port here, since each
# check binds a single dual-stack socket -- and only the ports listed below match. So
# while the number equals the length of the list the two forms behave the same: both fail
# when a listed port did not bind, and neither sees a listener outside the list (testapi
# serves 7016 and 7017 from bind-mounted checks and stays healthy under the stock 10-port
# `^10$`). Where they differ: a port bound v4 and v6 separately prints two lines, which
# the floor tolerates and an exact count would not. When adding a port, raise the number
# with it -- a floor lower than the list passes with a listener missing.
[ "$(netstat -tln | grep -cE ':(7001|7002|7003|7004|7005|7009|7011|7013|7014|7015|7016)\b')" -ge 11 ] || exit 1

# The shed poller must be alive and publishing (file rewritten every poll;
# stale mtime means the poller died — agent checks fail open to no shedding,
# but the container should be flagged unhealthy so someone notices)
SHED_LEVEL_FILE="${SHED_LEVEL_FILE:-/run/shed.level}"
SHED_LEVEL_MAX_AGE="${SHED_LEVEL_MAX_AGE:-30}"
mtime=$(stat -c %Y "$SHED_LEVEL_FILE" 2>/dev/null) || exit 1
[ $(( $(date +%s) - mtime )) -le "$SHED_LEVEL_MAX_AGE" ] || exit 1
exit 0
