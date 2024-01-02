#! /bin/sh

print_help() {
  echo "Usage: $0 [--publish] version_number"
}

if ! OPTIONS=$(getopt -o '' --long publish -n "$0" -- "$@"); then
    print_help
    exit 1
fi

eval set -- "$OPTIONS"

PUBLISH=false
while true; do
  case $1 in
    --publish)
      PUBLISH=true
      shift
      ;;
    --)
      shift
      break
      ;;
  esac
done

if [ $# -ne 1 ]; then
    print_help
    exit 1
fi
POSTGREST_VERSION="$1"

IMAGE_BASE=registry.gitlab.syncad.com/hive/haf_api_node/postgrest

docker build --build-arg="POSTGREST_VERSION=$POSTGREST_VERSION" --tag="${IMAGE_BASE}:${POSTGREST_VERSION}" --tag="${IMAGE_BASE}:latest" .
if [ "$PUBLISH" = "true" ]; then
  docker push "${IMAGE_BASE}:${POSTGREST_VERSION}"
  docker push "${IMAGE_BASE}:latest"
fi
