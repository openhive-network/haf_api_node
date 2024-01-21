#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] snapshot-name new-top-level-dataset"
}

OPTIONS=$(getopt -o he: --long env-file:,help,zpool:,top-level-dataset: -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e)
      ENV_FILE="$2"
      shift 2
      ;;
    --zpool)
      ZPOOL="$2"
      shift 2
      ;;
    --top-level-dataset)
      TOP_LEVEL_DATASET="$2"
      shift 2
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
  esac
done

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  if [ ! -z "$ENV_FILE" ]; then
    echo reading $ENV_FILE
    . $ENV_FILE
  elif [ -f .env ]; then
    echo reading configuration from .env
    . ./.env
  else
    echo "You must either provide an --env-file argument or both a --zpool and --top-level-dataset"
    echo "argument to tell this script what datasets to snapshot."
    exit 1
  fi
fi

if [ -z "$ZPOOL" -o -z "$TOP_LEVEL_DATASET" ]; then
  echo "Your environment file must define the ZPOOL and TOP_LEVEL_DATASET environment variables"
  exit 1
fi

SNAPSHOT_NAME="$1"
if [ -z "$SNAPSHOT_NAME" ]; then
  echo "No snapshot name provided"
  exit 1
fi
shift

NEW_TOP_LEVEL_DATASET="$1"
if [ -z "$NEW_TOP_LEVEL_DATASET" ]; then
  echo "No new top-level dataset name provided"
  exit 1
fi
shift

case "$NEW_TOP_LEVEL_DATASET" in
  "$TOP_LEVEL_DATASET"/*)
    echo "The cloned dataset can't be under the old top-level dataset"
    exit 1
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

set -- $(zfs list -r -H -o name -s mountpoint "$ZPOOL/$TOP_LEVEL_DATASET")

for dataset; do
  new_dataset="$(echo "$dataset" | sed "s|$ZPOOL/$TOP_LEVEL_DATASET|$ZPOOL/$NEW_TOP_LEVEL_DATASET|")"
  new_options="$(zfs get -H -o property,value -s local,received all "$dataset" | sed 's/^\([^=]*\)\t\(.*\)$/-o \1=\2/g')"
  echo "cloning dataset $dataset to $new_dataset with $new_options"
  zfs clone -p $new_options "$dataset@$SNAPSHOT_NAME" "$new_dataset"
done
