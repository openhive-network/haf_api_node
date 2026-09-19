#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# Full-path sync check via the uniform /sync-status API, so this covers
# rewriter -> postgrest -> DB as well as the app's own block age.
#
# 60s, THE SIBLING VALUE, AND NOT THE 360 THIS APP HAS RUN WITH -- read this before
# changing it back. hive/haf_fyp#29 files the number under a heading that reads "do not
# copy the number across", and says beneath it that 360 was "tuned to 360s for this app's
# drift-and-catch-up cycle". (Quoted as two pieces on purpose: an earlier version of this
# comment ran them together with an ellipsis, in the reverse of the order they appear in.)
# The node that runs
# haf_fyp today has used 360 for months. That instruction was right to demand a
# measurement rather than a copied constant; the measurement does not support the number.
#
# Measured on that node, 2026-09-19: block age sampled directly, 66 samples across two
# windows -- p50 2s, p95 3s, max 4s. An independent re-sample the next day (40 psql
# samples at 2s plus 15 over HTTP) came back p50 2s, p95 3s, max 6s. Both are a single
# day's tail rather than a bound -- which is the point: 60s clears either by two orders
# of magnitude, and it is the distance that carries the argument, not the maximum.
# The psql quantity
# (get_app_current_block_age) and this HTTP one (age of /sync-status' last_block_time)
# agree to within a second. So haf_fyp tracks the tip at roughly one block every 3s,
# indistinguishable from haf_stats (p50 3s, max 4s) and hivemind, both of which have run
# 60s for years.
#
# TWO THINGS THAT LOOK LIKE CORROBORATION AND ARE NOT, recorded so nobody re-derives
# them:
#
#   * The sync container's log cadence. An earlier version of this comment offered
#     "171,003 log lines over 48h, largest gap 2.0s" as proof there is no catch-up
#     cycle. Every one of those lines is the same "HAF instance is ready" NOTICE, at a
#     ~1.5s cadence -- FASTER than the 3s block interval, because it is a poll, not a
#     per-block record. It ticks whether or not the chain advances, which is the exact
#     distinction haf_fyp's own block-processing-healthcheck.sh draws: the heartbeat
#     proves the loop is ITERATING, not ADVANCING. An unbroken cadence is therefore
#     consistent with a completely stalled app, and proves nothing about drift.
#   * HAProxy's logs. That node's read path goes straight to the rewriter, bypassing
#     HAProxy entirely, so HAProxy has never consumed an agent verdict for this app and
#     "no agent transition in 7 days" says nothing about drift. The check itself does
#     run there, on 7017, and the status page reads it for TWO rows (that node labels
#     both its rewriter and its write API with healthcheck.port 7017) -- so 360 has been
#     load-bearing for those rows, just never for routing. This is the first HAProxy
#     agent-check for haf_fyp, not the first agent-check.
#
# WHAT WOULD JUSTIFY RAISING IT AGAIN, since the earlier number came from somewhere:
# the app's ranker does run in cycles, and a node that puts the ranker and block
# processing under the same contended CPU could plausibly stall the loop in a way this
# node does not. If a false `down` appears, SAMPLE THE AGE -- /sync-status'
# last_block_time, or get_app_current_block_age over psql -- rather than the container's
# log cadence, for the reason directly above. A raised threshold that is not measured
# just moves the blind spot.
#
# The agent check has NO damping -- HAProxy's `fall 3 rise 2` applies to the httpchk,
# not to the agent -- so one `down` response takes the server out immediately, and with
# a single server-template that is a 503. Recovery is one agent-inter tick (10s) once
# the condition clears. That asymmetry is why the threshold wants evidence in both
# directions: too low costs availability, too high hides staleness.
check_sync_status "haf_fyp" 60 "${HAF_FYP_HEALTH_URL:-http://haf-fyp-postgrest-rewriter:80/sync-status}"

shed_up "${HAF_FYP_SHED_MAXCONNS:-32 8 4}"
exit 0
