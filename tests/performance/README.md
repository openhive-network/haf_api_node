# HAF API Node Performance Tests

Load and stress tests for the HAF API Node stack using [k6](https://k6.io/).

## Prerequisites

Install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/

```bash
# Ubuntu/Debian
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6

# macOS
brew install k6

# Docker (no install needed)
docker run --rm -i grafana/k6 run - <tests/performance/jsonrpc.test.js
```

## Test Suites

| File | Description |
|------|-------------|
| `jsonrpc.test.js` | JSON-RPC endpoints (hived, HAfAH, Hivemind) |
| `rest-apis.test.js` | REST API endpoints (Balance Tracker, Block Explorer, etc.) |
| `mixed-workload.test.js` | Combined realistic traffic pattern (70% JSON-RPC, 30% REST) |

## Running Tests

### Quick smoke test (1 VU, 10s)

```bash
k6 run tests/performance/jsonrpc.test.js

# Against a specific host
k6 run -e BASE_URL=https://api.hive.blog tests/performance/jsonrpc.test.js
```

### Load test (ramp to 50 VUs over 3 minutes)

```bash
k6 run -e TEST_PROFILE=load tests/performance/mixed-workload.test.js
```

### Stress test (ramp to 200 VUs over 4 minutes)

```bash
k6 run -e TEST_PROFILE=stress tests/performance/mixed-workload.test.js
```

### Custom parameters

```bash
k6 run --vus 20 --duration 2m \
  -e BASE_URL=https://my-api-node.example.com \
  -e TLS_SKIP_VERIFY=true \
  tests/performance/jsonrpc.test.js
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `https://localhost` | Target API node URL |
| `TEST_PROFILE` | `smoke` | Test profile: `smoke`, `load`, or `stress` |
| `TLS_SKIP_VERIFY` | `true` | Skip TLS certificate verification |

## Test Profiles

| Profile | VUs | Duration | Use Case |
|---------|-----|----------|----------|
| `smoke` | 1 | 10s | Verify endpoints work |
| `load` | 10-50 | ~3min | Normal production load |
| `stress` | 50-200 | ~4min | Find breaking points |

## Output

k6 outputs a summary with request rates, latencies (p50/p95/p99), and error rates.
Pass `--out json=results.json` to save detailed results, or use the k6 Cloud/Grafana
integration for dashboards.

## Thresholds

Default pass/fail thresholds:
- **p95 response time** < 5s
- **p99 response time** < 10s
- **Error rate** < 5%

The mixed workload test has stricter thresholds for specific endpoints (e.g., block
queries < 3s at p95, status health < 1s at p95).

## Running Against a Live Stack

The HAF API node is a large multi-service stack that requires replayed blockchain data.
You cannot spin it up from scratch just for performance testing. Instead, run the tests
against an already-running stack.

### Using the convenience script

The `ci/scripts/perf-test-api-node.sh` script handles k6 detection (local binary or
Docker fallback), runs all three test suites, and saves results:

```bash
# Against a remote/local running stack
BASE_URL=https://api.hive.blog ci/scripts/perf-test-api-node.sh

# Load test profile
BASE_URL=https://api.hive.blog TEST_PROFILE=load ci/scripts/perf-test-api-node.sh
```

Results are saved to `perf-results/` as JSON summaries and logs.

## CI Integration

The performance tests integrate with the existing GitLab CI pipeline. The stack is
already built and replayed in CI (see `ci/node-replay.gitlab-ci.yml`). To run perf
tests in CI, add a job to `.gitlab-ci.yml`:

```yaml
haf_api_node_perf_test:
  extends: .haf_api_node_test
  stage: test
  needs:
    - haf_api_node_replay_data_copy
  script:
    - docker-entrypoint.sh /haf-api-node/ci/scripts/test-api-node.sh
    - docker-entrypoint.sh /haf-api-node/ci/scripts/perf-test-api-node.sh
  artifacts:
    when: always
    expire_in: 1 week
    paths:
      - "*.txt"
      - "*.log"
      - "logs/"
      - "*.json"
      - "perf-results/"
  rules:
    - when: manual
      allow_failure: true
  tags:
    - public-runner-docker
    - data-cache-storage
    - fast
```

This reuses the same DinD environment and replayed data as the functional tests,
then runs k6 (via Docker) against the stack. The `perf-results/` directory is
saved as a CI artifact for analysis.

**Note:** The CI `compose` image does not include k6. The `perf-test-api-node.sh`
script automatically falls back to running k6 via Docker (`grafana/k6`).
