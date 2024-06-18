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
    local service="$1"
    local format="$2"
    local expected_status="$3"
    echo "Waiting for ${service} to start..."
    count=0
    until [[ $(docker inspect --format "${format}" "${service}") == "${expected_status}" ]]
    do
        echo "Waiting for ${service} to start..."
        count=$((count+10))
        [[ $count -eq 600 ]] && exit 1
        sleep 10s
    done
    echo "Done! ${service} has started successfully."
}

wait-for-service "haf-world-haf-1" "{{.State.Health.Status}}" "healthy"
wait-for-service "haf-world-hafah-postgrest-1" "{{.State.Status}}" "running"
wait-for-service "haf-world-hivemind-server-1" "{{.State.Status}}" "running"
wait-for-service "haf-world-haproxy-1" "{{.State.Health.Status}}" "healthy"

echo -e "\e[0Ksection_end:$(date +%s):haproxy\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):haproxy_state[collapsed=true]\r\e[0KChecking HAproxy state..."
docker exec haf-world-haproxy-1 sh -c "echo 'show servers conn' | socat stdio unix-connect:/run/haproxy/admin.sock"
docker exec haf-world-haproxy-1 sh -c "echo 'show servers state' | socat stdio unix-connect:/run/haproxy/admin.sock"
echo -e "\e[0Ksection_end:$(date +%s):haproxy_state\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):caddy[collapsed=true]\r\e[0KCaddy configuration... (saved to caddy-autosave.json)"
docker exec haf-world-caddy-1 sh -c "cat /config/caddy/autosave.json" | jq | tee caddy-autosave.json
echo -e "\e[0Ksection_end:$(date +%s):caddy\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):hive_link[collapsed=true]\r\e[0KTesting endpoints... Hive (via container link, simulating CI service)..."
docker run --rm --link "haf-world-caddy-1:${PUBLIC_HOSTNAME:?}" --network haf curlimages/curl:8.8.0 -vk -X POST --data '{"jsonrpc":"2.0", "method":"condenser_api.get_block", "params":[1], "id":1}' "https://${PUBLIC_HOSTNAME:?}/"
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
curl -k --data '{"jsonrpc":"2.0", "method":"condenser_api.get_trending_tags", "id":1}' --trace-ascii hivemind-output.log "https://${PUBLIC_HOSTNAME:?}/"
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