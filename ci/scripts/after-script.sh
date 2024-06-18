#!/bin/bash

set -e

# If Docker CLI is available try and use it to obtain logs
if command -v docker &> /dev/null
then

  EXPECTED_SERVICES=(
      caddy-1
      haf-1
      hafah-install-1
      hafah-postgrest-1
      haproxy-1
      haproxy-healthchecks-1
      hivemind-block-processing-1
      hivemind-server-1
      jussi-1
      pgadmin-1
      pghero-1
      redis-1
      swagger-1
      varnish-1
      version-display-1
  )

  cd /haf-api-node

  echo "Getting a list of services..."
  docker compose ps --all > "${CI_PROJECT_DIR:?}/compose_processes.txt"

  echo "Fetching stack logs..."
  docker compose logs --no-color > "${CI_PROJECT_DIR:?}/haf_api_node.log"

  for SERVICE in "${EXPECTED_SERVICES[@]}"; do
    echo "Getting status of $SERVICE..."
    # Do not exit the script if the service is mising
    docker inspect --format "{{json .State}}" "haf-world-${SERVICE}" > "${CI_PROJECT_DIR:?}/${SERVICE}-status.json" || true
  done

  docker compose down --volumes

fi

cd "${CI_PROJECT_DIR:?}"

cp -R "${TOP_LEVEL_DATASET_MOUNTPOINT:?}/logs" "${CI_PROJECT_DIR:?}/logs"
rm -f "${REPLAY_DIRECTORY:?}/replay_running"