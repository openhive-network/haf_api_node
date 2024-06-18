#!/bin/bash

set -e

echo "Copying replay data to ${REPLAY_PIPELINE_DIRECTORY:?}"
cp -a "${REPLAY_DIRECTORY:?}" "${REPLAY_PIPELINE_DIRECTORY:?}"