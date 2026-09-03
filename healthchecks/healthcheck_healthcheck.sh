#! /bin/sh
# All agent-check listeners must be bound
netstat -tln | grep -E ':(7001|7002|7003|7004|7005|7009|7011|7013|7014|7015|7016|7017)\b' | wc -l | grep -q '^12$' || exit 1

# The shed poller must be alive and publishing (file rewritten every poll;
# stale mtime means the poller died — agent checks fail open to no shedding,
# but the container should be flagged unhealthy so someone notices)
SHED_LEVEL_FILE="${SHED_LEVEL_FILE:-/run/shed.level}"
SHED_LEVEL_MAX_AGE="${SHED_LEVEL_MAX_AGE:-30}"
mtime=$(stat -c %Y "$SHED_LEVEL_FILE" 2>/dev/null) || exit 1
[ $(( $(date +%s) - mtime )) -le "$SHED_LEVEL_MAX_AGE" ] || exit 1
exit 0
