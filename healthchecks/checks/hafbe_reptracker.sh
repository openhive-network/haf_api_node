#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

REPTRACKER_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_REPTRACKER" --quiet --no-align --tuples-only --command="select extract('epoch' from hive.get_app_current_block_age('reptracker_app'))::integer")
# Adjust age for CI environments (TIME_OFFSET is set by check_haf_lib)
REPTRACKER_ADJUSTED_AGE=$(adjust_age_for_ci "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE")
if [ "$REPTRACKER_ADJUSTED_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE")
  if [ "$TIME_OFFSET" -gt 0 ]; then
    echo "down #hafbe_rep block over a minute old ($age_string, adjusted from CI offset)"
  else
    echo "down #hafbe_rep block over a minute old ($age_string)"
  fi
  exit 3
fi

echo "up"
exit 0
