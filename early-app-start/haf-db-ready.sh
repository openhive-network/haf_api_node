#!/bin/bash
# Exits once the HAF database can take app installs and block processing while
# hived may still be replaying: PostgreSQL accepts connections, the
# hive_fork_manager extension is installed, hafd.events_queue has a row and
# hived holds a session to the database.
#
# hived's session is checked because on a restart of an existing database the
# queue already has rows, yet the HAF entrypoint restarts PostgreSQL (to load
# pg_cron) just before it starts hived.  hived connects over the Unix socket
# without an application_name, as the same role as other local clients, so
# that is what identifies it; psql and pg_cron set an application_name.
#
# As a fallback it also exits once hived's API answers, the point at which the
# default stack starts the apps, so the gate never holds them back longer.
#
# Connection settings come from the libpq environment (PGHOST, PGUSER, ...);
# HIVED_HTTP_URL is hived's HTTP endpoint.
set -euo pipefail

INTERVAL="${HAF_DB_READY_INTERVAL:-10}"
HIVED_HTTP_URL="${HIVED_HTTP_URL:-http://haf:8091/}"

query() {
    psql --no-psqlrc --quiet --tuples-only --no-align --command "$1" 2>/dev/null
}

database_ready() {
    [ "$(query "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hive_fork_manager')")" = t ] &&
        [ "$(query "SELECT EXISTS (SELECT 1 FROM hafd.events_queue)")" = t ] &&
        [ "$(query "SELECT EXISTS (SELECT 1 FROM pg_stat_activity
                                   WHERE datname = current_database()
                                     AND backend_type = 'client backend'
                                     AND client_addr IS NULL
                                     AND application_name = ''
                                     AND pid <> pg_backend_pid())")" = t ]
}

hived_api_answers() {
    wget -T2 -nv -t1 --spider "${HIVED_HTTP_URL}" > /dev/null 2>&1
}

until database_ready; do
    if hived_api_answers; then
        echo "hived's API answers; not waiting for the database checks any longer"
        exit 0
    fi
    echo "Waiting for the HAF database (extension installed, events queue written, hived connected)..."
    sleep "${INTERVAL}"
done
echo "HAF database is ready for app installs and block processing"
