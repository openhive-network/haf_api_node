#! /bin/sh
set -e
# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - SIGINT SIGTERM && kill -- -\$\$" SIGINT SIGTERM
if [ $(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_instance_ready();") = f ]; then
  echo "down #HAF not in sync"
  exit 1
fi

APP_IN_SYNC=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_app_in_sync('hivemind_app');")
if [ $APP_IN_SYNC = "f" ]; then
  echo "down #app not in sync"
  exit 2
fi

echo "up"
exit 0
