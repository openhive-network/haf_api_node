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
#   --app-url APP=URL   Send APP's requests to URL instead of through the stack, e.g.
#                       hafah=http://localhost:17003 (repeatable; see README.md)
#   --vus N             Virtual users per app (default: 10)
#   --duration DUR      Steady-state duration (default: 2m)
#   --max-vus N         Max VUs for stress tests (default: 50)
#   --smoke             Run smoke test only (quick health check)
#   --json DIR          Save k6 JSON output to directory
#   --summary           Print summary comparison table at end
#   --docker            Run k6 via Docker (grafana/k6:2.4.0) instead of local binary
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
K6_IMAGE="grafana/k6:2.4.0"
# k6's default trend stats omit p(99), which the summary table reports.
K6_SUMMARY_TREND_STATS="avg,min,med,max,p(90),p(95),p(99)"
RESULTS_DIR=""
APPS=()
APP_URL_ARGS=()

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
    --app-url)   APP_URL_ARGS+=("$2"); shift 2 ;;
    -h|--help)   head -21 "$0" | tail -20; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; exit 1 ;;
    *)           APPS+=("$1"); shift ;;
  esac
done

# k6 resolves output paths inside the Docker container, where the directory is
# mounted at its absolute host path; create it now so it is owned by the caller.
if [[ -n "$JSON_DIR" ]]; then
  mkdir -p "$JSON_DIR"
  JSON_DIR="$(cd "$JSON_DIR" && pwd)"
fi

# Map app names to k6 scripts
declare -A APP_SCRIPTS=(
  [hafah]="hafah.js"
  [hivemind]="hivemind.js"
  [balance_tracker]="balance_tracker.js"
  [reputation_tracker]="reputation_tracker.js"
  [haf_block_explorer]="haf_block_explorer.js"
  [nft_tracker]="nft_tracker.js"
  [haf_stats]="haf_stats.js"
  [haf_fyp]="haf_fyp.js"
)

# Map app names to their path prefix under the stack URL
declare -A APP_PREFIX=(
  [hafah]="/hafah-api"
  [hivemind]=""
  [balance_tracker]="/balance-api"
  [reputation_tracker]="/reputation-api"
  [haf_block_explorer]="/hafbe-api"
  [nft_tracker]="/nft-tracker-api"
  [haf_stats]="/haf-stats-api"
  [haf_fyp]="/haf-fyp-api"
)

# Map app names to the k6/config.js variable that overrides their base URL
declare -A APP_URL_VAR=(
  [hafah]="HAFAH_URL"
  [hivemind]="HIVEMIND_URL"
  [balance_tracker]="BALANCE_URL"
  [reputation_tracker]="REPUTATION_URL"
  [haf_block_explorer]="HAFBE_URL"
  [nft_tracker]="NFT_URL"
  [haf_stats]="HAF_STATS_URL"
  [haf_fyp]="HAF_FYP_URL"
)

ALL_APPS=(hafah hivemind balance_tracker reputation_tracker haf_block_explorer nft_tracker haf_stats haf_fyp)

declare -A APP_URLS=()
for arg in "${APP_URL_ARGS[@]}"; do
  app="${arg%%=*}"
  url="${arg#*=}"
  if [[ "$arg" != *=* || -z "$url" || -z "${APP_URL_VAR[$app]:-}" ]]; then
    echo "ERROR: --app-url takes APP=URL with APP one of: ${ALL_APPS[*]} (got '$arg')" >&2
    exit 1
  fi
  APP_URLS[$app]="${url%/}"
done

app_url() {
  local app="$1"
  echo "${APP_URLS[$app]:-${STACK_URL}${APP_PREFIX[$app]}}"
}

run_k6() {
  local script="$1"
  shift
  local env_vars=(
    "STACK_URL=$STACK_URL"
    "VUS=$K6_VUS"
    "DURATION=$K6_DURATION"
    "MAX_VUS=$K6_MAX_VUS"
  )
  local app
  for app in "${!APP_URLS[@]}"; do
    env_vars+=("${APP_URL_VAR[$app]}=${APP_URLS[$app]}")
  done

  if [[ "$USE_DOCKER" == "true" ]]; then
    local env_args=() var
    for var in "${env_vars[@]}"; do
      env_args+=(-e "$var")
    done
    local mounts=(-v "$K6_DIR:/scripts:ro")
    local dir
    for dir in "$RESULTS_DIR" "$JSON_DIR"; do
      if [[ -n "$dir" ]]; then
        mounts+=(-v "$dir:$dir")
      fi
    done
    docker run --rm --network host \
      --user "$(id -u):$(id -g)" \
      "${env_args[@]}" \
      "${mounts[@]}" \
      "$K6_IMAGE" run "/scripts/$script" "$@"
  else
    if ! command -v k6 > /dev/null 2>&1; then
      echo "ERROR: k6 not found. Install it (https://k6.io/docs/get-started/installation/) or use --docker" >&2
      exit 1
    fi
    env "${env_vars[@]}" k6 run "$K6_DIR/$script" "$@"
  fi
}

check_app() {
  local app="$1"
  local base
  base="$(app_url "$app")"

  if [[ "$app" == "hivemind" ]]; then
    # Hivemind uses JSON-RPC POST
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"hive.db_head_state","params":{}}' \
      "${base}/" 2>/dev/null) || status="000"
    [[ "$status" == "200" ]]
  else
    curl -sf -o /dev/null "${base}/version" 2>/dev/null
  fi
}

# --- Smoke test ---
if [[ "$SMOKE_ONLY" == "true" ]]; then
  echo "=== Smoke Test: ${STACK_URL} ==="
  local_args=()
  if [[ -n "$JSON_DIR" ]]; then
    local_args+=(--out "json=$JSON_DIR/smoke.json")
  fi
  run_k6 smoke.js "${local_args[@]}"
  exit $?
fi

# --- Auto-detect available apps ---
if [[ ${#APPS[@]} -eq 0 ]]; then
  echo "=== Detecting available apps ==="
  for app in "${ALL_APPS[@]}"; do
    if check_app "$app"; then
      echo "  [OK] $app ($(app_url "$app"))"
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
for app in "${APPS[@]}"; do
  if [[ -n "${APP_URLS[$app]:-}" ]]; then
    echo "  Backend:    $app -> ${APP_URLS[$app]} (bypasses Caddy, Varnish, Drone and HAProxy)"
  fi
done
echo ""

RESULTS_DIR=$(mktemp -d)
FAILED=()

for app in "${APPS[@]}"; do
  script="${APP_SCRIPTS[$app]}"
  echo "=== Benchmarking: $app ==="

  k6_args=()
  if [[ -n "$JSON_DIR" ]]; then
    k6_args+=(--out "json=$JSON_DIR/${app}.json")
  fi

  # Capture summary to file for later comparison
  k6_args+=(--summary-export="$RESULTS_DIR/${app}.json")
  k6_args+=(--summary-trend-stats="$K6_SUMMARY_TREND_STATS")

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
  printf "%-25s %10s %10s %10s %10s %10s %10s\n" \
    "App" "Requests" "Avg (ms)" "p50 (ms)" "p95 (ms)" "p99 (ms)" "Errors"
  printf "%-25s %10s %10s %10s %10s %10s %10s\n" \
    "-------------------------" "----------" "----------" "----------" "----------" "----------" "----------"

  for app in "${APPS[@]}"; do
    summary="$RESULTS_DIR/${app}.json"
    if [[ -f "$summary" ]]; then
      python3 -c "
import json, sys
app, path = sys.argv[1:3]
with open(path) as f:
    d = json.load(f)
m = d.get('metrics', {})

# summary-export writes metric fields flat: a Rate as 'value', a Trend's stats
# as 'avg', 'p(95)', ... A missing field reads 'n/a' rather than a false 0.
def field(metric, key, fmt):
    v = m.get(metric, {}).get(key)
    return 'n/a' if v is None else fmt.format(v)

print('|'.join([
    app,
    field('http_reqs', 'count', '{}'),
    field('http_req_duration', 'avg', '{:.1f}'),
    field('http_req_duration', 'med', '{:.1f}'),
    field('http_req_duration', 'p(95)', '{:.1f}'),
    field('http_req_duration', 'p(99)', '{:.1f}'),
    field('http_req_failed', 'value', '{:.2%}'),
]))
" "$app" "$summary" 2>/dev/null | while IFS='|' read -r name reqs avg p50 p95 p99 errs; do
        printf "%-25s %10s %10s %10s %10s %10s %10s\n" "$name" "$reqs" "$avg" "$p50" "$p95" "$p99" "$errs"
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
