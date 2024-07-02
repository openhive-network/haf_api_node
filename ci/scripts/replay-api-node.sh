#!/bin/bash

set -e
     
echo -e "\e[0Ksection_start:$(date +%s):check[collapsed=true]\r\e[0KChecking replay status..."
while [[ -f "${REPLAY_DIRECTORY:?}/replay_running" ]]
do
    echo "Another replay is running in ${REPLAY_DIRECTORY:?}. Waiting for it to end..."
    sleep 60
done
if [[ -f "${REPLAY_DIRECTORY:?}/status" ]]
then
    echo "Previous replay exit code"
    status=$(cat "${REPLAY_DIRECTORY:?}/status")
    echo "$status"
    if [[ "$status" -eq 0 ]]
    then
        echo "Previous replay datadir is valid, exiting"
        exit 0
    fi
fi

echo "Didn't find a valid replay, performing a fresh one..."
ls "${REPLAY_DIRECTORY:?}" -lath
rm "${REPLAY_DIRECTORY:?}/*" -rf
touch "${REPLAY_DIRECTORY:?}/replay_running"
echo -e "\e[0Ksection_end:$(date +%s):check\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):prepare[collapsed=true]\r\e[0KPreparing replay directory..."
echo "Hardlinking the block_log..."
mkdir -p "${REPLAY_DIRECTORY:?}/blockchain"
cp -u "${BLOCK_LOG_SOURCE_DIR:?}/block_log" "${REPLAY_DIRECTORY:?}/..${BLOCK_LOG_SOURCE_DIR:?}/block_log"
ln "${REPLAY_DIRECTORY:?}/..${BLOCK_LOG_SOURCE_DIR:?}/block_log" "${REPLAY_DIRECTORY:?}/blockchain/block_log"
if [[ -e "${BLOCK_LOG_SOURCE_DIR:?}/block_log.artifacts" ]]
then
    echo "Copying the artifacts file..." 
    cp "${BLOCK_LOG_SOURCE_DIR:?}/block_log.artifacts" "${REPLAY_DIRECTORY:?}/blockchain/block_log.artifacts"
fi
chown -R 1000:100 "${REPLAY_DIRECTORY:?}/blockchain"
echo -e "\e[0Ksection_end:$(date +%s):prepare\r\e[0K"

echo -e "\e[0Ksection_start:$(date +%s):replay[collapsed=true]\r\e[0KReplaying HAF API node..."
docker-entrypoint.sh docker version

cd /haf-api-node
docker-entrypoint.sh docker compose up --detach --quiet-pull

cd "${CI_PROJECT_DIR:?}"
count=0
until [[ $(docker-entrypoint.sh docker exec --env LC_ALL="C" haf-world-hivemind-block-processing-1 psql "${HAF_DB_URL:?}" --quiet --tuples-only --no-align --command "${PSQL_COMMAND:?}") == "${LAST_BLOCK_NUMBER:?}" ]]
do
    CURRENT_BLOCK=$(docker-entrypoint.sh docker exec --env LC_ALL="C" haf-world-hivemind-block-processing-1 psql "${HAF_DB_URL:?}" --quiet --tuples-only --no-align --command "${PSQL_COMMAND:?}")
    echo -e "Waiting for Hivemind replay to finish...\n Current block: ${CURRENT_BLOCK:?}"
    count=$((count+10))
    [[ $count -eq 6000 ]] && exit 1
    sleep 10s
done

cd /haf-api-node
docker-entrypoint.sh docker compose stop

cd "${CI_PROJECT_DIR:?}"
status=$(docker-entrypoint.sh docker inspect haf-world-haf-1 --format="{{.State.ExitCode}}")
echo "${status}" > "${REPLAY_DIRECTORY:?}/status"
echo -e "\e[0Ksection_end:$(date +%s):replay\r\e[0K"