#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

BTRACKER_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_BTRACKER" --quiet --no-align --tuples-only --command="select extract('epoch' from hive.get_app_current_block_age('hafbe_bal'))::integer")
if [ "$BTRACKER_LAST_PROCESSED_BLOCK_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$BTRACKER_LAST_PROCESSED_BLOCK_AGE")
  echo "down #hafbe_bal block over a minute old ($age_string)"
  exit 3
fi

echo "up"
exit 0
