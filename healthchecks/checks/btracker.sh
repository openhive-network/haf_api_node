#! /bin/sh
set -e
# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - SIGINT SIGTERM && kill -- -\$\$" SIGINT SIGTERM
if [ $(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_instance_ready();") = f ]; then
  echo "down #HAF not in sync"
  exit 1
fi
LAST_IRREVERSIBLE_BLOCK=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT irreversible_block FROM hive.contexts WHERE name = 'btracker_app'")
if [ -z "$LAST_IRREVERSIBLE_BLOCK" ]; then
  echo "down #No LIB"
  exit 2
fi
if [ "$LAST_IRREVERSIBLE_BLOCK" -eq 0 ]; then
  echo "down #LIB is zero"
  exit 3
fi
LAST_PROCESSED_BLOCK=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT last_processed_block FROM btracker_app.app_status")
if [ -z "$LAST_PROCESSED_BLOCK" ]; then
  echo "down #no last processed block"
  exit 4
fi
if [ "$LAST_PROCESSED_BLOCK" -lt "$LAST_IRREVERSIBLE_BLOCK" ]; then
  echo "down #stale data, last processed: $LAST_PROCESSED_BLOCK, lib: $LAST_IRREVERSIBLE_BLOCK"
  exit 5
fi

echo "up"
exit 0
