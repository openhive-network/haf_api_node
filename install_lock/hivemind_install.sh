#!/bin/bash
# hivemind-install's entrypoint: runs the hivemind image's own entrypoint, then fails a run
# that exited 0 without bringing the database to this image's revision.
#
# hivemind's installer skips when another session holds the hivemind lock (hivemind-postgrest-
# server always does while it serves).  Images without hivemind#456 skip with exit 0 even when
# the skip leaves an upgrade pending, and hivemind-block-processing then starts the new code on
# the old schema and crash-loops.  Every install that runs records the image's revision in
# hivemind_app.hive_state.hivemind_git_rev (a fresh one seeds it, an existing one updates it),
# so a mismatch after exit 0 means the install did not run.
#
# Arguments: as for the image's entrypoint; --database-admin-url names the database checked.
set -euo pipefail

ENTRYPOINT=/home/hivemind/docker_entrypoint.sh
HIVE_PYTHON=/home/hivemind/.hivemind-venv/bin/python3
SKIP_LINE='Skipping install: lock on hivemind held by'

ADMIN_URL=""
for arg in "$@"; do
  case "$arg" in
    --database-admin-url=*) ADMIN_URL="${arg#*=}" ;;
  esac
done
if [ -z "$ADMIN_URL" ]; then
  echo "hivemind install check: no --database-admin-url argument" >&2
  exit 2
fi

OUTPUT=$(mktemp)
ERRORS=$(mktemp)
trap 'rm -f "$OUTPUT" "$ERRORS"' EXIT

"$ENTRYPOINT" "$@" 2>&1 | tee "$OUTPUT"

IMAGE_REVISION=$("$HIVE_PYTHON" -c 'from hive.version import GIT_REVISION; print(GIT_REVISION)')
# stderr apart: the image's psql wrapper may print locale warnings there.
if INSTALLED_REVISION=$(psql "$ADMIN_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
    -c "SELECT hivemind_git_rev FROM hivemind_app.hive_state" 2>"$ERRORS"); then
  [ "$INSTALLED_REVISION" != "$IMAGE_REVISION" ] || exit 0
else
  INSTALLED_REVISION="unreadable ($(grep -m1 '^psql' "$ERRORS" || tail -1 "$ERRORS"))"
fi

# The holders each skip NOTICE names after "held by", on one line.  The NOTICE text is
# hive_fork_manager's, so a line naming none is kept, less its "NOTICE:" prefix.
HOLDERS=""
while IFS= read -r line; do
  holder=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${line#*"$SKIP_LINE"}")
  [ -n "$holder" ] || holder=$(sed -E 's/^[[:space:]]*NOTICE:[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")
  HOLDERS="${HOLDERS:+$HOLDERS, }$holder"
done < <(grep -F "$SKIP_LINE" "$OUTPUT" || true)
HELD_BY="The install did not report a lock holder."
[ -z "$HOLDERS" ] || HELD_BY="The lock on hivemind is held by $HOLDERS."
echo "Cannot install hivemind revision $IMAGE_REVISION: the install exited 0, but the database is at revision $INSTALLED_REVISION." \
  "$HELD_BY" \
  "To upgrade: stop hivemind-postgrest-server (postgrest_app_lock_hivemind), hivemind-postgrest-rewriter" \
  "and any other holder named above (haf-fyp-block-processing, hivesense-sync), then run docker compose up -d." >&2
exit 1
