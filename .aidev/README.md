# haf_api_node under AIDEV

AIDEV verifies changes to this repository through the slots in `project.yaml`,
integrates them into `aidev/integration`, and people merge that into `develop`
through merge requests (as in hive/denser). GitLab CI doesn't run for AIDEV branches
(`ai/*`, `session/*`, pushes to `aidev/integration`); see `.gitlab-ci.yml` `workflow:`.

## Suites

`.aidev/run-checks.sh <suite> <step>...` runs the named steps and writes
`test-results/<suite>/junit.xml`, one test case per step, with the step's log tail as
the failure body. `caddy-validate` and `caddy-smoke` also write one case per variant
or route (`caddy-validate.xml`, `caddy-smoke.xml`).

| Step | What |
|---|---|
| `compose-lint` | `dclint` on `*.yaml ci/compose.yml */compose*.yml` with CI's disabled rules (CI's `lint-docker-compose`) |
| `shellcheck` | `shellcheck -f gcc healthchecks/checks/*.sh healthchecks/*.sh` (CI's `lint-shellcheck`), plus `.aidev/`'s own scripts |
| `log-rotation` | `python3 log_rotation/sync_log_rotation.py --check` (CI's `check-log-rotation`) |
| `caddy-validate` | `caddy/Caddyfile.tmpl` rendered with gomplate as `caddy/entrypoint.sh` does (`.aidev/caddy-render.sh`), under five environments (defaults; public TLS with PROXY protocol and admin IPs; rate limit and admin restriction off; the legacy `*_SNIPPET` variables; `postgres-public` with the layer4 snippet), each checked with `caddy validate` |
| `caddy-smoke` | `.aidev/caddy_smoke.py`: `caddy run` on the rendered template (defaults, plain HTTP on `localhost:18080`), with the upstreams it names (`denser-blog`, `denser-wallet`, `block-explorer-ui`, `varnish`, `swagger`, the JSON-RPC server) rewritten to stub servers on 127.0.0.1. Checks that `/blog`, `/wallet`, `/explorer` (pages and `_next/static` JS), the REST APIs, JSON-RPC `POST /`, the swagger fallback, `robots.txt` and CORS pre-flight route as intended, that the UI routes are compressed (zstd, or gzip for a gzip-only client) while the REST APIs are not, and that an upstream's own `Content-Encoding` passes through once. Then again with the site-wide `compression.snippet` (caddy/snippets/README.md) added: every response is still encoded exactly once |

| Slot | Steps |
|---|---|
| quick, static, coverage | compose-lint, shellcheck, log-rotation, caddy-validate |
| full, canary | those plus caddy-smoke |
| baseline, system | caddy-validate, caddy-smoke |

The smoke test sends a browser's `Accept-Encoding` (`zstd, br, gzip, deflate`) and
decodes every response by its `Content-Encoding` before comparing it with what the
stub sent; each case's output records the encoding and the size on the wire. To check a
header or an encoding on a route, add a check to `CHECKS` in `caddy_smoke.py`.

Not covered: the CI's HAF replay and API tests (`haf-node-replay`,
`haf_api_node_test`: block_log data and a docker daemon), `docker buildx bake` of
the service images, `docker compose config`, and HTTPS (the smoke test serves plain
HTTP; `caddy-validate` covers the TLS variants).

## The test runtime image (`runtime/`)

The checks run in a container with `--network none` and your uid. The image is CI's
`alpine:3.22.1` with `shellcheck`, `python3` + PyYAML and `py3-zstandard` from its
repositories, the `dclint` binary from CI's `dclint:alpine` image, and `caddy` +
`gomplate` from this project's own `caddy` image (with the rate_limit, layer4 and
transform-encoder plugins), all pinned by digest.

When `runtime/Dockerfile` changes (e.g. to pick up a new `caddy` image), rebuild and
re-pin **in the same commit**:

```bash
.aidev/runtime/build.sh --push   # registry digest if aidev-<input hash> exists, else build + push
# put the printed repo@sha256:<digest> into project.yaml environment.image
```

Run a suite by hand the same way AIDEV does:

```bash
docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD":/work -w /work <environment.image> \
  .aidev/run-checks.sh full compose-lint shellcheck log-rotation caddy-validate caddy-smoke
```
