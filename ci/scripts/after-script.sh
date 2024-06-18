#!/bin/bash

set -e

# If Docker CLI is available try and use it to obtain logs
if command -v docker &> /dev/null
then

  cd /haf-api-node

  echo "Getting a list of services..."
  docker compose ps --all --format json > "${CI_PROJECT_DIR:?}/compose_processes.json"

  echo "Fetching stack logs..."
  docker compose logs --no-color > "${CI_PROJECT_DIR:?}/haf_api_node.log"
 
  echo "Getting status of services..."
  docker ps --all --format "{{.Names}}" | xargs -I {} bash -c "docker inspect --format \"{{json .State}}\" \"{}\" > \"{}.json\""

  echo "Shutting down the stack..."
  docker compose down --volumes
fi

cd "${CI_PROJECT_DIR:?}"

cp -R "${TOP_LEVEL_DATASET_MOUNTPOINT:?}/logs" "${CI_PROJECT_DIR:?}/logs"
rm -f "${REPLAY_DIRECTORY:?}/replay_running"