#! /bin/sh

. "$(dirname "$0")/format_seconds.sh"

# Setup a trap to kill potentially pending wget at script exit
trap "trap - 2 15 && kill -- -\$\$ && wait" 2 15


if ! WGET_RESULT=$(wget -q --timeout=15 -O - --post-data '{"jsonrpc": "2.0", "id": 1, "method": "node_status_api.get_node_status", "params": {}}' http://${HIVED_HOSTNAME:-haf}:8091/); then
  echo "down #wget returned an error"
  exit 1
fi

if echo "$WGET_RESULT" | grep -q '"error":'; then
  echo "down #get_node_status() call returned an error"
  exit 2
fi

HIVED_HEAD_BLOCK_TIME_STRING=$(echo "$WGET_RESULT" | sed 's/^.*"last_processed_block_time":"\([^"]*\)".*/\1/g')
HIVED_HEAD_BLOCK_TIME_EPOCH=$(date +%s -d "$(echo "$HIVED_HEAD_BLOCK_TIME_STRING" | tr -- -T .-)")
CURRENT_TIME_EPOCH=$(date +%s)
HEAD_BLOCK_AGE_SEC=$((CURRENT_TIME_EPOCH - HIVED_HEAD_BLOCK_TIME_EPOCH))
if [ $HEAD_BLOCK_AGE_SEC -gt 15 ]; then
  age_string=$(format_seconds $HEAD_BLOCK_AGE_SEC)
  echo "down #head block too old (age: $age_string)"
  exit 3
fi

echo "up"
exit 0
