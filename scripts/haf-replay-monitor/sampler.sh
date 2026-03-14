#!/bin/bash
# sampler.sh — Collects HAF replay metrics and pushes to the monitor API.
#
# Usage: sampler.sh --run-id=ID --api-url=URL --compose-dir=DIR [--interval=15]
#
# The sampler polls the HAF container's PostgreSQL for block progress and
# Docker for container status, then POSTs to the replay monitor API.

set -euo pipefail

RUN_ID=""
API_URL=""
COMPOSE_DIR=""
INTERVAL=15
HAF_SERVICE="haf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id=*) RUN_ID="${1#*=}" ;;
    --api-url=*) API_URL="${1#*=}" ;;
    --compose-dir=*) COMPOSE_DIR="${1#*=}" ;;
    --interval=*) INTERVAL="${1#*=}" ;;
    --haf-service=*) HAF_SERVICE="${1#*=}" ;;
    --help)
      echo "Usage: $0 --run-id=ID --api-url=URL --compose-dir=DIR [--interval=15]"
      echo ""
      echo "  --run-id=ID          Run ID from the monitor API (POST /api/runs first)"
      echo "  --api-url=URL        Monitor API base URL (e.g. http://192.168.50.109:8082)"
      echo "  --compose-dir=DIR    Path to docker-compose project directory"
      echo "  --interval=N         Seconds between samples (default: 15)"
      echo "  --haf-service=NAME   HAF service name in compose (default: haf)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$RUN_ID" || -z "$API_URL" || -z "$COMPOSE_DIR" ]]; then
  echo "ERROR: --run-id, --api-url, and --compose-dir are required"
  exit 1
fi

# Resolve compose options from .env if present
cd "$COMPOSE_DIR"
COMPOSE_CMD="docker compose"

# Find HAF container name
find_haf_container() {
  $COMPOSE_CMD ps --format '{{.Name}}' 2>/dev/null | grep -E "[-_]${HAF_SERVICE}[-_]" | head -1
}

query_pg() {
  local container="$1"
  local sql="$2"
  docker exec "$container" psql -U haf_admin -d haf_block_log -tAF'|' -c "$sql" 2>/dev/null || echo ""
}

echo "Sampler started: run_id=$RUN_ID api=$API_URL compose=$COMPOSE_DIR interval=${INTERVAL}s"

while true; do
  HAF_CONTAINER=$(find_haf_container)
  if [[ -z "$HAF_CONTAINER" ]]; then
    echo "$(date -Iseconds) HAF container not found, waiting..."
    sleep "$INTERVAL"
    continue
  fi

  # Block progress
  HIVE_STATE=$(query_pg "$HAF_CONTAINER" "SELECT num, consistent_block FROM hafd.hive_state LIMIT 1")
  if [[ -z "$HIVE_STATE" ]]; then
    sleep "$INTERVAL"
    continue
  fi
  BLOCK_NUM=$(echo "$HIVE_STATE" | cut -d'|' -f1)
  LIB=$(echo "$HIVE_STATE" | cut -d'|' -f2)

  # App progress
  APP_JSON="[]"
  CONTEXTS=$(query_pg "$HAF_CONTAINER" "SELECT name, current_block_num FROM hafd.contexts WHERE current_block_num > 0")
  if [[ -n "$CONTEXTS" ]]; then
    APP_JSON="["
    first=true
    while IFS='|' read -r name block; do
      if [[ "$first" == true ]]; then first=false; else APP_JSON+=","; fi
      APP_JSON+="{\"app_name\":\"$name\",\"current_block_num\":$block}"
    done <<< "$CONTEXTS"
    APP_JSON+="]"
  fi

  # Container status
  CTR_JSON="["
  first=true
  while IFS='|' read -r name status health; do
    [[ -z "$name" ]] && continue
    if [[ "$first" == true ]]; then first=false; else CTR_JSON+=","; fi
    CTR_JSON+="{\"name\":\"$name\",\"status\":\"$status\",\"health\":\"${health:-unknown}\"}"
  done < <($COMPOSE_CMD ps --format '{{.Name}}|{{.Status}}|{{.Health}}' 2>/dev/null || true)
  CTR_JSON+="]"

  # Memory (HAF container RSS)
  MEM_RAW=$(docker stats --no-stream --format '{{.MemUsage}}' "$HAF_CONTAINER" 2>/dev/null | cut -d'/' -f1 | tr -d ' ')
  MEM_BYTES=""
  if [[ "$MEM_RAW" =~ ^([0-9.]+)GiB$ ]]; then
    MEM_BYTES=$(echo "${BASH_REMATCH[1]} * 1073741824" | bc | cut -d. -f1)
  elif [[ "$MEM_RAW" =~ ^([0-9.]+)MiB$ ]]; then
    MEM_BYTES=$(echo "${BASH_REMATCH[1]} * 1048576" | bc | cut -d. -f1)
  fi

  # PG database size
  PG_SIZE=$(query_pg "$HAF_CONTAINER" "SELECT pg_database_size('haf_block_log')")

  # Build payload
  PAYLOAD=$(cat <<ENDJSON
{
  "block_num": $BLOCK_NUM,
  "lib": $LIB,
  "memory_rss": ${MEM_BYTES:-null},
  "pg_size": ${PG_SIZE:-null},
  "app_progress": $APP_JSON,
  "containers": $CTR_JSON
}
ENDJSON
)

  # Push to API
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${API_URL}/api/runs/${RUN_ID}/samples" 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" != "201" ]]; then
    echo "$(date -Iseconds) Push failed (HTTP $HTTP_CODE) block=$BLOCK_NUM"
  fi

  sleep "$INTERVAL"
done
