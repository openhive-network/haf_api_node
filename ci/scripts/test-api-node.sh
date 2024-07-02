#!/bin/bash

set -e

echo -e "\nWaiting for Docker to start..."
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

echo -e "\nWaiting for HAproxy to start..."
count=0
until [[ $(docker inspect --format "{{.State.Health.Status}}" haf-world-haproxy-1) == "healthy" ]]
do
    echo "Waiting for HAproxy to start..."
    count=$((count+10))
    [[ $count -eq 600 ]] && exit 1
    sleep 10s
done

echo -e "\nChecking HAproxy state..."
docker exec haf-world-haproxy-1 sh -c "echo 'show servers conn' | socat stdio unix-connect:/run/haproxy/admin.sock"
docker exec haf-world-haproxy-1 sh -c "echo 'show servers state' | socat stdio unix-connect:/run/haproxy/admin.sock"

echo -e "\nCaddy configuration... (saved to caddy-autosave.json)"
docker exec haf-world-caddy-1 sh -c "cat /config/caddy/autosave.json" | jq > caddy-autosave.json

echo -e "\nTesting endpoints...\nHive (via container link, simulating CI service)..."
docker run --rm --link "haf-world-caddy-1:${PUBLIC_HOSTNAME:?}" --network haf curlimages/curl:8.8.0 -vk -X POST --data '{"jsonrpc":"2.0", "method":"condenser_api.get_block", "params":[1], "id":1}' "https://${PUBLIC_HOSTNAME:?}/"

echo -e "\nHive directly..."
curl -vk --data '{"jsonrpc":"2.0", "method":"condenser_api.get_block", "params":[1], "id":1}' "https://${PUBLIC_HOSTNAME:?}/"

echo -e "\nHAfAH..."
curl -vk -X POST "https://${PUBLIC_HOSTNAME:?}/hafah/get_version"

echo -e "\nHivemind..."
curl -vk --data '{"jsonrpc":"2.0", "method":"condenser_api.get_trending_tags", "id":1}' "https://${PUBLIC_HOSTNAME:?}/"