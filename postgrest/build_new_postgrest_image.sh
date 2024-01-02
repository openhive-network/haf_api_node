#! /bin/sh
POSTGREST_VERSION="$1"
if [ -z "$POSTGREST_VERSION" ]; then
  echo "Usage: $0 version_number"
  exit 1
fi

IMAGE_BASE=registry.gitlab.syncad.com/hive/haf_api_node/postgrest

docker build --build-arg="POSTGREST_VERSION=$POSTGREST_VERSION" --tag="${IMAGE_BASE}:${POSTGREST_VERSION}" --tag="${IMAGE_BASE}:latest" .
