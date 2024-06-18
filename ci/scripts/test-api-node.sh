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

echo -e "\e[0Ksection_start:$(date +%s):haproxy[collapsed=true]\r\e[0KWaiting for HAproxy to start..."
count=0
until [[ $(docker inspect --format "{{.State.Health.Status}}" haf-world-haproxy-1) == "healthy" ]]
do
    echo "Waiting for HAproxy to start..."
    count=$((count+10))
    [[ $count -eq 600 ]] && exit 1
    sleep 10s
done
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