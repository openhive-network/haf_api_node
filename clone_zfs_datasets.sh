#! /bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] [--swap-logs-with-dataset=dataset] snapshot-name new-top-level-dataset"
  echo "  --swap-logs-with-dataset  the snapshot was taken by snapshot_zfs_datasets.sh with this option, so"
  echo "                            <top-level>/logs and <top-level>/hivesense/ollama carry no snapshot; their"
  echo "                            snapshots live on the stand-in dataset given here (the same argument that was"
  echo "                            passed at snapshot time). Clone those two from the stand-in instead, keeping"
  echo "                            the real datasets' properties, so the clone gets an empty logs dataset and"
  echo "                            an empty ollama dataset (models are re-downloaded on first use)."
}

OPTIONS=$(getopt -o he:l: --long env-file:,help,zpool:,top-level-dataset:,swap-logs-with-dataset: -n "$0" -- "$@")

if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

ZPOOL=""
TOP_LEVEL_DATASET=""
ZPOOL_MOUNT_POINT=""
TOP_LEVEL_DATASET_MOUNTPOINT=""
SWAP_LOGS_DATASET=""

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
    --swap-logs-with-dataset|-l)
      SWAP_LOGS_DATASET="$2"
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

# In swap mode the logs and hivesense/ollama datasets carry no @SNAPSHOT_NAME (they were
# swapped with empty stand-ins while the snapshot was taken); their snapshots live on the
# stand-in dataset, so clone those two from there.  Verify that up front: the checks
# double as a guard against passing the option for a snapshot taken without it (and
# vice versa), which would otherwise fail halfway through with a partial clone.
if [ -n "$SWAP_LOGS_DATASET" ]; then
  for swapped in logs hivesense/ollama; do
    if ! zfs list "$SWAP_LOGS_DATASET/$swapped@$SNAPSHOT_NAME" >/dev/null 2>&1; then
      echo "ERROR: $SWAP_LOGS_DATASET/$swapped@$SNAPSHOT_NAME does not exist. Either the stand-in dataset"
      echo "is wrong or the snapshot was taken WITHOUT --swap-logs-with-dataset; re-run without that option."
      exit 1
    fi
  done
  if zfs list "$ZPOOL/$TOP_LEVEL_DATASET/logs@$SNAPSHOT_NAME" >/dev/null 2>&1; then
    echo "ERROR: $ZPOOL/$TOP_LEVEL_DATASET/logs@$SNAPSHOT_NAME exists, so this snapshot appears to have been"
    echo "taken WITHOUT --swap-logs-with-dataset. Re-run without that option."
    exit 1
  fi
elif ! zfs list "$ZPOOL/$TOP_LEVEL_DATASET/logs@$SNAPSHOT_NAME" >/dev/null 2>&1; then
  echo "ERROR: $ZPOOL/$TOP_LEVEL_DATASET/logs@$SNAPSHOT_NAME does not exist."
  echo "If this snapshot was taken with snapshot_zfs_datasets.sh's --swap-logs-with-dataset option,"
  echo "pass the same option (and dataset) to this script."
  exit 1
fi

# Get all datasets under the top-level dataset
# This will automatically include comments-rocksdb-storage if it exists, and skip it if it doesn't
set -- $(zfs list -r -H -o name -s mountpoint "$ZPOOL/$TOP_LEVEL_DATASET")

for dataset; do
  new_dataset="$(echo "$dataset" | sed "s|$ZPOOL/$TOP_LEVEL_DATASET|$ZPOOL/$NEW_TOP_LEVEL_DATASET|")"
  # Properties always come from the real dataset, even when the snapshot is cloned from the
  # stand-in, so the clone's logs/ollama datasets get the same compression etc. as the originals
  new_options="$(zfs get -H -o property,value -s local,received all "$dataset" | sed 's/^\([^=]*\)\t\(.*\)$/-o \1=\2/g')"
  source_snapshot="$dataset@$SNAPSHOT_NAME"
  if [ -n "$SWAP_LOGS_DATASET" ]; then
    case "$dataset" in
      "$ZPOOL/$TOP_LEVEL_DATASET"/logs|"$ZPOOL/$TOP_LEVEL_DATASET"/hivesense/ollama)
        source_snapshot="$SWAP_LOGS_DATASET/${dataset#"$ZPOOL/$TOP_LEVEL_DATASET/"}@$SNAPSHOT_NAME"
        ;;
    esac
  fi
  echo "cloning $source_snapshot to $new_dataset with $new_options"
  zfs clone -p $new_options "$source_snapshot" "$new_dataset"
done
