#!/usr/bin/env bash
#
# Test that an app's PostgREST holds the app's shared HAF lock while it serves, so a rerun of the
# app's install skips, while an upgraded install still runs.  Brings up nft_tracker's install and
# PostgREST from the stack's own nft_tracker.yaml, keeping their depends_on, with an override that
# swaps in: a PostgreSQL named "haf" carrying HAF 1.28.8's lock functions (plus a stub of develop's
# hive._app_broken_reason); a pgbouncer that only reports healthy (the PostgREST connects to haf
# directly here); an install that takes the exclusive lock the way the app installers do and
# records whether it ran or skipped; and the PostgREST image built from postgrest/.
# Checks: the lock is taken at start and stays held; a plain "up -d" reruns the install, which
# skips; an upgraded install restarts the PostgREST and runs; after a postgres restart the lock
# is back within a retry; an app HAF reports broken has its lock released, so its repair install
# runs, and taken again once healed; with an unreachable lock connection the API still serves;
# and the documented limitation of "up -d <install>" alone.  Control: with HAF_APP_LOCK unset, a
# plain rerun of the install runs under the live API.
# Also checks the whole stack's config: every PostgREST holds a lock or is exempt; every holder
# has its pg_hba row and restarts with every install that takes its lock (control: without
# block-explorer-postgrest's restart on the hafbe_bal install, the check names that edge).
# Needs a docker daemon; skips (exit 0) with the reason when there is none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
POSTGRES_IMAGE=${POSTGRES_IMAGE:-postgres:18}
# Empty: build postgrest/ as haf-api-node-postgrest:app-lock-test.
POSTGREST_IMAGE=${POSTGREST_IMAGE:-}
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

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"
docker compose version >/dev/null 2>&1 || skip "docker compose is not installed"

PROJECT=app-lock-$$
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
  rm -rf "$WORK"
}
trap cleanup EXIT

######### The stack's config #########

# check_stack [OVERRIDE]: every PostgREST holds its lock or is exempt; every holder has its
# pg_hba row and restarts with each install of its lock.  Prints why it fails.
check_stack() {
  local files=(-f "$REPO_DIR/compose.yml")
  [ -z "${1:-}" ] || files+=(-f "$1")
  if ! docker compose --project-directory "$REPO_DIR" --env-file "$REPO_DIR/.env.example" "${files[@]}" \
    --profile '*' config --format json > "$WORK/stack.json" 2>"$WORK/config.log"; then
    echo "stack config failed: $(tail -5 "$WORK/config.log")"
    return 1
  fi
  python3 - "$WORK/stack.json" "$LOCK_INSTALLS" "$EXEMPT" <<'EOF'
import json, sys
services = json.load(open(sys.argv[1]))["services"]
lock_installs = json.loads(sys.argv[2])
exempt = set(sys.argv[3].split())
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

######### Image #########

if [ -z "$POSTGREST_IMAGE" ]; then
  POSTGREST_IMAGE=haf-api-node-postgrest:app-lock-test
  BUILT_IMAGE=$POSTGREST_IMAGE
  docker build -q -t "$POSTGREST_IMAGE" "$REPO_DIR/postgrest" >"$WORK/build.log" 2>&1 ||
    fail "postgrest image build failed: $(tail -5 "$WORK/build.log")"
fi

######### Stub override #########

cat > "$WORK/.env" <<EOF
HIVE_API_NODE_VERSION=stub
PUBLIC_HOSTNAME=stub.invalid
TOP_LEVEL_DATASET_MOUNTPOINT=/stub
COMPOSE_PROFILES=nft-tracker
STUB_POSTGRES_IMAGE=$POSTGRES_IMAGE
STUB_POSTGREST_IMAGE=$POSTGREST_IMAGE
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
CREATE TABLE public.install_runs (id serial PRIMARY KEY, gen int, outcome text);
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
# image bump does.
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
    image: ${STUB_POSTGRES_IMAGE}
    environment:
      INSTALL_GEN: ${INSTALL_GEN:-1}
    command:
      - sh
      - -c
      - |
        exec psql -X -q -v ON_ERROR_STOP=1 -v gen="$$INSTALL_GEN" -h haf -U postgres -d haf_block_log <<'SQL'
        SET application_name = 'nft_tracker_install';
        SELECT hive.try_acquire_app_install_lock('nft_tracker') AS locked \gset
        \if :locked
          CREATE SCHEMA IF NOT EXISTS nfttracker_endpoints;
          GRANT USAGE ON SCHEMA nfttracker_endpoints TO nfttracker_user;
          DROP FUNCTION IF EXISTS nfttracker_endpoints.probe();
          CREATE FUNCTION nfttracker_endpoints.probe() RETURNS int LANGUAGE sql AS 'SELECT 1';
          INSERT INTO public.install_runs (gen, outcome) VALUES (:gen, 'ran');
        \else
          INSERT INTO public.install_runs (gen, outcome) VALUES (:gen, 'skipped');
        \endif
        SQL
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

# up GENERATION: "up -d" with the install at GENERATION.
up() {
  INSTALL_GEN=$1 compose up -d --wait nft-tracker-postgrest >"$WORK/up.log" 2>&1 ||
    fail "up -d (install generation $1) failed: $(tail -5 "$WORK/up.log")"
}

last_install() {
  q "SELECT gen || ' ' || outcome FROM public.install_runs ORDER BY id DESC LIMIT 1"
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
  got=$(last_install)
  [ "$got" = "$1" ] || fail "$2: last install was '$got', expected '$1'"
  echo "ok    $2"
}

######### Control: no holder #########

EXTRA_FILES=("$WORK/no-lock.yaml")
start_haf
up 1
expect_install "1 ran" "control: generation 1 installs"
sleep 3
up 1
expect_install "1 ran" "control: without HAF_APP_LOCK, a plain up -d reruns the install under the live API"
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
expect_install "1 ran" "generation 1 installs"
LIMIT=10 within "the PostgREST holds the shared lock on nft_tracker" 1 held
steady "the lock stays held"

pg=$(started nft-tracker-postgrest)
up 1
expect_install "1 skipped" "a plain up -d reruns the install, which skips"
[ "$(started nft-tracker-postgrest)" = "$pg" ] || fail "the plain up -d restarted the PostgREST"

up 2
expect_install "2 ran" "an upgraded install runs"
[ "$(started nft-tracker-postgrest)" != "$pg" ] || fail "the upgraded install did not restart the PostgREST"
LIMIT=10 within "the restarted PostgREST holds the lock again" 1 held

compose restart haf >/dev/null 2>&1 || fail "postgres restart failed"
LIMIT=15 within "after a postgres restart the lock is held again within a retry" 1 held

q "INSERT INTO public.broken VALUES ('nft_tracker', 'test breakage')" >/dev/null
within "an app HAF reports broken has its lock released" 0 held
within "the release is logged" 1 logged "releasing the lock on nft_tracker: test breakage"
up 2
expect_install "2 ran" "the repair install of the broken app runs under the live API"
q "DELETE FROM public.broken" >/dev/null
LIMIT=15 within "once healed, the lock is held again within a retry" 1 held
steady "and stays held"

# Documented limitation (README): "up -d <install>" alone leaves the PostgREST out of the
# project, so compose does not stop it, and the upgraded install skips -- also on the next full
# "up -d", since the install is then up to date.  Stopping the PostgREST first lets it run.
pg=$(started nft-tracker-postgrest)
INSTALL_GEN=3 compose up -d nft-tracker-install >"$WORK/up.log" 2>&1 || fail "up -d nft-tracker-install failed"
up 3
expect_install "3 skipped" "limitation: an upgraded install brought up alone skips, and so does the next full up -d"
[ "$(started nft-tracker-postgrest)" = "$pg" ] || fail "limitation: the PostgREST was restarted"
compose stop nft-tracker-postgrest >/dev/null 2>&1 || fail "stopping the PostgREST failed"
up 3
expect_install "3 ran" "limitation: with the PostgREST stopped first, the upgraded install runs"

echo "PASS postgrest-app-lock"
