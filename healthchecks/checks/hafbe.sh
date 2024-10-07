#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

REPTRACKER_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_REPTRACKER" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hive.blocks where num = (select hive.app_get_current_block_num('reptracker_app'))")
if [ "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$REPTRACKER_LAST_PROCESSED_BLOCK_AGE")
  echo "down #reptracker_app block over a minute old ($age_string)"
  exit 3
fi

BTRACKER_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_BTRACKER" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hive.blocks where num = (select hive.app_get_current_block_num('hafbe_bal'))")
if [ "$BTRACKER_LAST_PROCESSED_BLOCK_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$BTRACKER_LAST_PROCESSED_BLOCK_AGE")
  echo "down #hafbe_bal block over a minute old ($age_string)"
  exit 3
fi

HAFBE_LAST_PROCESSED_BLOCK_AGE=$(psql "$POSTGRES_URL_HAFBE" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hive.blocks where num = (select hive.app_get_current_block_num('hafbe_app'))")
if [ "$HAFBE_LAST_PROCESSED_BLOCK_AGE" -gt 60 ]; then
  age_string=$(format_seconds "$HAFBE_LAST_PROCESSED_BLOCK_AGE")
  echo "down #hafbe block over a minute old ($age_string)"
  exit 4
fi

echo "up"
exit 0
