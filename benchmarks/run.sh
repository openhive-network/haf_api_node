#!/bin/bash
# Run k6 benchmarks against a running HAF API node stack.
#
# Usage:
#   ./run.sh [OPTIONS] [APP...]
#
# Apps: hafah, hivemind, balance_tracker, reputation_tracker, haf_block_explorer, nft_tracker
#       If no apps specified, auto-detects which are available via smoke test.
#
# Options:
#   --url URL           Stack base URL (default: http://localhost:8080)
#   --vus N             Virtual users per app (default: 10)
#   --duration DUR      Steady-state duration (default: 2m)
#   --max-vus N         Max VUs for stress tests (default: 50)
#   --smoke             Run smoke test only (quick health check)
#   --json DIR          Save k6 JSON output to directory
#   --summary           Print summary comparison table at end
#   --docker            Run k6 via Docker instead of local binary
#   -h, --help          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6_DIR="$SCRIPT_DIR/k6"

# Defaults
STACK_URL="http://localhost:8080"
K6_VUS=10
K6_DURATION="2m"
K6_MAX_VUS=50
SMOKE_ONLY=false
JSON_DIR=""
SHOW_SUMMARY=true
USE_DOCKER=false
APPS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)       STACK_URL="$2"; shift 2 ;;
    --vus)       K6_VUS="$2"; shift 2 ;;
    --duration)  K6_DURATION="$2"; shift 2 ;;
    --max-vus)   K6_MAX_VUS="$2"; shift 2 ;;
    --smoke)     SMOKE_ONLY=true; shift ;;
    --json)      JSON_DIR="$2"; shift 2 ;;
    --no-summary) SHOW_SUMMARY=false; shift ;;
    --summary)   SHOW_SUMMARY=true; shift ;;
    --docker)    USE_DOCKER=true; shift ;;
    -h|--help)   head -17 "$0" | tail -16; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; exit 1 ;;
    *)           APPS+=("$1"); shift ;;
  esac
done

# Map app names to k6 scripts
declare -A APP_SCRIPTS=(
  [hafah]="hafah.js"
  [hivemind]="hivemind.js"
  [balance_tracker]="balance_tracker.js"
  [reputation_tracker]="reputation_tracker.js"
  [haf_block_explorer]="haf_block_explorer.js"
  [nft_tracker]="nft_tracker.js"
)

# Map app names to health check URLs
declare -A APP_HEALTH=(
  [hafah]="/hafah-api/version"
  [hivemind]="/"
  [balance_tracker]="/balance-api/version"
  [reputation_tracker]="/reputation-api/version"
  [haf_block_explorer]="/hafbe-api/version"
  [nft_tracker]="/nft-tracker-api/version"
)

ALL_APPS=(hafah hivemind balance_tracker reputation_tracker haf_block_explorer nft_tracker)

run_k6() {
  local script="$1"
  shift
  local env_args=(
    -e "STACK_URL=$STACK_URL"
    -e "VUS=$K6_VUS"
    -e "DURATION=$K6_DURATION"
    -e "MAX_VUS=$K6_MAX_VUS"
  )

  if [[ "$USE_DOCKER" == "true" ]]; then
    docker run --rm --network host \
      "${env_args[@]}" \
      -v "$K6_DIR:/scripts:ro" \
      grafana/k6 run "/scripts/$script" "$@"
  else
    if ! command -v k6 > /dev/null 2>&1; then
      echo "ERROR: k6 not found. Install it (https://k6.io/docs/get-started/installation/) or use --docker" >&2
      exit 1
    fi
    STACK_URL="$STACK_URL" VUS="$K6_VUS" DURATION="$K6_DURATION" MAX_VUS="$K6_MAX_VUS" \
      k6 run "$K6_DIR/$script" "$@"
  fi
}

check_app() {
  local app="$1"
  local path="${APP_HEALTH[$app]}"

  if [[ "$app" == "hivemind" ]]; then
    # Hivemind uses JSON-RPC POST
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"hive.db_head_state","params":{}}' \
      "${STACK_URL}${path}" 2>/dev/null) || status="000"
    [[ "$status" == "200" ]]
  else
    curl -sf -o /dev/null "${STACK_URL}${path}" 2>/dev/null
  fi
}

# --- Smoke test ---
if [[ "$SMOKE_ONLY" == "true" ]]; then
  echo "=== Smoke Test: ${STACK_URL} ==="
  local_args=()
  if [[ -n "$JSON_DIR" ]]; then
    mkdir -p "$JSON_DIR"
    local_args+=(--out "json=$JSON_DIR/smoke.json")
  fi
  run_k6 smoke.js "${local_args[@]}"
  exit $?
fi

# --- Auto-detect available apps ---
if [[ ${#APPS[@]} -eq 0 ]]; then
  echo "=== Detecting available apps at ${STACK_URL} ==="
  for app in "${ALL_APPS[@]}"; do
    if check_app "$app"; then
      echo "  [OK] $app"
      APPS+=("$app")
    else
      echo "  [--] $app (not available)"
    fi
  done
  echo ""

  if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "ERROR: No apps detected. Is the stack running at ${STACK_URL}?" >&2
    exit 1
  fi
fi

# Validate app names
for app in "${APPS[@]}"; do
  if [[ -z "${APP_SCRIPTS[$app]:-}" ]]; then
    echo "ERROR: Unknown app '$app'. Available: ${ALL_APPS[*]}" >&2
    exit 1
  fi
done

# --- Run benchmarks ---
echo "=== Benchmark Configuration ==="
echo "  Stack URL:  $STACK_URL"
echo "  Apps:       ${APPS[*]}"
echo "  VUs:        $K6_VUS"
echo "  Duration:   $K6_DURATION"
echo ""

RESULTS_DIR=$(mktemp -d)
FAILED=()

for app in "${APPS[@]}"; do
  script="${APP_SCRIPTS[$app]}"
  echo "=== Benchmarking: $app ==="

  k6_args=()
  if [[ -n "$JSON_DIR" ]]; then
    mkdir -p "$JSON_DIR"
    k6_args+=(--out "json=$JSON_DIR/${app}.json")
  fi

  # Capture summary to file for later comparison
  k6_args+=(--summary-export="$RESULTS_DIR/${app}.json")

  if run_k6 "$script" "${k6_args[@]}"; then
    echo "  $app: PASSED"
  else
    echo "  $app: FAILED"
    FAILED+=("$app")
  fi
  echo ""
done

# --- Summary ---
if [[ "$SHOW_SUMMARY" == "true" && -d "$RESULTS_DIR" ]]; then
  echo "=== Results Summary ==="
  printf "%-25s %10s %10s %10s %10s %10s\n" \
    "App" "Requests" "Avg (ms)" "p95 (ms)" "p99 (ms)" "Errors"
  printf "%-25s %10s %10s %10s %10s %10s\n" \
    "-------------------------" "----------" "----------" "----------" "----------" "----------"

  for app in "${APPS[@]}"; do
    summary="$RESULTS_DIR/${app}.json"
    if [[ -f "$summary" ]]; then
      python3 -c "
import json, sys
with open('$summary') as f:
    d = json.load(f)
m = d.get('metrics', {})
reqs = m.get('http_reqs', {}).get('count', 0)
dur = m.get('http_req_duration', {})
avg = dur.get('avg', 0)
p95 = dur.get('p(95)', 0)
p99 = dur.get('p(99)', 0)
fails = m.get('http_req_failed', {}).get('values', {}).get('rate', 0)
print(f'$app|{reqs}|{avg:.1f}|{p95:.1f}|{p99:.1f}|{fails*100:.2f}%')
" 2>/dev/null | while IFS='|' read -r name reqs avg p95 p99 errs; do
        printf "%-25s %10s %10s %10s %10s %10s\n" "$name" "$reqs" "$avg" "$p95" "$p99" "$errs"
      done
    fi
  done
  echo ""
fi

rm -rf "$RESULTS_DIR"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED apps: ${FAILED[*]}"
  exit 1
fi

echo "All benchmarks passed."
