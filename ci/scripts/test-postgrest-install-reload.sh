#!/usr/bin/env bash
#
# Test that an app's PostgREST serves the endpoint signatures its install leaves behind, through its
# rewriter, once compose reruns an upgraded install.  Brings up hafah's install, PostgREST and rewriter
# from the stack's own hafah.yaml, keeping their depends_on, with an override that swaps in: a
# PostgreSQL named "pgbouncer"; an install that creates hafah_endpoints.probe(a), or from generation 2
# on probe(a, extra); the real PostgREST binary (upstream image); and an nginx rewriter that proxies
# to it by name with no resolver, like the real rewriter images.
# "docker compose up -d" with a changed install environment (an image bump to compose) must then
# serve probe?a=..&extra=.. through the rewriter within ANSWER_TIMEOUT, and a plain rerun must restart
# neither the PostgREST nor the rewriter.  Two controls: without the PostgREST's restart: true the new
# parameter must stay PGRST202, and without the rewriter's own install dependency the rewriter must
# not restart (compose does not pass a dependency restart on).  Also checks the whole stack's config:
# every app's PostgREST and rewriter restart with each of the PostgREST's installs.
# Needs a docker daemon; skips (exit 0) with the reason when there is none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
POSTGRES_IMAGE=${POSTGRES_IMAGE:-postgres:18}
POSTGREST_IMAGE=${POSTGREST_IMAGE:-postgrest/postgrest:v14.15}
STUB_IMAGE=${STUB_IMAGE:-nginx:alpine}
# The PostgREST's restart and schema load after the install, plus slack.
ANSWER_TIMEOUT=${ANSWER_TIMEOUT:-30}

# "<postgrest> <rewriter>" for each app of the stack.
PAIRS="hivemind-postgrest-server hivemind-postgrest-rewriter
hafah-postgrest hafah-postgrest-rewriter
balance-tracker-postgrest balance-tracker-postgrest-rewriter
block-explorer-postgrest block-explorer-postgrest-rewriter
reputation-tracker-postgrest reputation-tracker-postgrest-rewriter
nft-tracker-postgrest nft-tracker-postgrest-rewriter
haf-stats-postgrest haf-stats-postgrest-rewriter
haf-fyp-postgrest haf-fyp-postgrest-rewriter
hivesense-postgrest hivesense-postgrest-rewriter
proxy-whitelist-postgrest proxy-whitelist-postgrest-rewriter"

skip() {
  echo "SKIP postgrest-install-reload: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  [ ! -f "${WORK:-}/stubs.yaml" ] || compose ps -a 2>&1 || true
  exit 1
}

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"
docker compose version >/dev/null 2>&1 || skip "docker compose is not installed"

PROJECT=install-reload-$$
WORK=$(mktemp -d)
EXTRA_FILES=()

compose() {
  local files=(-f "$REPO_DIR/hafah.yaml" -f "$WORK/stubs.yaml")
  for f in "${EXTRA_FILES[@]}"; do files+=(-f "$f"); done
  docker compose -p "$PROJECT" --project-directory "$WORK" "${files[@]}" "$@"
}

# By project name: down with the files would skip the services of profiles that are not enabled.
down() {
  docker compose -p "$PROJECT" --project-directory "$WORK" down -v --remove-orphans >/dev/null 2>&1
}

cleanup() {
  down || true
  rm -rf "$WORK"
}
trap cleanup EXIT

######### The stack's depends_on #########

# Every app's PostgREST restarts with each of its installs, and so does its rewriter.
docker compose --project-directory "$REPO_DIR" --env-file "$REPO_DIR/.env.example" --profile '*' \
  config --format json > "$WORK/stack.json" 2>"$WORK/config.log" ||
  fail "stack config failed: $(tail -5 "$WORK/config.log")"
python3 - "$WORK/stack.json" "$PAIRS" <<'EOF' || fail "a PostgREST or rewriter does not restart with its install"
import json, sys
services = json.load(open(sys.argv[1]))["services"]
for line in sys.argv[2].splitlines():
    postgrest, rewriter = line.split()
    pg_deps = services[postgrest]["depends_on"]
    rw_deps = services[rewriter]["depends_on"]
    installs = [n for n, d in pg_deps.items() if d.get("condition") == "service_completed_successfully"
                and "install" in n and not n.startswith("lite-")]
    if not installs:
        sys.exit(f"{postgrest} depends on no install: {pg_deps}")
    for name in installs:
        if pg_deps[name].get("restart") is not True:
            sys.exit(f"{postgrest} depends_on {name}: {pg_deps[name]}")
        rw = rw_deps.get(name, {})
        if (rw.get("condition") != "service_completed_successfully" or rw.get("restart") is not True
                or rw.get("required", True) != pg_deps[name].get("required", True)):
            sys.exit(f"{rewriter} depends_on {name}: {rw}")
    if rw_deps.get(postgrest, {}).get("restart") is not True:
        sys.exit(f"{rewriter} depends_on {postgrest}: {rw_deps.get(postgrest)}")
EOF
echo "ok    every app's PostgREST and rewriter restart with the PostgREST's installs"

######### Stub override #########

cat > "$WORK/.env" <<EOF
HIVE_API_NODE_VERSION=stub
PUBLIC_HOSTNAME=stub.invalid
COMPOSE_PROFILES=hafah
EOF

# INSTALL_GEN stands for the install image's version: changing it recreates the install, as an
# image bump does.
cat > "$WORK/stubs.yaml" <<EOF
services:
  pgbouncer:
    image: $POSTGRES_IMAGE
    command: ["postgres", "-p", "6432"]
    environment:
      POSTGRES_HOST_AUTH_METHOD: trust
      POSTGRES_DB: haf_block_log
    networks:
      haf-network:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U postgres -d haf_block_log"]
      interval: 1s
      timeout: 2s
      retries: 60
      start_period: 0s
  hafah-install:
    image: $POSTGRES_IMAGE
    environment:
      INSTALL_GEN: \${INSTALL_GEN:-1}
    depends_on: !override
      pgbouncer:
        condition: service_healthy
    command:
      - sh
      - -c
      - |
        if [ "\$\$INSTALL_GEN" -ge 2 ]; then
          args='a int, extra int DEFAULT NULL'
        else
          args='a int'
        fi
        exec psql -v ON_ERROR_STOP=1 -1 -h pgbouncer -p 6432 -U postgres -d haf_block_log <<SQL
        DO \\\$\$\\\$\$ BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hafah_user') THEN
            CREATE ROLE hafah_user LOGIN;
          END IF;
        END \\\$\$\\\$\$;
        CREATE SCHEMA IF NOT EXISTS hafah_endpoints;
        GRANT USAGE ON SCHEMA hafah_endpoints TO hafah_user;
        DROP FUNCTION IF EXISTS hafah_endpoints.probe(int);
        DROP FUNCTION IF EXISTS hafah_endpoints.probe(int, int);
        CREATE FUNCTION hafah_endpoints.probe(\$\$args) RETURNS json LANGUAGE sql
          AS 'SELECT json_build_object(''gen'', \$\$INSTALL_GEN)';
        SQL
  hafah-postgrest:
    image: $POSTGREST_IMAGE
    ulimits: !reset {}
    environment:
      PGRST_DB_URI: postgresql://hafah_user@pgbouncer:6432/haf_block_log
      PGRST_DB_ROOT_SPEC: ""
    healthcheck:
      test: ["CMD", "/bin/postgrest", "--ready"]
      interval: 1s
      timeout: 2s
      retries: 60
      start_period: 0s
  hafah-postgrest-rewriter:
    image: $STUB_IMAGE
    command:
      - sh
      - -c
      - |
        cat > /etc/nginx/conf.d/default.conf <<'CONF'
        server {
          listen 80;
          location / { proxy_pass http://hafah-postgrest:3000; }
        }
        server {
          listen 81;
          location = /health { return 200; }
        }
        CONF
        exec nginx -g 'daemon off;'
    healthcheck:
      interval: 1s
      start_period: 0s
networks:
  haf-network:
    name: $PROJECT
EOF

# Control 1: the PostgREST's depends_on as before the fix.
cat > "$WORK/no-postgrest-restart.yaml" <<'EOF'
services:
  hafah-postgrest:
    depends_on: !override
      hafah-install:
        condition: service_completed_successfully
      pgbouncer:
        condition: service_healthy
EOF

# Control 2: the rewriter depends on its PostgREST only.
cat > "$WORK/no-rewriter-install.yaml" <<'EOF'
services:
  hafah-postgrest-rewriter:
    depends_on: !override
      hafah-postgrest:
        condition: service_healthy
        restart: true
EOF

######### Helpers #########

# up GENERATION: "up -d" with the install at GENERATION.
up() {
  INSTALL_GEN=$1 compose up -d --wait hafah-postgrest-rewriter >"$WORK/up.log" 2>&1 ||
    fail "up -d (install generation $1) failed: $(tail -5 "$WORK/up.log")"
}

# call QUERY: what the rewriter answers GET /rpc/probe?QUERY with ("error: ..." for a non-2xx).
call() {
  compose exec -T hafah-postgrest-rewriter sh -c \
    "wget -q -T 2 -O - '127.0.0.1:80/rpc/probe?$1' 2>&1 || echo \" (error)\"" </dev/null 2>&1
}

started() {
  docker inspect "$(compose ps -aq "$1")" | python3 -c "import json, sys; print(json.load(sys.stdin)[0]['State']['StartedAt'])"
}

# answers QUERY EXPECTED WHAT: within ANSWER_TIMEOUT, the rewriter answers QUERY with EXPECTED.
answers() {
  local deadline=$((SECONDS + ANSWER_TIMEOUT)) got
  while :; do
    got=$(call "$1")
    if [ "$got" = "$2" ]; then
      echo "ok    $3 ($((ANSWER_TIMEOUT - deadline + SECONDS))s)"
      return
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "$3: after ${ANSWER_TIMEOUT}s, probe?$1 answered: $got"
    sleep 1
  done
}

NEW_ARG='a=1&extra=2'
GEN1='{"gen" : 1}'
GEN2='{"gen" : 2}'

# rejects_new_arg WHAT: the new parameter is still unknown to the PostgREST's schema cache
# (PGRST202, a 404).
rejects_new_arg() {
  local got
  got=$(call "$NEW_ARG")
  case "$got" in
    *404*) echo "ok    $1" ;;
    *) fail "$1: probe?$NEW_ARG answered: $got" ;;
  esac
}

######### Control 1: PostgREST without restart: true #########

EXTRA_FILES=("$WORK/no-postgrest-restart.yaml")
up 1
answers "a=1" "$GEN1" "control 1: generation 1 serves probe(a)"
up 2
sleep 3
rejects_new_arg "control 1: without restart: true, the PostgREST still rejects probe(a, extra) after the upgrade"
down || fail "down failed"

######### Control 2: rewriter without its install dependency #########

EXTRA_FILES=("$WORK/no-rewriter-install.yaml")
up 1
answers "a=1" "$GEN1" "control 2: generation 1 serves probe(a)"
pg=$(started hafah-postgrest)
rw=$(started hafah-postgrest-rewriter)
up 2
[ "$(started hafah-postgrest)" != "$pg" ] || fail "control 2: the upgraded install did not restart the PostgREST"
[ "$(started hafah-postgrest-rewriter)" = "$rw" ] ||
  fail "control 2: the rewriter restarted through its PostgREST alone, so the test cannot see the gap"
echo "ok    control 2: the PostgREST restart does not reach a rewriter without its own install dependency"
down || fail "down failed"

######### With the stack's depends_on #########

EXTRA_FILES=()
up 1
answers "a=1" "$GEN1" "generation 1 serves probe(a)"
rejects_new_arg "generation 1 rejects probe(a, extra)"

pg=$(started hafah-postgrest)
rw=$(started hafah-postgrest-rewriter)
up 2
answers "$NEW_ARG" "$GEN2" "the upgraded install's probe(a, extra) is served through the rewriter"
[ "$(started hafah-postgrest)" != "$pg" ] || fail "the upgraded install did not restart the PostgREST"
[ "$(started hafah-postgrest-rewriter)" != "$rw" ] || fail "the upgraded install did not restart the rewriter"
echo "ok    the PostgREST and its rewriter restarted after the install"

# A rerun that changes nothing reruns the install but restarts neither.
install=$(started hafah-install)
pg=$(started hafah-postgrest)
rw=$(started hafah-postgrest-rewriter)
up 2
[ "$(started hafah-install)" != "$install" ] || fail "the plain up -d did not rerun the install"
[ "$(started hafah-postgrest)" = "$pg" ] || fail "the plain up -d restarted the PostgREST"
[ "$(started hafah-postgrest-rewriter)" = "$rw" ] || fail "the plain up -d restarted the rewriter"
answers "$NEW_ARG" "$GEN2" "a plain up -d reruns the install without restarting the PostgREST or rewriter"

echo "PASS postgrest-install-reload"
