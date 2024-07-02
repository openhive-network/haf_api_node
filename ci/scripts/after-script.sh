#!/bin/bash

set -e

cd /haf-api-node
docker compose ps --all > "${CI_PROJECT_DIR:?}/compose_processes.txt"
docker compose logs --no-color > "${CI_PROJECT_DIR:?}/haf_api_node.log"
docker compose down --volumes
cd "${CI_PROJECT_DIR:?}"
rm -f "${REPLAY_DIRECTORY:?}/replay_running"