#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

LAST_IRREVERSIBLE_BLOCK=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT irreversible_block FROM hive.contexts WHERE name = 'btracker_app'")
if [ -z "$LAST_IRREVERSIBLE_BLOCK" ]; then
  echo "down #No btracker LIB"
  exit 3
fi
if [ "$LAST_IRREVERSIBLE_BLOCK" -eq 0 ]; then
  echo "down #btracker LIB is zero"
  exit 4
fi
LAST_PROCESSED_BLOCK=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT last_processed_block FROM btracker_app.app_status")
if [ -z "$LAST_PROCESSED_BLOCK" ]; then
  echo "down #no btracker last processed block"
  exit 5
fi
if [ "$LAST_PROCESSED_BLOCK" -lt "$LAST_IRREVERSIBLE_BLOCK" ]; then
  echo "down #stale data, last processed: $LAST_PROCESSED_BLOCK, lib: $LAST_IRREVERSIBLE_BLOCK"
  exit 6
fi

echo "up"
exit 0
