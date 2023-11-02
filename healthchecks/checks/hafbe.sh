#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

check_haf_lib

APP_IN_SYNC=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_app_in_sync(ARRAY['hafbe_app', 'btracker_app']);")
if [ "$APP_IN_SYNC" = "f" ]; then
  echo "down #app not in sync"
  exit 3
fi

echo "up"
exit 0
