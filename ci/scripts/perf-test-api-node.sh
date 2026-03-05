#!/bin/bash

# Runs k6 performance tests against the HAF API node stack.
# Designed to run in CI after the stack is up (same context as test-api-node.sh),
# or locally against any running HAF API node.
#
# Usage:
#   ci/scripts/perf-test-api-node.sh                     # CI mode (uses PUBLIC_HOSTNAME)
#   BASE_URL=https://api.example.com ci/scripts/perf-test-api-node.sh   # Local mode
#   TEST_PROFILE=load ci/scripts/perf-test-api-node.sh   # Load test profile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_DIR="${REPO_DIR}/tests/performance"

# Determine base URL
if [[ -z "${BASE_URL:-}" ]]; then
  if [[ -n "${PUBLIC_HOSTNAME:-}" ]]; then
    BASE_URL="https://${PUBLIC_HOSTNAME}"
  else
    echo "ERROR: Set BASE_URL or PUBLIC_HOSTNAME"
    exit 1
  fi
fi

TEST_PROFILE="${TEST_PROFILE:-smoke}"

echo "=== HAF API Node Performance Tests ==="
echo "Target:  ${BASE_URL}"
echo "Profile: ${TEST_PROFILE}"
echo ""

# Output directory for results
RESULTS_DIR="${CI_PROJECT_DIR:-${REPO_DIR}}/perf-results"
mkdir -p "${RESULTS_DIR}"

# Check if k6 is available, fall back to Docker
USE_DOCKER=false
K6_CMD=""
if command -v k6 &>/dev/null; then
  K6_CMD="k6"
elif command -v docker &>/dev/null; then
  echo "k6 not found locally, using Docker..."
  USE_DOCKER=true
  K6_CMD="docker run --rm --user $(id -u):$(id -g) --network host -v ${TEST_DIR}:/tests -v ${RESULTS_DIR}:/results grafana/k6:latest"
fi

if [[ -z "${K6_CMD}" ]]; then
  echo "ERROR: Neither k6 nor docker is available"
  exit 1
fi

# Common k6 arguments
K6_ARGS="-e BASE_URL=${BASE_URL} -e TEST_PROFILE=${TEST_PROFILE} -e TLS_SKIP_VERIFY=${TLS_SKIP_VERIFY:-true}"

run_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "${test_file}" .test.js)"
  echo ""
  echo "--- Running: ${test_name} ---"

  local test_path="${TEST_DIR}/${test_file}"
  local summary_path="${RESULTS_DIR}/${test_name}-summary.json"
  if [[ "${USE_DOCKER}" == "true" ]]; then
    test_path="/tests/${test_file}"
    summary_path="/results/${test_name}-summary.json"
  fi

  # shellcheck disable=SC2086
  ${K6_CMD} run ${K6_ARGS} \
    --summary-export="${summary_path}" \
    "${test_path}" 2>&1 | tee "${RESULTS_DIR}/${test_name}.log"

  echo "--- Done: ${test_name} ---"
}

# Run all test suites
run_test "jsonrpc.test.js"
run_test "rest-apis.test.js"
run_test "mixed-workload.test.js"

echo ""
echo "=== All performance tests complete ==="
echo "Results saved to: ${RESULTS_DIR}"
