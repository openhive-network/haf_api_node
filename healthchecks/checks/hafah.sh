#! /bin/sh
set -e
# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - SIGINT SIGTERM && kill -- -\$\$" SIGINT SIGTERM
if [ $(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_instance_ready();") = f ]; then
  echo "down #HAF not in sync"
  exit 1
fi
LAST_IRREVERSIBLE_BLOCK_AGE=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hive.blocks where num = (select consistent_block from hive.irreversible_data)")
if [ "$LAST_IRREVERSIBLE_BLOCK_AGE" -gt 60 ]; then
  echo "down #LIB over a minute old ($LAST_IRREVERSIBLE_BLOCK_AGE sec)"
  exit 2
fi

echo "up"
exit 0
