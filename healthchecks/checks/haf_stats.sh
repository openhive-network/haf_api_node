#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API (hive/haf_stats!72), so
# this covers rewriter -> postgrest -> DB as well as the app's own block age.
#
# 60s is the value every sibling uses, and review MEASURED it here rather than
# assuming it transfers. On testapi, 98 samples over 13 minutes plus a 70-sample
# 1-second burst: p50 3s, p95 3s, max 4s, nothing above 8s. haf_stats' pointer
# advances one block every ~3s with no batching stalls, which makes it
# indistinguishable from hivemind (p50 3s, max 4s over the same window).
#
# Two caveats a future reader should have, because an earlier version of this
# comment asserted a behaviour instead of measuring one:
#
#   * The context is NON-FORKING (hive.app_context_set_non_forking in
#     db/haf_stats_app.sql), so /sync-status reports the IRREVERSIBLE block and
#     this age is LIB age plus app lag. That sounds like it leaves no headroom
#     over check_haf_lib's own 60s LIB gate three lines above -- but hivemind's
#     context is non-forking too and sits at the same block, and it has run this
#     threshold for years (1 agent DOWN in 21 days of node logs). Measured LIB
#     age here is 2-3s, so the headroom is real.
#   * The tail is thinner than the median suggests. pg_stat_statements has
#     process_block_range at max 44.2s over 1.37M calls, and pg_cron runs four
#     heavy refreshes at 03:00/03:30 UTC (refresh_top_accounts_alltime alone has
#     max 67.7s). Worst plausible reportable age is therefore ~47s -- inside 60s,
#     but only just. If a false `down` ever appears, look at 03:00-03:35 first.
#
# NOTE the threshold is hardcoded here, unlike the URL and the shed budget below.
# Every sibling hardcodes it too, so this is consistent rather than an oversight,
# but it means the 03:00 window cannot be tuned around without a code change.
#
# The agent check has NO damping -- HAProxy's `fall 3 rise 2` applies to the
# httpchk, not to the agent -- so one `down` response takes the server out
# immediately, and with a single server-template that is a 503. Recovery is one
# agent-inter tick (10s) once the condition clears.
check_sync_status "haf_stats" 60 "${HAF_STATS_HEALTH_URL:-http://haf-stats-postgrest-rewriter:80/sync-status}"

shed_up "${HAF_STATS_SHED_MAXCONNS:-32 8 4}"
exit 0
