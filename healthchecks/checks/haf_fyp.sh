#! /bin/sh
set -e

. "$(dirname "$0")/check_haf_lib.sh"
. "$(dirname "$0")/shed_functions.sh"
. "$(dirname "$0")/check_http_sync_age.sh"

# Setup a trap to kill potentially pending healthcheck SQL query at script exit
trap "trap - 2 15 && kill -- -\$\$" 2 15

# HAF gate first (psql) — see hivemind.sh for why this precedes HTTP probes.
check_haf_lib

# NOTE haf_fyp serves /sync-status from its FastAPI overlay, not from postgrest:
# the endpoint lives in the app's own service (hive/haf_fyp!41), and its postgrest
# schema has no equivalent. So unlike the other checks here this probe does NOT
# exercise the rewriter -> postgrest path, and a wedged haf-fyp-postgrest is
# invisible to it. Adding /sync-status to haf_fyp's postgrest endpoints is the fix;
# until then this is the authoritative sync source for the app.
#
# Threshold is 360s, not the stock 60s. haf_fyp's per-block work is heavier than
# the other apps, so on a busy node it processes live blocks slightly slower than
# realtime, drifts a few minutes behind, then self-heals with a short MASSIVE
# catch-up — a legitimate oscillation of roughly seven minutes. At 60s the backend
# would flap in and out on every cycle. Up to five minutes of feed staleness is
# immaterial for a personalized feed, so the looser bound costs nothing real.
check_sync_status "haf_fyp" 360 "${HAF_FYP_HEALTH_URL:-http://haf-fyp-api:3002/sync-status}"

shed_up "${HAF_FYP_SHED_MAXCONNS:-32 8 4}"
exit 0
