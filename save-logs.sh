#!/bin/bash

set -e

trap 'echo "Script failed at line $LINENO with exit code $?"' ERR

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Save docker compose logs and on-disk hived/PostgreSQL logs for all services
to a timestamped directory. Logs are compressed with zstd by default.

OPTIONS:
  --stack-dir=DIR           Path to haf_api_node stack (default: cwd)
  --output-dir=DIR          Base directory for logs (default: logs/ relative to cwd)
  --no-compress             Skip zstd compression (default: compress)
  --services=svc1,svc2,...  Override auto-detection with specific service list
  --no-disk-logs            Skip on-disk hived/PostgreSQL/entrypoint logs
  --help                    Show this help message

EXAMPLES:
  # Save logs for all running services
  $0 --stack-dir=/path/to/stack

  # Save without compression
  $0 --no-compress

  # Save only specific services
  $0 --services=haf,hivemind-block-processing
EOF
}

# Default values
STACK_DIR=""
OUTPUT_DIR="logs"
COMPRESS=1
SERVICES=""
DISK_LOGS=1

# Parse command line arguments
OPTIONS=$(getopt -o h --long help,stack-dir:,output-dir:,no-compress,no-disk-logs,services: -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    print_help
    exit 1
fi

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --stack-dir)
      STACK_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --no-compress)
      COMPRESS=0
      shift
      ;;
    --no-disk-logs)
      DISK_LOGS=0
      shift
      ;;
    --services)
      SERVICES="$2"
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

# Resolve stack directory
if [ -z "$STACK_DIR" ]; then
  if [ -f "compose.yml" ] || [ -f "docker-compose.yml" ]; then
    STACK_DIR="$(pwd)"
  else
    echo "Error: No compose.yml found in current directory. Use --stack-dir to specify the stack location."
    exit 1
  fi
fi

if [ ! -f "$STACK_DIR/compose.yml" ] && [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
  echo "Error: No compose.yml found in $STACK_DIR"
  exit 1
fi

# Determine services to save
if [ -n "$SERVICES" ]; then
  SERVICE_LIST=$(echo "$SERVICES" | tr ',' ' ')
else
  SERVICE_LIST=$(cd "$STACK_DIR" && docker compose ps -a --services 2>/dev/null) || {
    echo "Error: Failed to list services. Is docker compose working in $STACK_DIR?"
    exit 1
  }
fi

if [ -z "$SERVICE_LIST" ]; then
  echo "No services found to save logs for."
  exit 0
fi

# Create timestamped output directory
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR="${OUTPUT_DIR}/${TIMESTAMP}"
mkdir -p "$LOG_DIR"

echo "============================================="
echo "Saving logs"
echo "============================================="
echo "Stack:      $STACK_DIR"
echo "Output:     $LOG_DIR"
echo "Compress:   $( [ $COMPRESS -eq 1 ] && echo 'yes (zstd)' || echo 'no' )"
echo ""

compress_file() {
  local file="$1"
  if [ $COMPRESS -eq 1 ]; then
    if command -v zstd >/dev/null 2>&1; then
      zstd --rm -q "$file"
    fi
  fi
}

TOTAL_SIZE=0
SERVICE_COUNT=0

for service in $SERVICE_LIST; do
  echo -n "Saving $service... "

  LOG_FILE="$LOG_DIR/$service.log"
  (cd "$STACK_DIR" && docker compose logs --timestamps "$service" > "$LOG_FILE" 2>/dev/null) || {
    echo "no logs (skipped)"
    rm -f "$LOG_FILE"
    continue
  }

  if [ ! -s "$LOG_FILE" ]; then
    echo "empty (skipped)"
    rm -f "$LOG_FILE"
    continue
  fi

  RAW_SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  RAW_SIZE_MB=$(echo "scale=1; $RAW_SIZE / 1048576" | bc)

  if [ $COMPRESS -eq 1 ]; then
    if command -v zstd >/dev/null 2>&1; then
      zstd --rm -q "$LOG_FILE"
      COMPRESSED_SIZE=$(stat -c %s "${LOG_FILE}.zst" 2>/dev/null || echo 0)
      COMPRESSED_SIZE_MB=$(echo "scale=1; $COMPRESSED_SIZE / 1048576" | bc)
      echo "${RAW_SIZE_MB}MB -> ${COMPRESSED_SIZE_MB}MB"
      TOTAL_SIZE=$((TOTAL_SIZE + COMPRESSED_SIZE))
    else
      echo "${RAW_SIZE_MB}MB (zstd not found, uncompressed)"
      TOTAL_SIZE=$((TOTAL_SIZE + RAW_SIZE))
    fi
  else
    echo "${RAW_SIZE_MB}MB"
    TOTAL_SIZE=$((TOTAL_SIZE + RAW_SIZE))
  fi

  SERVICE_COUNT=$((SERVICE_COUNT + 1))
done

# On-disk logs (hived, PostgreSQL, entrypoint)
if [ $DISK_LOGS -eq 1 ] && [ -f "$STACK_DIR/.env" ]; then
  ZPOOL=$(grep -oP '(?<=^ZPOOL=).*' "$STACK_DIR/.env" | tr -d '"')
  DATASET=$(grep -oP '(?<=^TOP_LEVEL_DATASET=).*' "$STACK_DIR/.env" | tr -d '"')

  if [ -n "$ZPOOL" ] && [ -n "$DATASET" ]; then
    DATADIR="/${ZPOOL}/${DATASET}"

    echo ""
    echo "On-disk logs from $DATADIR:"

    # Hived logs
    for f in "$DATADIR"/logs/hived/default/default.log "$DATADIR"/logs/hived/p2p/p2p.log; do
      if [ -f "$f" ]; then
        name="disk-hived-$(basename "$(dirname "$f")").log"
        RAW_SIZE=$(stat -c %s "$f" 2>/dev/null || echo 0)
        RAW_SIZE_MB=$(echo "scale=1; $RAW_SIZE / 1048576" | bc)
        echo -n "  Saving $name (${RAW_SIZE_MB}MB)... "
        cp "$f" "$LOG_DIR/$name"
        compress_file "$LOG_DIR/$name"
        echo "done"
        SERVICE_COUNT=$((SERVICE_COUNT + 1))
      fi
    done

    # PostgreSQL logs
    for f in "$DATADIR"/logs/postgresql/*.log; do
      if [ -f "$f" ]; then
        name="disk-postgresql-$(basename "$f")"
        RAW_SIZE=$(stat -c %s "$f" 2>/dev/null || echo 0)
        RAW_SIZE_MB=$(echo "scale=1; $RAW_SIZE / 1048576" | bc)
        echo -n "  Saving $name (${RAW_SIZE_MB}MB)... "
        cp "$f" "$LOG_DIR/$name"
        compress_file "$LOG_DIR/$name"
        echo "done"
        SERVICE_COUNT=$((SERVICE_COUNT + 1))
      fi
    done

    # Docker entrypoint log
    if [ -f "$DATADIR/docker_entrypoint.log" ]; then
      RAW_SIZE=$(stat -c %s "$DATADIR/docker_entrypoint.log" 2>/dev/null || echo 0)
      RAW_SIZE_MB=$(echo "scale=1; $RAW_SIZE / 1048576" | bc)
      echo -n "  Saving disk-docker_entrypoint.log (${RAW_SIZE_MB}MB)... "
      cp "$DATADIR/docker_entrypoint.log" "$LOG_DIR/disk-docker_entrypoint.log"
      compress_file "$LOG_DIR/disk-docker_entrypoint.log"
      echo "done"
      SERVICE_COUNT=$((SERVICE_COUNT + 1))
    fi
  fi
fi

# Calculate total size of output directory
TOTAL_SIZE=$(du -sb "$LOG_DIR" 2>/dev/null | cut -f1)
TOTAL_SIZE_MB=$(echo "scale=1; $TOTAL_SIZE / 1048576" | bc)

echo ""
echo "============================================="
echo "Saved $SERVICE_COUNT logs (${TOTAL_SIZE_MB}MB total)"
echo "Location: $LOG_DIR"
echo "============================================="
