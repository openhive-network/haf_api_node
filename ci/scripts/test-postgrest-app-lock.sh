#!/usr/bin/env bash
#
# Test that an app's PostgREST holds the app's shared HAF lock while it serves, so a rerun of the
# app's install skips, while an upgraded install runs or fails visibly.  Brings up nft_tracker's
# install and PostgREST from the stack's own nft_tracker.yaml, keeping their depends_on and
# environment, with an override that swaps in: a PostgreSQL named "haf" carrying HAF 1.28.8's
# lock functions (plus a stub of develop's hive._app_broken_reason); a pgbouncer that only
# reports healthy (the PostgREST connects to haf directly here); an install image built on the
# apps' psql base with install_lock/ copied where the stack mounts it (copied, not mounted, as the
# docker daemon may not see this host's files) and an install_app.sh that re-executes under
# /usr/local/bin/install_with_app_lock.py as the app installers do and records the version it
# installed; and the PostgREST image built from postgrest/.
# Checks: the lock is taken at start and stays held; a plain "up -d" reruns the install, which
# skips with exit 0; an upgraded install restarts the PostgREST and runs; after a postgres
# restart the lock is back within a retry; an app HAF reports broken has its lock released, so
# its repair install runs, and taken again once healed; with an unreachable lock connection the
# API still serves; an upgraded install brought up alone ("up -d --wait <install>") fails with a
# non-zero exit naming the holder and the recovery, so does the next full "up -d", and the
# recovery (stop the PostgREST, "up -d") installs it.  Control: with HAF_APP_LOCK unset, a plain
# rerun of the install runs under the live API.
# Also checks the whole stack's config: every PostgREST holds a lock or is exempt; every holder
# has its pg_hba row and restarts with every install that takes its lock (control: without
# block-explorer-postgrest's restart on the hafbe_bal install, the check names that edge); every
# install of a lock that records its version mounts install_lock/ and queries its version
# (control: without the mounts on the hafbe_bal install, the check names it); and
# install_lock/install_with_app_lock.py is common-ci-configuration's, unmodified.
# Needs a docker daemon for all but the last check; skips (exit 0) with the reason when there is
# none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
POSTGRES_IMAGE=${POSTGRES_IMAGE:-postgres:18}
# Empty: build postgrest/ as haf-api-node-postgrest:app-lock-test.
POSTGREST_IMAGE=${POSTGREST_IMAGE:-}
# The base of the app images (their python3, psycopg2 and psql), as nft_tracker 1.28.8 pins it.
INSTALL_BASE_IMAGE=${INSTALL_BASE_IMAGE:-registry.gitlab.syncad.com/hive/common-ci-configuration/psql:da9ffb6003edfb5cbaf1dfcde8e1847667af7d24}
# The holder retries and checks every 5s; plus the PostgREST's start, plus slack.
LOCK_TIMEOUT=${LOCK_TIMEOUT:-40}
HOLDER=postgrest_app_lock_nft_tracker

# PostgRESTs that hold no lock: hafah's and haf_stats' installers take none; haf_fyp's API role
# has no USAGE on schema hive, by design (haf_fyp's db/builtin_roles.sql).
EXEMPT="hafah-postgrest haf-stats-postgrest haf-fyp-postgrest"

# Every install that takes each lock, as the apps' installers name it (checked by hand against
# their sources; this test cannot see them): a PostgREST holding the lock must restart with all
# of them, or an upgrade of one of them alone finds the lock held and skips.
LOCK_INSTALLS='{
  "hivemind": ["hivemind-install"],
  "hivesense": ["hivesense-install-schema"],
  "proxy-whitelist": ["proxy-whitelist-install"],
  "balance_tracker": ["balance-tracker-install"],
  "reputation_tracker": ["reputation-tracker-install"],
  "nft_tracker": ["nft-tracker-install"],
  "haf_block_explorer": ["block-explorer-install-schema", "block-explorer-install-balance-tracker"]
}'

# Installs of LOCK_INSTALLS that cannot tell an upgrade from a rerun through install_lock/:
# hivemind's installer is its own (no install_with_app_lock.py; ci/scripts/test-hivemind-install-check.sh
# covers its check); proxy-whitelist records no version.
UNVERSIONED_INSTALLS="hivemind-install proxy-whitelist-install"

# install_lock/install_with_app_lock.py: common-ci-configuration 7658f4893592b132352e5fdbc103dbb9adc7cfa8
# (#85), haf-app-tools/scripts/install_with_app_lock.py (install_lock/README.md).
WRAPPER_BLOB=1e1eebada76bbe5371c617bea02142cd2738e466

skip() {
  echo "SKIP postgrest-app-lock: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  if [ -f "${WORK:-}/stubs.yaml" ]; then
    compose ps -a 2>&1 || true
    compose logs --tail 20 nft-tracker-postgrest 2>&1 || true
  fi
  exit 1
}

blob=$(git hash-object "$REPO_DIR/install_lock/install_with_app_lock.py")
[ "$blob" = "$WRAPPER_BLOB" ] ||
  fail "install_lock/install_with_app_lock.py is blob $blob, not common-ci-configuration's $WRAPPER_BLOB"
echo "ok    install_lock/install_with_app_lock.py is common-ci-configuration's #85 wrapper, unmodified"

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"
docker compose version >/dev/null 2>&1 || skip "docker compose is not installed"

PROJECT=app-lock-$$
INSTALL_IMAGE=haf-api-node-install:app-lock-test-$$
WORK=$(mktemp -d)
EXTRA_FILES=()

compose() {
  local files=(-f "$REPO_DIR/nft_tracker.yaml" -f "$WORK/stubs.yaml")
  for f in "${EXTRA_FILES[@]}"; do files+=(-f "$f"); done
  docker compose -p "$PROJECT" --project-directory "$WORK" "${files[@]}" "$@"
}

# By project name: down with the files would skip the services of profiles that are not enabled.
down() {
  docker compose -p "$PROJECT" --project-directory "$WORK" down -v --remove-orphans >/dev/null 2>&1
}

cleanup() {
  down || true
  [ -z "${BUILT_IMAGE:-}" ] || docker rmi "$BUILT_IMAGE" >/dev/null 2>&1 || true
  docker rmi "$INSTALL_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

######### The stack's config #########

# check_stack [OVERRIDE]: every PostgREST holds its lock or is exempt; every holder has its
# pg_hba row and restarts with each install of its lock; each install of a lock, but the
# unversioned ones, runs install_lock/'s wrapper with a version query.  Prints why it fails.
check_stack() {
  local files=(-f "$REPO_DIR/compose.yml")
  [ -z "${1:-}" ] || files+=(-f "$1")
  if ! docker compose --project-directory "$REPO_DIR" --env-file "$REPO_DIR/.env.example" "${files[@]}" \
    --profile '*' config --format json > "$WORK/stack.json" 2>"$WORK/config.log"; then
    echo "stack config failed: $(tail -5 "$WORK/config.log")"
    return 1
  fi
  python3 - "$WORK/stack.json" "$LOCK_INSTALLS" "$EXEMPT" "$UNVERSIONED_INSTALLS" "$REPO_DIR" <<'EOF'
import json, sys
services = json.load(open(sys.argv[1]))["services"]
lock_installs = json.loads(sys.argv[2])
exempt = set(sys.argv[3].split())
unversioned = set(sys.argv[4].split())
repo = sys.argv[5]
mounts = {
    "/usr/local/bin/install_with_app_lock.py": f"{repo}/install_lock/with_install_version.py",
    "/usr/local/lib/haf_api_node/install_with_app_lock.py": f"{repo}/install_lock/install_with_app_lock.py",
}
hba = services["haf"]["environment"]["PG_ACCESS"].split("\n")
holders = {n: s["environment"] for n, s in services.items()
           if (s.get("environment") or {}).get("HAF_APP_LOCK")}
postgrests = {n for n, s in services.items() if "/haf_api_node/postgrest:" in s.get("image", "")}
for name in sorted(postgrests - set(holders) - exempt):
    sys.exit(f"{name} holds no app lock and is not exempt")
for name in sorted(exempt & set(holders)):
    sys.exit(f"{name} is exempt but holds {holders[name]['HAF_APP_LOCK']}")
for install in sorted({i for installs in lock_installs.values() for i in installs} - set(services)):
    sys.exit(f"LOCK_INSTALLS names {install}, which is not a service")
missing = set(lock_installs) - {env["HAF_APP_LOCK"] for env in holders.values()}
if missing:
    sys.exit(f"no PostgREST holds {sorted(missing)}")
for name, env in holders.items():
    lock = env["HAF_APP_LOCK"]
    if lock not in lock_installs:
        sys.exit(f"{name} holds {lock}, which no install in LOCK_INSTALLS takes")
    user = env["HAF_APP_LOCK_DB_URI"].split("://", 1)[1].split("@", 1)[0]
    if not any(r.split()[:3] == ["host", "haf_block_log", user] and f"-{name}-1." in r for r in hba):
        sys.exit(f"{name}: no pg_hba row for {user} from its container")
    deps = services[name]["depends_on"]
    for install in lock_installs[lock]:
        if deps.get(install, {}).get("restart") is not True:
            sys.exit(f"{name} holds {lock} but does not restart with {install}: {deps.get(install)}")
for install in sorted({i for installs in lock_installs.values() for i in installs} - unversioned):
    service = services[install]
    if not (service.get("environment") or {}).get("HAF_APP_INSTALLED_VERSION_QUERY"):
        sys.exit(f"{install} sets no HAF_APP_INSTALLED_VERSION_QUERY")
    bound = {v["target"]: v["source"] for v in service.get("volumes", []) if v.get("type") == "bind"}
    for target, source in mounts.items():
        if bound.get(target) != source:
            sys.exit(f"{install} does not mount {source} at {target}: {bound.get(target)}")
EOF
}

check_stack >"$WORK/check.log" 2>&1 || fail "the stack's lock holders are not wired: $(cat "$WORK/check.log")"
echo "ok    every PostgREST holds its lock or is exempt; every holder has its pg_hba row and restarts with each install of its lock"

cat > "$WORK/no-bal-restart.yaml" <<'EOF'
services:
  block-explorer-postgrest:
    depends_on: !override
      block-explorer-install-schema:
        condition: service_completed_successfully
        restart: true
      pgbouncer:
        condition: service_healthy
EOF
check_stack "$WORK/no-bal-restart.yaml" >"$WORK/check.log" 2>&1 || true
grep -q "block-explorer-postgrest holds haf_block_explorer but does not restart with block-explorer-install-balance-tracker" \
  "$WORK/check.log" ||
  fail "control: without block-explorer-postgrest's restart on the hafbe_bal install, the check said: $(cat "$WORK/check.log")"
echo "ok    control: the config check catches a holder that does not restart with an install of its lock"

cat > "$WORK/no-bal-wrapper.yaml" <<'EOF'
services:
  block-explorer-install-balance-tracker:
    volumes: !reset []
EOF
check_stack "$WORK/no-bal-wrapper.yaml" >"$WORK/check.log" 2>&1 || true
grep -q "block-explorer-install-balance-tracker does not mount .*/install_lock/with_install_version.py at /usr/local/bin/install_with_app_lock.py" \
  "$WORK/check.log" ||
  fail "control: without the hafbe_bal install's install_lock/ mounts, the check said: $(cat "$WORK/check.log")"
echo "ok    control: the config check catches an install of a lock that does not run install_lock/'s wrapper"

######### Image #########

if [ -z "$POSTGREST_IMAGE" ]; then
  POSTGREST_IMAGE=haf-api-node-postgrest:app-lock-test
  BUILT_IMAGE=$POSTGREST_IMAGE
  docker build -q -t "$POSTGREST_IMAGE" "$REPO_DIR/postgrest" >"$WORK/build.log" 2>&1 ||
    fail "postgrest image build failed: $(tail -5 "$WORK/build.log")"
fi

# The app installers' re-exec under the lock wrapper (e.g. nft_tracker's scripts/install_app.sh),
# then an install that drops and recreates an endpoint and records its version.  The stack's
# HAF_APP_INSTALL_VERSION_ENV names NFTTRACKER_GIT_HASH, the image's version.
mkdir "$WORK/install"
cat > "$WORK/install/install_app.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
POSTGRES_ACCESS=postgresql://postgres@haf/haf_block_log
if [[ -z "${HAF_INSTALL_LOCK_HELD:-}" ]]; then
  export HAF_INSTALL_LOCK_HELD=1
  exec python3 /usr/local/bin/install_with_app_lock.py nft_tracker "$POSTGRES_ACCESS" "$0" "$@"
fi
psql "$POSTGRES_ACCESS" -X -q -v ON_ERROR_STOP=1 -v gen="$INSTALL_GEN" -v hash="$NFTTRACKER_GIT_HASH" <<'SQL'
CREATE SCHEMA IF NOT EXISTS nfttracker_endpoints;
GRANT USAGE ON SCHEMA nfttracker_endpoints TO nfttracker_user;
DROP FUNCTION IF EXISTS nfttracker_endpoints.probe();
CREATE FUNCTION nfttracker_endpoints.probe() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE TABLE IF NOT EXISTS nfttracker_app.version (git_hash text NOT NULL);
TRUNCATE nfttracker_app.version;
INSERT INTO nfttracker_app.version VALUES (:'hash');
INSERT INTO public.install_runs (gen) VALUES (:gen);
SQL
EOF
cp "$REPO_DIR/install_lock/with_install_version.py" "$REPO_DIR/install_lock/install_with_app_lock.py" "$WORK/install/"
cat > "$WORK/install/Dockerfile" <<'EOF'
ARG BASE
FROM ${BASE}
COPY --chmod=0755 with_install_version.py /usr/local/bin/install_with_app_lock.py
COPY --chmod=0755 install_with_app_lock.py /usr/local/lib/haf_api_node/install_with_app_lock.py
COPY --chmod=0755 install_app.sh /stub/install_app.sh
EOF
docker build -q --build-arg BASE="$INSTALL_BASE_IMAGE" -t "$INSTALL_IMAGE" "$WORK/install" >"$WORK/build.log" 2>&1 ||
  fail "install image build failed: $(tail -5 "$WORK/build.log")"

######### Stub override #########

cat > "$WORK/.env" <<EOF
HIVE_API_NODE_VERSION=stub
PUBLIC_HOSTNAME=stub.invalid
TOP_LEVEL_DATASET_MOUNTPOINT=/stub
COMPOSE_PROFILES=nft-tracker
STUB_POSTGRES_IMAGE=$POSTGRES_IMAGE
STUB_POSTGREST_IMAGE=$POSTGREST_IMAGE
STUB_INSTALL_IMAGE=$INSTALL_IMAGE
NETWORK=$PROJECT
EOF

# HAF 1.28.8's lock functions (hive_fork_manager/app_locks.sql), and a stub of develop's
# hive._app_broken_reason reading public.broken.
cat > "$WORK/haf.sql" <<'EOF'
CREATE ROLE nfttracker_user LOGIN;
CREATE SCHEMA nfttracker_app;
GRANT USAGE ON SCHEMA nfttracker_app TO nfttracker_user;
CREATE SCHEMA hive;
-- On HAF, through hive_applications_group.
GRANT USAGE ON SCHEMA hive TO nfttracker_user;
CREATE TABLE public.install_runs (id serial PRIMARY KEY, gen int);
CREATE TABLE public.broken (app text PRIMARY KEY, reason text);
GRANT SELECT ON public.broken TO PUBLIC;

CREATE FUNCTION hive._try_app_lock( _app_name TEXT, _exclusive BOOLEAN ) RETURNS TEXT LANGUAGE plpgsql VOLATILE AS $BODY$
DECLARE
    __classid INTEGER := hashtext( 'hive_fork_manager_app_lock' );
    __objid   INTEGER := hashtext( _app_name );
    __acquired BOOLEAN;
    __holders TEXT;
BEGIN
    IF _exclusive THEN
        __acquired := pg_try_advisory_lock( __classid, __objid );
    ELSE
        __acquired := pg_try_advisory_lock_shared( __classid, __objid );
    END IF;
    IF __acquired THEN
        RETURN NULL;
    END IF;
    SELECT string_agg( format( '%s (pid=%s)', a.application_name, a.pid ), ', ' ) INTO __holders
      FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE l.locktype = 'advisory' AND l.classid = __classid AND l.objid = __objid AND l.granted;
    RETURN COALESCE( __holders, '(unknown)' );
END;
$BODY$;

CREATE FUNCTION hive.try_acquire_app_install_lock( _app_name TEXT ) RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE AS $BODY$
DECLARE
    __holders TEXT;
BEGIN
    __holders := hive._try_app_lock( _app_name, TRUE );
    IF __holders IS NULL THEN
        RETURN TRUE;
    END IF;
    RAISE NOTICE 'Skipping install: lock on % held by %', _app_name, __holders;
    RETURN FALSE;
END;
$BODY$;

CREATE FUNCTION hive.acquire_app_block_processor_locks( _app_names TEXT[] ) RETURNS VOID LANGUAGE plpgsql VOLATILE AS $BODY$
DECLARE
    __app TEXT;
BEGIN
    FOREACH __app IN ARRAY _app_names LOOP
        WHILE hive._try_app_lock( __app, FALSE ) IS NOT NULL LOOP
            PERFORM pg_sleep( 1 );
        END LOOP;
        -- As on develop: refused, and released, while HAF reports the app broken.
        IF hive._app_broken_reason( __app ) IS NOT NULL THEN
            PERFORM pg_advisory_unlock_shared( hashtext( 'hive_fork_manager_app_lock' ), hashtext( __app ) );
            RAISE EXCEPTION 'Cannot take block-processor lock on %: %', __app, hive._app_broken_reason( __app );
        END IF;
    END LOOP;
END;
$BODY$;

CREATE FUNCTION hive._app_broken_reason( _app_name TEXT ) RETURNS TEXT LANGUAGE sql AS
  'SELECT reason FROM public.broken WHERE app = _app_name';
EOF

# INSTALL_GEN stands for the install image's version: changing it recreates the install, as an
# image bump does, and NFTTRACKER_GIT_HASH is that version's 40-digit hash.
cat > "$WORK/stubs.yaml" <<'EOF'
services:
  haf:
    image: ${STUB_POSTGRES_IMAGE}
    environment:
      POSTGRES_HOST_AUTH_METHOD: trust
      POSTGRES_DB: haf_block_log
    networks:
      haf-network:
    healthcheck:
      test: ["CMD-SHELL", "psql -U postgres -d haf_block_log -tAc \"SELECT to_regprocedure('hive.try_acquire_app_install_lock(text)') IS NOT NULL\" | grep -qx t"]
      interval: 1s
      timeout: 2s
      retries: 120
  pgbouncer:
    image: ${STUB_POSTGRES_IMAGE}
    command: ["sleep", "infinity"]
    networks:
      haf-network:
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
  nft-tracker-install:
    image: ${STUB_INSTALL_IMAGE}
    entrypoint: ["/stub/install_app.sh"]
    command: !reset []
    volumes: !reset []
    environment:
      INSTALL_GEN: ${INSTALL_GEN:-1}
      NFTTRACKER_GIT_HASH: ${INSTALL_HASH:-0000000000000000000000000000000000000001}
  nft-tracker-postgrest:
    image: ${STUB_POSTGREST_IMAGE}
    ulimits: !reset {}
    environment:
      PGRST_DB_URI: postgresql://nfttracker_user@haf/haf_block_log
      PGRST_DB_ROOT_SPEC: ""
    healthcheck:
      interval: 1s
      start_period: 0s
networks:
  haf-network:
    name: ${NETWORK}
EOF

# Control: no holder.
cat > "$WORK/no-lock.yaml" <<'EOF'
services:
  nft-tracker-postgrest:
    environment:
      HAF_APP_LOCK: ""
EOF

# A lock connection that cannot connect.
cat > "$WORK/bad-lock-uri.yaml" <<'EOF'
services:
  nft-tracker-postgrest:
    environment:
      HAF_APP_LOCK_DB_URI: postgresql://nfttracker_user@no-such-host.invalid/haf_block_log
EOF

######### Helpers #########

q() {
  compose exec -T haf psql -X -qAt -U postgres -d haf_block_log -c "$1" </dev/null
}

# start_haf: postgres up with the lock functions in place (the install waits for them).
start_haf() {
  compose up -d haf >"$WORK/up.log" 2>&1 || fail "haf did not start: $(tail -5 "$WORK/up.log")"
  local deadline=$((SECONDS + 60))
  until compose exec -T haf pg_isready -q -U postgres -d haf_block_log </dev/null >/dev/null 2>&1 &&
        q "SELECT 1" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || fail "postgres did not accept connections"
    sleep 1
  done
  compose exec -T haf psql -X -q -v ON_ERROR_STOP=1 -U postgres -d haf_block_log <"$WORK/haf.sql" >"$WORK/init.log" 2>&1 ||
    fail "lock functions: $(tail -5 "$WORK/init.log")"
}

# at GENERATION COMPOSE-ARGS...: compose with the install at GENERATION.
at() {
  local gen=$1
  shift
  INSTALL_GEN=$gen INSTALL_HASH=$(printf '%040d' "$gen") compose "$@"
}

# up GENERATION: "up -d" with the install at GENERATION.
up() {
  at "$1" up -d --wait nft-tracker-postgrest >"$WORK/up.log" 2>&1 ||
    fail "up -d (install generation $1) failed: $(tail -5 "$WORK/up.log")"
}

# install_result: the last install's exit code, then the generations installed so far.
install_result() {
  echo "$(docker inspect -f '{{.State.ExitCode}}' "$(compose ps -aq nft-tracker-install)")" \
    "$(q "SELECT string_agg(gen::text, ' ' ORDER BY id) FROM public.install_runs")"
}

held() {
  q "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE l.locktype = 'advisory' AND l.mode = 'ShareLock' AND l.granted AND a.application_name = '$HOLDER'"
}

# logged TEXT: 1 when the PostgREST's log has TEXT.
logged() {
  if compose logs nft-tracker-postgrest 2>&1 | grep -qF "$1"; then echo 1; else echo 0; fi
}

started() {
  docker inspect -f '{{.State.StartedAt}}' "$(compose ps -aq "$1")"
}

# [LIMIT=SECONDS] within WHAT EXPECTED COMMAND...: COMMAND prints EXPECTED within LIMIT
# (default LOCK_TIMEOUT).
within() {
  local what=$1 expected=$2 limit=${LIMIT:-$LOCK_TIMEOUT} got
  local deadline=$((SECONDS + limit))
  shift 2
  while :; do
    got=$("$@" 2>&1) || true
    if [ "$got" = "$expected" ]; then
      echo "ok    $what ($((limit - deadline + SECONDS))s)"
      return
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "$what: after ${limit}s got: $got"
    sleep 1
  done
}

# steady WHAT: the lock stays held, sampled each second over three checks, with no new warning.
steady() {
  local warnings end=$((SECONDS + 16))
  warnings=$(compose logs nft-tracker-postgrest 2>&1 | grep -c "WARNING: not holding" || true)
  while [ "$SECONDS" -lt "$end" ]; do
    [ "$(held)" = 1 ] || fail "$1: the lock was dropped"
    sleep 1
  done
  [ "$(compose logs nft-tracker-postgrest 2>&1 | grep -c "WARNING: not holding" || true)" = "$warnings" ] ||
    fail "$1: the holder warned that it lost the lock"
  echo "ok    $1"
}

expect_install() {
  local got
  got=$(install_result)
  [ "$got" = "$1" ] || fail "$2: last install was '$got', expected '$1'"
  echo "ok    $2"
}

######### Control: no holder #########

EXTRA_FILES=("$WORK/no-lock.yaml")
start_haf
up 1
expect_install "0 1" "control: generation 1 installs"
sleep 3
up 1
expect_install "0 1 1" "control: without HAF_APP_LOCK, a plain up -d reruns the install under the live API"
[ "$(held)" = 0 ] || fail "control: a lock is held without HAF_APP_LOCK"
down || fail "down failed"

######### Fail-open #########

EXTRA_FILES=("$WORK/bad-lock-uri.yaml")
start_haf
up 1
within "fail-open: with the lock connection failing, the API is healthy and the failure is logged" 1 \
  logged "app lock: WARNING: not holding"
down || fail "down failed"

######### With the holder #########

EXTRA_FILES=()
start_haf
up 1
expect_install "0 1" "generation 1 installs"
LIMIT=10 within "the PostgREST holds the shared lock on nft_tracker" 1 held
steady "the lock stays held"

pg=$(started nft-tracker-postgrest)
up 1
expect_install "0 1" "a plain up -d reruns the install, which skips with exit 0"
compose logs nft-tracker-install 2>&1 | grep -qF "Skipping nft_tracker install — version $(printf '%040d' 1) is already installed" ||
  fail "the skipped rerun did not log the installed version"
[ "$(started nft-tracker-postgrest)" = "$pg" ] || fail "the plain up -d restarted the PostgREST"

up 2
expect_install "0 1 2" "an upgraded install runs"
[ "$(started nft-tracker-postgrest)" != "$pg" ] || fail "the upgraded install did not restart the PostgREST"
LIMIT=10 within "the restarted PostgREST holds the lock again" 1 held

compose restart haf >/dev/null 2>&1 || fail "postgres restart failed"
LIMIT=15 within "after a postgres restart the lock is held again within a retry" 1 held

q "INSERT INTO public.broken VALUES ('nft_tracker', 'test breakage')" >/dev/null
within "an app HAF reports broken has its lock released" 0 held
within "the release is logged" 1 logged "releasing the lock on nft_tracker: test breakage"
up 2
expect_install "0 1 2 2" "the repair install of the broken app runs under the live API"
q "DELETE FROM public.broken" >/dev/null
LIMIT=15 within "once healed, the lock is held again within a retry" 1 held
steady "and stays held"

# An upgrade brought up alone leaves the PostgREST out of what compose manages in that run, so
# it is not stopped and holds the lock: the install fails, naming the holder and the recovery
# (README).  "up -d" alone returns before the install ends; --wait reports how it ended.
pg=$(started nft-tracker-postgrest)
if at 3 up -d --wait nft-tracker-install >"$WORK/up.log" 2>&1; then
  fail "up -d --wait nft-tracker-install of an upgrade under the live API exited 0"
fi
expect_install "1 1 2 2" "an upgraded install brought up alone fails with a non-zero exit, installing nothing"
compose logs nft-tracker-install 2>&1 | grep -F "Cannot install" >"$WORK/install.log" || true
for expected in "Cannot install nft_tracker version $(printf '%040d' 3): the installed version is $(printf '%040d' 2)" \
                "held by NOTICE:  Skipping install: lock on nft_tracker held by $HOLDER" \
                "To upgrade: stop nft_tracker-postgrest"; do
  grep -qF "$expected" "$WORK/install.log" ||
    fail "the failed upgrade did not log '$expected': $(compose logs --tail 5 nft-tracker-install 2>&1)"
done
echo "ok    the failure names the versions, the holder and the recovery"
[ "$(started nft-tracker-postgrest)" = "$pg" ] || fail "the failed upgrade restarted the PostgREST"
[ "$(held)" = 1 ] || fail "the PostgREST lost the lock over the failed upgrade"
if at 3 up -d --wait nft-tracker-postgrest >"$WORK/up.log" 2>&1; then
  fail "the full up -d after the failed upgrade exited 0"
fi
expect_install "1 1 2 2" "the next full up -d does not stop the PostgREST either, and fails again"

compose stop nft-tracker-postgrest >/dev/null 2>&1 || fail "stopping the PostgREST failed"
up 3
expect_install "0 1 2 2 3" "recovery: with the PostgREST stopped first, up -d installs the upgrade"
LIMIT=10 within "and the PostgREST holds the lock again" 1 held

echo "PASS postgrest-app-lock"
