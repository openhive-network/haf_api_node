#!/usr/bin/env bash
#
# Test hivemind-install's entrypoint (install_lock/hivemind_install.sh): an install that exits 0
# while the database is behind the image's revision fails, naming the lock holder and the
# recovery.  Runs the wrapper in the hivemind image (its python, hive.version and psql) with the
# image's docker_entrypoint.sh replaced by a stub that either skips as images without
# hivemind#456 do (HAF's lock NOTICE, exit 0), installs (records the image's revision in
# hivemind_app.hive_state, as every hivemind install that runs does), or fails; against a
# PostgreSQL holding hivemind_app.hive_state.
# Checks: a skipped upgrade exits 1 with both revisions, the holder and the recovery; a skipped
# rerun of the installed revision, and an install that ran, exit 0; a failed install keeps its
# exit code; a skip on a database without hivemind's schema exits 1.  Also checks that
# hivemind.yaml's hivemind-install runs the wrapper.
# Needs a docker daemon; skips (exit 0) with the reason when there is none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
POSTGRES_IMAGE=${POSTGRES_IMAGE:-postgres:18}
# A hivemind image without hivemind#456: its install skips a locked-out upgrade with exit 0.
HIVEMIND_IMAGE=${HIVEMIND_IMAGE:-registry.hive.blog/hivemind:1.28.8}
OLD_REVISION=0000000000000000000000000000000000000000
SKIP_NOTICE='NOTICE:  Skipping install: lock on hivemind held by postgrest_app_lock_hivemind (pid=4242)'

skip() {
  echo "SKIP hivemind-install-check: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  exit 1
}

if ! grep -q '^      - /usr/local/lib/haf_api_node/hivemind_install.sh$' "$REPO_DIR/hivemind.yaml" ||
  ! grep -q 'source: ./install_lock/hivemind_install.sh$' "$REPO_DIR/hivemind.yaml"; then
  fail "hivemind.yaml's hivemind-install does not run install_lock/hivemind_install.sh"
fi
echo "ok    hivemind-install runs install_lock/hivemind_install.sh"

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"

NAME=hivemind-install-check-$$
IMAGE=haf-api-node-hivemind-install:check-$$
WORK=$(mktemp -d)
DB_URL=postgresql://postgres@$NAME-db/postgres

cleanup() {
  docker rm -f "$NAME-db" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

######### Image #########

# Copied, not mounted: the docker daemon may not see this host's files.
cat > "$WORK/docker_entrypoint.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub entrypoint: \$*"
case "\$STUB_MODE" in
  skip)
    echo '$SKIP_NOTICE'
    echo "Skipping hivemind schema install (see NOTICE above)." ;;
  install)
    rev=\$(/home/hivemind/.hivemind-venv/bin/python3 -c 'from hive.version import GIT_REVISION; print(GIT_REVISION)')
    psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c "UPDATE hivemind_app.hive_state SET hivemind_git_rev = '\$rev'" ;;
  fail)
    exit 3 ;;
esac
EOF
cp "$REPO_DIR/install_lock/hivemind_install.sh" "$WORK/"
cat > "$WORK/Dockerfile" <<'EOF'
ARG BASE
FROM ${BASE}
COPY --chmod=0755 docker_entrypoint.sh /home/hivemind/docker_entrypoint.sh
COPY --chmod=0755 hivemind_install.sh /usr/local/lib/haf_api_node/hivemind_install.sh
EOF
docker build -q --build-arg BASE="$HIVEMIND_IMAGE" -t "$IMAGE" "$WORK" >"$WORK/build.log" 2>&1 ||
  fail "image build failed: $(tail -5 "$WORK/build.log")"
IMAGE_REVISION=$(docker run --rm --entrypoint /home/hivemind/.hivemind-venv/bin/python3 "$IMAGE" \
  -c 'from hive.version import GIT_REVISION; print(GIT_REVISION)')

######### Database #########

docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-db" --network "$NAME" -e POSTGRES_HOST_AUTH_METHOD=trust "$POSTGRES_IMAGE" >/dev/null
for _ in $(seq 60); do
  docker exec "$NAME-db" pg_isready -q -U postgres 2>/dev/null && break
  sleep 1
done

db() {
  docker exec "$NAME-db" psql -U postgres -X -q -v ON_ERROR_STOP=1 -c "$1" >/dev/null
}

set_installed_revision() {
  db "CREATE SCHEMA IF NOT EXISTS hivemind_app;
      CREATE TABLE IF NOT EXISTS hivemind_app.hive_state (hivemind_git_rev text);
      TRUNCATE hivemind_app.hive_state;
      INSERT INTO hivemind_app.hive_state VALUES ('$1');"
}

# install MODE: runs the wrapper as hivemind.yaml does; sets RC and leaves its output in $WORK/out.
install() {
  RC=0
  docker run --rm --network "$NAME" -e STUB_MODE="$1" --entrypoint /usr/local/lib/haf_api_node/hivemind_install.sh \
    "$IMAGE" setup --upgrade-schema --database-admin-url="$DB_URL" >"$WORK/out" 2>&1 || RC=$?
}

expect_rc() {
  [ "$RC" -eq "$1" ] || fail "$2: exit $RC, not $1: $(tail -5 "$WORK/out")"
}

expect_log() {
  grep -qF -- "$1" "$WORK/out" || fail "$2: the log lacks '$1': $(tail -5 "$WORK/out")"
}

######### Checks #########

set_installed_revision "$OLD_REVISION"
install skip
expect_rc 1 "a skipped upgrade"
expect_log "Cannot install hivemind revision $IMAGE_REVISION" "a skipped upgrade"
expect_log "the database is at revision $OLD_REVISION" "a skipped upgrade"
expect_log "$SKIP_NOTICE" "a skipped upgrade"
expect_log "stop hivemind-postgrest-server (postgrest_app_lock_hivemind)" "a skipped upgrade"
echo "ok    a skipped upgrade exits 1, naming both revisions, the holder and the recovery"

install install
expect_rc 0 "the recovery's install"
echo "ok    an install that runs exits 0"

install skip
expect_rc 0 "a skipped rerun of the installed revision"
echo "ok    a skipped rerun of the installed revision exits 0"

install fail
expect_rc 3 "a failed install"
echo "ok    a failed install keeps its exit code"

db "DROP SCHEMA hivemind_app CASCADE"
install skip
expect_rc 1 "a skip without hivemind's schema"
expect_log "the database is at revision unreadable" "a skip without hivemind's schema"
echo "ok    a skip on a database without hivemind's schema exits 1"

echo "PASS hivemind-install-check"
