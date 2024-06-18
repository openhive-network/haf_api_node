#!/bin/bash

#!/bin/bash

set -e

if [[ -f "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log" ]]
then
  mv -v "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log" "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.$(date +"%d-%m-%y-%H-%M-%S").log"
fi

# Create log file and make it readable for anyone
touch "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log"
chmod 666 "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log"
chown 1000:100 "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log"

{
  /haf-api-node/ci/scripts/set-up-stack.sh

  echo "Waiting for Docker to start..."
  until docker-entrypoint.sh docker version &>/dev/null
  do 
    echo "Waiting for Docker to start..."
    sleep 10
  done

  # Necessary for GitLab CI service healthcheck
  httpd

  docker-entrypoint.sh docker compose "$@"
} 2>&1 | tee -a "${TOP_LEVEL_DATASET_MOUNTPOINT}/logs/haf-api-node.log"
