#!/usr/bin/env bash
#
# Test that each PostgREST rewriter follows its PostgREST container when compose recreates or
# restarts it.  Brings up the hafah and reputation tracker PostgREST + rewriter pairs from the stack's
# own hafah.yaml and reputation_tracker.yaml, with an override that keeps the rewriters' depends_on
# but swaps the images for nginx stubs: each "PostgREST" answers GET / with an OpenAPI document
# titled after its app, and each "rewriter" proxies to its PostgREST by name with no resolver, so,
# like the real rewriter images, it resolves the address once when nginx starts.
# The PostgREST stubs get fixed addresses, and "docker compose up -d" with a changed environment
# variable both share recreates them twice so that they end up on each other's first address, as on
# steem-20; every rewriter must answer with its own app's title after each step.  Then
# "docker compose restart hafah-postgrest" must restart hafah's rewriter too.  A control run first
# drops the rewriters' "restart: true" and must see every rewriter answer with the other app.
# Needs a docker daemon; skips (exit 0) with the reason when there is none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
STUB_IMAGE=${STUB_IMAGE:-nginx:alpine}
# The rewriter's start after its PostgREST is recreated, plus slack.
ANSWER_TIMEOUT=${ANSWER_TIMEOUT:-30}

# "<rewriter> <postgrest> <OpenAPI title>" for each pair under test.
PAIRS="hafah-postgrest-rewriter hafah-postgrest HAfAH
reputation-tracker-postgrest-rewriter reputation-tracker-postgrest Reputation_tracker"

skip() {
  echo "SKIP postgrest-rewriter-recreate: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  [ -z "${PROJECT:-}" ] || compose ps -a 2>&1 || true
  exit 1
}

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"
docker compose version >/dev/null 2>&1 || skip "docker compose is not installed"

PROJECT=rewriter-recreate-$$
WORK=$(mktemp -d)
EXTRA_FILES=()

compose() {
  local files=(-f "$REPO_DIR/hafah.yaml" -f "$REPO_DIR/reputation_tracker.yaml" -f "$WORK/stubs.yaml")
  for f in "${EXTRA_FILES[@]}"; do files+=(-f "$f"); done
  docker compose -p "$PROJECT" --project-directory "$WORK" "${files[@]}" "$@"
}

# By project name: down with the files would skip the services of profiles that are not enabled.
down() {
  docker compose -p "$PROJECT" --project-directory "$WORK" down -v --remove-orphans >/dev/null 2>&1
}

cleanup() {
  down || true
  docker network rm "$PROJECT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Values the stack files interpolate; none of them reaches a stub.
cat > "$WORK/.env" <<EOF
HIVE_API_NODE_VERSION=stub
PUBLIC_HOSTNAME=stub.invalid
TOP_LEVEL_DATASET_MOUNTPOINT=$WORK
EOF

# Fixed addresses need a network with a subnet of our choosing: take the first free one.
SUBNET=""
for third in $(seq 200 254); do
  if docker network create --subnet "10.254.$third.0/24" "$PROJECT" >/dev/null 2>&1; then
    SUBNET=10.254.$third
    break
  fi
done
[ -n "$SUBNET" ] || fail "no free /24 in 10.254.200-254.0 for the test network"

# ip_var POSTGREST: the variable holding the service's address.
ip_var() {
  local v=${1^^}
  echo "${v//-/_}_IP"
}

######### Stub override #########

# The PostgREST stubs drop their install and pgbouncer dependencies; the rewriters keep the
# depends_on the stack files give them.  STUB_GENERATION stands for an environment variable the
# PostgREST services share (#91's PGRST_DB_PREPARED_STATEMENTS).
{
  echo "services:"
  while read -r rewriter postgrest title; do
    cat <<EOF
  $postgrest:
    image: $STUB_IMAGE
    ulimits: !reset {}
    depends_on: !reset {}
    environment:
      STUB_GENERATION: \${STUB_GENERATION:-1}
    networks:
      haf-network:
        ipv4_address: \${$(ip_var "$postgrest")}
    command:
      - sh
      - -c
      - |
        cat > /etc/nginx/conf.d/default.conf <<'CONF'
        server {
          listen 3000;
          location = /stub-ready { return 200; }
          location / { default_type application/json; return 200 '{"info":{"title":"$title"}}'; }
        }
        CONF
        exec nginx -g 'daemon off;'
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null 127.0.0.1:3000/stub-ready || exit 1"]
      interval: 1s
      timeout: 2s
      retries: 30
      start_period: 0s
  $rewriter:
    image: $STUB_IMAGE
    command:
      - sh
      - -c
      - |
        cat > /etc/nginx/conf.d/default.conf <<'CONF'
        server {
          listen 80;
          location / { proxy_pass http://$postgrest:3000; }
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
EOF
  done <<< "$PAIRS"
  cat <<EOF
networks:
  haf-network:
    name: $PROJECT
    external: true
EOF
} > "$WORK/stubs.yaml"

# The control: the same depends_on without restart: true, as before the fix.
{
  echo "services:"
  while read -r rewriter postgrest _; do
    cat <<EOF
  $rewriter:
    depends_on: !override
      $postgrest:
        condition: service_healthy
EOF
  done <<< "$PAIRS"
} > "$WORK/no-restart.yaml"

REWRITERS=$(cut -d' ' -f1 <<< "$PAIRS" | tr '\n' ' ')

######### Helpers #########

# place HOST...: put the PostgREST services, in PAIRS order, on SUBNET.HOST.
place() {
  local postgrest
  while read -r _ postgrest _; do
    export "$(ip_var "$postgrest")=$SUBNET.$1"
    shift
  done <<< "$PAIRS"
}

# up GENERATION HOST...: "up -d" with the PostgREST services placed on HOST....
up() {
  local generation=$1
  shift
  place "$@"
  # shellcheck disable=SC2086 # one argument per service
  STUB_GENERATION=$generation compose up -d --wait $REWRITERS >"$WORK/up.log" 2>&1 ||
    fail "up -d (generation $generation) failed: $(tail -5 "$WORK/up.log")"
}

# answer REWRITER: the OpenAPI title (or the error) the rewriter answers GET / with.
answer() {
  local body
  body=$(compose exec -T "$1" wget -q -T 2 -O - 127.0.0.1:80/ 2>&1 </dev/null) || { echo "error: ${body:-no answer}"; return; }
  python3 -c 'import json, sys; print(json.loads(sys.argv[1])["info"]["title"])' "$body" 2>/dev/null ||
    echo "unparsable: $body"
}

inspect() {
  docker inspect "$(compose ps -q "$1")" | python3 -c "
import json, sys
c = json.load(sys.stdin)[0]
print($2)"
}

postgrest_ips() {
  local postgrest
  while read -r _ postgrest _; do
    printf '%s=%s ' "$postgrest" "$(inspect "$postgrest" "c['NetworkSettings']['Networks']['$PROJECT']['IPAddress']")"
  done <<< "$PAIRS"
}

# all_answer_own WHAT: within ANSWER_TIMEOUT, every rewriter answers with its own app's title.
all_answer_own() {
  local deadline=$((SECONDS + ANSWER_TIMEOUT)) wrong got rewriter title
  while :; do
    wrong=""
    while read -r rewriter _ title; do
      got=$(answer "$rewriter")
      [ "$got" = "$title" ] || wrong+="  $rewriter: wanted $title, got $got"$'\n'
    done <<< "$PAIRS"
    if [ -z "$wrong" ]; then
      echo "ok    $1 ($((ANSWER_TIMEOUT - deadline + SECONDS))s)"
      return
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "$1: after ${ANSWER_TIMEOUT}s:
$wrong"
    sleep 1
  done
}

# swap: recreate the PostgREST services via free addresses onto each other's first one.
swap() {
  local first
  first=$(postgrest_ips)
  up 2 12 13
  [ -z "${1:-}" ] || all_answer_own "$1 (PostgREST moved to $(postgrest_ips))"
  up 3 11 10
  echo "      PostgREST swapped: $first-> $(postgrest_ips)"
}

######### The stack's depends_on #########

# The stack files must give every rewriter restart: true on its PostgREST dependency.
place 10 11
# shellcheck disable=SC2086 # one argument per service
compose config --format json $REWRITERS > "$WORK/config.json"
python3 - "$WORK/config.json" "$PAIRS" <<'EOF' || fail "a rewriter does not restart with its PostgREST"
import json, sys
services = json.load(open(sys.argv[1]))["services"]
for line in sys.argv[2].splitlines():
    rewriter, postgrest, _ = line.split()
    dep = services[rewriter].get("depends_on", {}).get(postgrest, {})
    if dep.get("condition") != "service_healthy" or dep.get("restart") is not True:
        sys.exit(f"{rewriter} depends_on {postgrest}: {dep}")
EOF
echo "ok    every rewriter depends on its PostgREST with restart: true"

######### Control: without restart: true #########

EXTRA_FILES=("$WORK/no-restart.yaml")
up 1 10 11
all_answer_own "control: every rewriter answers with its own app at start"
swap
right=""
while read -r rewriter _ title; do
  got=$(answer "$rewriter")
  echo "      $rewriter answers \"$got\" (its app: $title)"
  [ "$got" != "$title" ] || right+=" $rewriter"
done <<< "$PAIRS"
[ -z "$right" ] || fail "control: without restart: true,$right still answer with their own app, so the test cannot see the bug"
echo "ok    control: without restart: true, every rewriter answers wrongly"
down || fail "down failed"

######### With the stack's depends_on #########

EXTRA_FILES=()
up 1 10 11
all_answer_own "every rewriter answers with its own app at start"
swap "PostgREST recreated by up -d, every rewriter follows"
all_answer_own "PostgREST swapped by up -d, every rewriter follows"

started=$(inspect hafah-postgrest-rewriter "c['State']['StartedAt']")
compose restart hafah-postgrest >/dev/null 2>&1 || fail "restart hafah-postgrest failed"
[ "$(inspect hafah-postgrest-rewriter "c['State']['StartedAt']")" != "$started" ] ||
  fail "restart hafah-postgrest did not restart hafah-postgrest-rewriter"
all_answer_own "hafah-postgrest restarted, its rewriter restarted with it"

echo "PASS postgrest-rewriter-recreate"
