#! /bin/sh
# All agent-check listeners must be bound
# `-ge`, not an exact count. develop made this shellcheck-clean in 9068fb6 and kept
# the exact form (`-eq 10`); this MR adds 7016, and the haf_fyp check on 7017 that it
# reserves would force yet another bump. A container binding MORE listeners than the
# assertion expects then reports unhealthy for no reason -- testapi runs a 12-listener
# build of this image today for exactly that reason. What the check is for is catching
# a listener that FAILED to bind, so a floor is the right comparison.
[ "$(netstat -tln | grep -cE ':(7001|7002|7003|7004|7005|7009|7011|7013|7014|7015|7016)\b')" -ge 11 ] || exit 1

# The shed poller must be alive and publishing (file rewritten every poll;
# stale mtime means the poller died — agent checks fail open to no shedding,
# but the container should be flagged unhealthy so someone notices)
SHED_LEVEL_FILE="${SHED_LEVEL_FILE:-/run/shed.level}"
SHED_LEVEL_MAX_AGE="${SHED_LEVEL_MAX_AGE:-30}"
mtime=$(stat -c %Y "$SHED_LEVEL_FILE" 2>/dev/null) || exit 1
[ $(( $(date +%s) - mtime )) -le "$SHED_LEVEL_MAX_AGE" ] || exit 1
exit 0
