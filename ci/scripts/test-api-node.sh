#!/bin/bash

set -e

echo -e "\e[0Ksection_start:$(date +%s):docker[collapsed=true]\r\e[0KWaiting for Docker to start..."
count=0
until docker version &>/dev/null
do
    echo "Waiting for Docker to start..."
    count=$((count+5))
    [[ $count -eq 600 ]] && exit 1
    sleep 5s
done

echo "Docker info (saved to docker-info.txt)"
docker info > docker-info.txt

echo -e "\nDocker processes"
docker ps --all

echo -e "\nDocker networks"
docker network ls
echo -e "\e[0Ksection_end:$(date +%s):docker\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):haproxy[collapsed=true]\r\e[0KWaiting for certain services to start..."

function wait-for-service(){
    local service="$1"          # service name in docker-compose.yml
    local format="$2"
    local expected_status="$3"
    echo "Waiting for ${service} to start..."
    count=0
    local container=""

    # Wait until the container exists
    until [[ -n "$container" ]]; do
        container=$(cd /haf-api-node && docker compose ps -q "${service}")
        if [[ -z "$container" ]]; then
            echo "Container for ${service} not created yet..."
            count=$((count+10))
            [[ $count -ge 600 ]] && { echo "Timeout waiting for ${service} container."; exit 1; }
            sleep 10s
        fi
    done

    until [[ $(docker inspect --format "${format}" "${container}") == "${expected_status}" ]]; do
        echo "Waiting for ${service} to start..."
        count=$((count+10))
        [[ $count -eq 600 ]] && exit 1
        sleep 10s
    done
    echo "Done! ${service} has started successfully."
}
wait-for-service "haf" "{{.State.Health.Status}}" "healthy"
wait-for-service "hafah-postgrest" "{{.State.Status}}" "running"
wait-for-service "hivemind-postgrest-server" "{{.State.Status}}" "running"
wait-for-service "haproxy" "{{.State.Health.Status}}" "healthy"

# Sleep for additional 30s to ensure HAproxy has time to connect to all the servers
sleep 30s

echo -e "\e[0Ksection_end:$(date +%s):haproxy\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):haproxy_state[collapsed=true]\r\e[0KChecking HAproxy state..."
(cd /haf-api-node && docker compose exec haproxy sh -c "echo 'show servers conn' | socat stdio unix-connect:/run/haproxy/admin.sock")
(cd /haf-api-node && docker compose exec haproxy sh -c "echo 'show servers state' | socat stdio unix-connect:/run/haproxy/admin.sock")
echo -e "\e[0Ksection_end:$(date +%s):haproxy_state\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):caddy[collapsed=true]\r\e[0KCaddy configuration... (saved to caddy-autosave.json)"
(cd /haf-api-node && docker compose exec caddy sh -c "cat /config/caddy/autosave.json" | jq | tee caddy-autosave.json)
echo -e "\e[0Ksection_end:$(date +%s):caddy\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):hive_link[collapsed=true]\r\e[0KTesting endpoints... Hive (via container link, simulating CI service)..."
caddy_id=$(cd /haf-api-node && docker compose ps -q caddy)
net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' "$caddy_id" | head -n1)
caddy_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$caddy_id")

docker run --rm --network "$net" curlimages/curl:8.8.0 -vk -X POST \
  --resolve "${PUBLIC_HOSTNAME:?}:443:${caddy_ip:?}" \
  --data '{"jsonrpc":"2.0","method":"condenser_api.get_block","params":[1],"id":1}' \
  "https://${PUBLIC_HOSTNAME:?}/"
echo -e "\e[0Ksection_end:$(date +%s):hive_link\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):hive[collapsed=true]\r\e[0KHive directly..."
curl -k --data '{"jsonrpc":"2.0", "method":"condenser_api.get_block", "params":[1], "id":1}' --trace-ascii hive-output.log "https://${PUBLIC_HOSTNAME:?}/"
cat hive-output.log
echo -e "\e[0Ksection_end:$(date +%s):hive\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):hafah[collapsed=true]\r\e[0KHAfAH..."
curl -k --data '{"jsonrpc":"2.0", "method":"block_api.get_block", "params":{"block_num":1}, "id":1}' --trace-ascii hafah-output.log "https://${PUBLIC_HOSTNAME:?}/"
cat hafah-output.log
echo -e "\e[0Ksection_end:$(date +%s):hafah\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):hivemind[collapsed=true]\r\e[0KHivemind..."
curl -k --data '{"jsonrpc":"2.0", "method":"condenser_api.get_blog", "params":["steem", 0, 1], "id":1}' --trace-ascii hivemind-output.log "https://${PUBLIC_HOSTNAME:?}/"

cat hivemind-output.log
echo -e "\e[0Ksection_end:$(date +%s):hivemind\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):check[collapsed=true]\r\e[0KChecking test results..."
function check-log-for-errors() {
    local logfile="$1"
    echo "Checking file ${logfile} for errors..."
    grep -i '"error"' "${logfile}" && exit 1 || echo "No errors found!"
}
check-log-for-errors hive-output.log
check-log-for-errors hafah-output.log
check-log-for-errors hivemind-output.log
echo -e "\e[0Ksection_end:$(date +%s):check\r\e[0K"
