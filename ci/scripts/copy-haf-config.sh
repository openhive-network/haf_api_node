#!/bin/bash

set -e

echo "Performing additional configuration..."

echo "Copying config.ini file..."
cp "/haf-api-node/ci/config.ini" "${REPLAY_DIRECTORY:?}/config.ini"

echo "Inspecting replay directory..."
ls -lah "${REPLAY_DIRECTORY:?}"
ls -lah "${REPLAY_DIRECTORY:?}/blockchain"