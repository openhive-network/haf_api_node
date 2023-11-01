#! /bin/sh

# Setup a trap to kill potentially pending wget at script exit
trap "trap - SIGINT SIGTERM && kill -- -\$\$" SIGINT SIGTERM
WGET_RESULT=$(wget -q -O - --post-data '{"jsonrpc": "2.0", "id": 1, "method": "node_status_api.get_node_status", "params": {}}' http://haf:8091/)
if [ $? -ne 0 ]; then
  echo "down #wget returned an error"
  exit 1
fi

if echo "$WGET_RESULT" | grep -q '"error":'; then
  echo "down #get_node_status() call returned an error"
  exit 2
fi

HIVED_HEAD_BLOCK_TIME_STRING=$(echo "$WGET_RESULT" | sed 's/^.*"last_processed_block_time":"\([^"]*\)".*/\1/g')
HIVED_HEAD_BLOCK_TIME_EPOCH=$(date +%s -d $(echo $HIVED_HEAD_BLOCK_TIME_STRING | tr -- -T .-))
CURRENT_TIME_EPOCH=$(date +%s)
HEAD_BLOCK_AGE_SEC=$(expr $CURRENT_TIME_EPOCH - $HIVED_HEAD_BLOCK_TIME_EPOCH)
if [ $HEAD_BLOCK_AGE_SEC -gt 15 ]; then
  echo "down #head block too old (age: ${HEAD_BLOCK_AGE_SEC}s"
  exit 1
fi

echo "up"
exit 0
