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

# Check if k6 is available, fall back to Docker
K6_CMD=""
if command -v k6 &>/dev/null; then
  K6_CMD="k6"
elif command -v docker &>/dev/null; then
  echo "k6 not found locally, using Docker..."
  K6_CMD="docker run --rm --network host -v ${TEST_DIR}:/tests -w /tests grafana/k6:latest"
  # Adjust test path for Docker volume mount
  TEST_DIR="/tests"
fi

if [[ -z "${K6_CMD}" ]]; then
  echo "ERROR: Neither k6 nor docker is available"
  exit 1
fi

# Common k6 arguments
K6_ARGS="-e BASE_URL=${BASE_URL} -e TEST_PROFILE=${TEST_PROFILE} -e TLS_SKIP_VERIFY=${TLS_SKIP_VERIFY:-true}"

# Output directory for results
RESULTS_DIR="${CI_PROJECT_DIR:-${REPO_DIR}}/perf-results"
mkdir -p "${RESULTS_DIR}"

run_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "${test_file}" .test.js)"
  echo ""
  echo "--- Running: ${test_name} ---"

  # shellcheck disable=SC2086
  ${K6_CMD} run ${K6_ARGS} \
    --summary-export="${RESULTS_DIR}/${test_name}-summary.json" \
    "${TEST_DIR}/${test_file}" 2>&1 | tee "${RESULTS_DIR}/${test_name}.log"

  echo "--- Done: ${test_name} ---"
}

# Run all test suites
run_test "jsonrpc.test.js"
run_test "rest-apis.test.js"
run_test "mixed-workload.test.js"

echo ""
echo "=== All performance tests complete ==="
echo "Results saved to: ${RESULTS_DIR}"
