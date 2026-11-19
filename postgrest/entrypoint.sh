#!/bin/sh
# While the API serves, hold the app's shared HAF advisory lock, the one its block processor
# holds, so a rerun of the app's installer (which tries the exclusive lock) skips instead of
# dropping functions under the live API.  PostgREST cannot hold it itself: it reaches
# postgres through pgbouncer in transaction mode, where session locks do not survive.
#
# HAF_APP_LOCK:        the app name its installer locks (unset: no lock, plain postgrest).
# HAF_APP_LOCK_DB_URI: a direct connection to haf, not through pgbouncer.
#
# Fail-open: postgrest serves whether or not the lock is held; a lost or refused lock is
# logged and retried.  An app that HAF reports broken has its lock released, as its block
# processor does, so that the installer that repairs it is not kept out.
set -u

# Retried every few seconds, with no backoff: after a haf restart the installers rerun as
# soon as haf is healthy, so the lock must be back by then.  A failure that persists (a
# missing grant, a broken app) is logged once every WARN_SECONDS, not on each retry.
RETRY_SECONDS=5
WARN_SECONDS=300
CHECK_SECONDS=5

# Each CHECK_SECONDS: fail if HAF reports the app broken (HAF versions with
# hive._app_broken_reason only), so psql exits and the lock goes with its session.
# psql does not expand variables inside dollar quotes, hence the setting.
CHECK="DO \$\$ DECLARE reason text; BEGIN IF to_regprocedure('hive._app_broken_reason(text)') IS NOT NULL THEN EXECUTE 'SELECT hive._app_broken_reason(\$1)' INTO reason USING current_setting('haf_api_node.app_lock'); IF reason IS NOT NULL THEN RAISE EXCEPTION 'releasing the lock on %: %', current_setting('haf_api_node.app_lock'), reason; END IF; END IF; END \$\$;"

hold_app_lock() {
  # Not prefixed with the app name: hivemind takes connections named hivemind* for its own.
  export PGAPPNAME="postgrest_app_lock_${HAF_APP_LOCK}"
  export PGCONNECT_TIMEOUT=10
  warned=0
  while :; do
    since=$(date +%s)
    {
      printf '%s\n' \
        "SET statement_timeout = 0;" \
        "SELECT set_config('haf_api_node.app_lock', :'app_lock', false);" \
        "SELECT hive.acquire_app_block_processor_locks(ARRAY[:'app_lock']);" \
        "\\echo app lock: holding the shared HAF lock on :app_lock"
      # Ends on the first write after psql is gone, also where SIGPIPE is ignored.
      while sleep "$CHECK_SECONDS" && printf '%s\n' "$CHECK"; do :; done
    } | psql "$HAF_APP_LOCK_DB_URI" -X -q -w -o /dev/null -v ON_ERROR_STOP=1 -v app_lock="$HAF_APP_LOCK"
    now=$(date +%s)
    # A session that lasted held the lock, so its loss is news; a repeat failure is not.
    if [ $((now - since)) -ge 30 ] || [ $((now - warned)) -ge "$WARN_SECONDS" ]; then
      echo "app lock: WARNING: not holding the shared HAF lock on $HAF_APP_LOCK; the API keeps serving; retrying every ${RETRY_SECONDS}s" >&2
      warned=$now
    fi
    sleep "$RETRY_SECONDS"
  done
}

if [ -n "${HAF_APP_LOCK:-}" ]; then
  if [ -n "${HAF_APP_LOCK_DB_URI:-}" ]; then
    hold_app_lock &
  else
    echo "app lock: WARNING: HAF_APP_LOCK=$HAF_APP_LOCK without HAF_APP_LOCK_DB_URI; not holding it" >&2
  fi
fi

exec "$@"
