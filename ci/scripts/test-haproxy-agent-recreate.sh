#!/usr/bin/env bash
#
# Test that HAProxy's agent checks follow a recreated haproxy-healthchecks container.  Runs the
# stack's haproxy configs (haproxy/*.cfg) in the haproxy base image on a throwaway docker network,
# with one stub container answering every agent-checked server's health check and another, aliased
# haproxy-healthchecks, answering every agent port.  The agent first says "down"; it is then
# recreated on a new IP saying "up", and every agent-checked server must come back UP with
# agent_status L7OK (polled with "show stat" on the admin socket) without restarting haproxy.
# Finally haproxy itself is recreated and must see the agent again.
# Needs a docker daemon; skips (exit 0) with the reason when there is none.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
HAPROXY_IMAGE=${HAPROXY_IMAGE:-$(sed -n 's/^FROM //p' "$REPO_DIR/haproxy/Dockerfile")}
# Two 10s agent intervals plus DNS re-resolution and check scheduling slack.
AGENT_TIMEOUT=${AGENT_TIMEOUT:-30}

skip() {
  echo "SKIP haproxy-agent-recreate: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  [ -z "${NAME:-}" ] || docker logs --tail 30 "$NAME-haproxy" 2>&1 || true
  exit 1
}

command -v docker >/dev/null || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "no docker daemon"

NAME=agent-recreate-$$
cleanup() {
  docker rm -f "$NAME-haproxy" "$NAME-app" "$NAME-agent" "$NAME-filler" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
WORK=$(mktemp -d)
trap cleanup EXIT

######### What the config agent-checks #########

# "<host> <port> <agent port>" for every agent-checked server-template.
sed -n 's/^ *server-template [^ ]* 1 \([^: ]*\):\([0-9]*\) .*agent-check.* agent-port \([0-9]*\).*/\1 \2 \3/p' \
  "$REPO_DIR/haproxy/30-proxies.cfg" > "$WORK/servers"
EXPECTED=$(wc -l < "$WORK/servers")
[ "$EXPECTED" -gt 0 ] || fail "found no agent-checked servers in haproxy/30-proxies.cfg"
HOSTS=$(cut -d' ' -f1 "$WORK/servers" | sort -u)
SERVER_PORTS=$(cut -d' ' -f2 "$WORK/servers" | sort -u | tr '\n' ' ')
# The agent listens on the port the relay forwards each agent port to.
AGENT_PORTS=$(awk '{print $3 - 20000}' "$WORK/servers" | sort -u | tr '\n' ' ')

mkdir "$WORK/cfg"
cp "$REPO_DIR"/haproxy/[0-9]*.cfg "$WORK/cfg/"

######### Stub containers #########

docker network create "$NAME" >/dev/null

# Listener scripts, copied into the stub containers (the docker daemon need not share this
# filesystem). Any request gets a 200 once its headers are read (closing on unread input would
# reset the connection), so httpchk and plain TCP checks both pass.
mkdir "$WORK/stub"
cat > "$WORK/stub/http.sh" <<'EOF'
#!/bin/sh
while read -r line && [ -n "${line%$(printf '\r')}" ]; do :; done
printf 'HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n'
EOF
cat > "$WORK/stub/agent.sh" <<'EOF'
#!/bin/sh
cat /stub/state
EOF
cat > "$WORK/stub/listen.sh" <<'EOF'
#!/bin/sh
# listen.sh SCRIPT PORT...: serve SCRIPT on every PORT.
script=$1; shift
for port in "$@"; do nc -lk -p "$port" -e "$script" & done
wait
EOF
chmod +x "$WORK/stub/"*.sh

# run_stub NAME DOCKER-ARGS... -- LISTEN-ARGS...
run_stub() {
  local name=$1 args=()
  shift
  while [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  docker create --name "$name" --network "$NAME" "${args[@]}" --user root --entrypoint /stub/listen.sh \
    "$HAPROXY_IMAGE" "$@" >/dev/null
  docker cp "$WORK/stub" "$name:/stub" >/dev/null
  docker start "$name" >/dev/null
}

alias_args=()
for host in $HOSTS; do alias_args+=(--network-alias "$host"); done
# shellcheck disable=SC2086 # one argument per port
run_stub "$NAME-app" "${alias_args[@]}" -- /stub/http.sh $SERVER_PORTS

# start_agent STATE: run the agent, answering STATE on every agent port.
start_agent() {
  echo "$1" > "$WORK/stub/state"
  # shellcheck disable=SC2086 # one argument per port
  run_stub "$NAME-agent" --network-alias haproxy-healthchecks -- /stub/agent.sh $AGENT_PORTS
}

agent_ip() {
  docker inspect "$NAME-agent" | python3 -c "
import json, sys
print(json.load(sys.stdin)[0]['NetworkSettings']['Networks']['$NAME']['IPAddress'])"
}

start_haproxy() {
  docker create --name "$NAME-haproxy" --network "$NAME" --user root --entrypoint sh "$HAPROXY_IMAGE" \
    -c 'mkdir -p /run/haproxy && exec haproxy -W -db -f /usr/local/etc/haproxy/cfg' >/dev/null
  docker cp "$WORK/cfg" "$NAME-haproxy:/usr/local/etc/haproxy/cfg" >/dev/null
  docker start "$NAME-haproxy" >/dev/null
}

haproxy_started_at() {
  docker inspect "$NAME-haproxy" | python3 -c "import json, sys; print(json.load(sys.stdin)[0]['State']['StartedAt'])"
}

######### Polling #########

# "<proxy>/<server> <status> <agent_status> <check_status>" for every agent-checked server.
agent_stats() {
  docker exec "$NAME-haproxy" sh -c 'echo "show stat" | socat - /run/haproxy/admin.sock' 2>/dev/null |
    awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
             $col["agent_status"] != "" { print $1 "/" $2, $col["status"], $col["agent_status"], $col["check_status"] }'
}

# wait_for STATUS AGENT_STATUS WHAT: within AGENT_TIMEOUT, every agent-checked server is in STATUS
# with AGENT_STATUS while its health check passes (so a DOWN comes from the agent).
wait_for() {
  local deadline=$((SECONDS + AGENT_TIMEOUT)) stats
  while :; do
    stats=$(agent_stats || true)
    if [ "$(echo "$stats" | grep -c .)" -eq "$EXPECTED" ] &&
       ! echo "$stats" | grep -vqE "^[^ ]+ $1( \(agent\))? (\* )?$2 (\* )?L[47]OK$"; then
      echo "ok    $3 ($((AGENT_TIMEOUT - deadline + SECONDS))s)"
      return
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "$3: not every agent-checked server is $1/$2 after ${AGENT_TIMEOUT}s:
$stats"
    sleep 1
  done
}

######### Recreate the agent #########

start_agent down
start_haproxy
STARTED_AT=$(haproxy_started_at)
wait_for DOWN L7STS "$EXPECTED agent-checked servers marked down by the agent"

OLD_IP=$(agent_ip)
docker rm -f "$NAME-agent" >/dev/null
# Hold the old address so the new agent cannot reuse it.
docker run -d --name "$NAME-filler" --network "$NAME" --entrypoint sleep "$HAPROXY_IMAGE" 600 >/dev/null
start_agent up
NEW_IP=$(agent_ip)
[ "$NEW_IP" != "$OLD_IP" ] || fail "the recreated agent kept $OLD_IP"

wait_for UP L7OK "agent recreated ($OLD_IP -> $NEW_IP), every server back UP"
[ "$(haproxy_started_at)" = "$STARTED_AT" ] || fail "haproxy restarted"

######### Recreate haproxy #########

docker rm -f "$NAME-haproxy" >/dev/null
start_haproxy
wait_for UP L7OK "haproxy recreated, every server UP"

echo "PASS haproxy-agent-recreate"
