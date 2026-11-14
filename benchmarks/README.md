# k6 benchmarks

`run.sh` runs one k6 script per app (`k6/<app>.js`) and prints a summary table of
request count, average, p50, p95 and p99 latency and error rate, read from k6's
`--summary-export`. `--json DIR` also keeps k6's full per-request output.

```bash
./benchmarks/run.sh --docker                      # every app that answers, through the stack
./benchmarks/run.sh --docker hafah hivemind       # selected apps
./benchmarks/run.sh --docker --smoke              # one request per app
```

## Two ways to target the apps

**Through the stack** (default, `--url`, e.g. `https://api.example.com`). Requests pass
Caddy, Varnish (REST apps) or Drone (JSON-RPC), and HAProxy, as a client's would. The
scripts draw accounts, block numbers, witnesses and posts per iteration so most URLs are
new to the cache, but some requests still repeat (metadata endpoints, a small set of
ranked feeds, accounts drawn again within a cache TTL), and those are answered by the
cache in well under a millisecond. Use this mode to check that the public endpoints work
and to see what a client sees end to end. Do not compare its percentiles with a backend
replay: the cache hits pull them down.

**Directly at the backends** (`--app-url APP=URL`, repeatable). Each listed app's requests
go to the given base URL instead, bypassing Caddy, Varnish, Drone and HAProxy, so every
request is answered by the app. **Use this mode for performance comparisons** — between
app versions, between nodes, or against `aidev replay run` on the same backend ports.
The scripts' request mix is not production's: it includes cheap metadata calls
(`/version`, `/headblock`, ...), so its p50 sits below a replay of real traffic. Compare
a run with another run of the same scripts, or per endpoint (`--json` tags each request
with `endpoint`).

The stock compose file publishes no app ports. Add the `exposed/` overlay (see
`exposed/README.md`), which publishes each app's PostgREST rewriter on its HAProxy
frontend port + 10000, or publish the ports some other way, and pass those URLs. With
the overlay's default prefix, on the node itself:

```bash
./benchmarks/run.sh --docker \
  --app-url hivemind=http://localhost:17002 \
  --app-url hafah=http://localhost:17003 \
  --app-url balance_tracker=http://localhost:17004 \
  --app-url haf_block_explorer=http://localhost:17005 \
  --app-url reputation_tracker=http://localhost:17009 \
  --app-url nft_tracker=http://localhost:17013 \
  --app-url haf_stats=http://localhost:17016 \
  --app-url haf_fyp=http://localhost:17017
```

An app without `--app-url` still goes through `--url`. The URL is the app's root: the
rewriter takes the paths the stack serves under `/<app>-api/` without that prefix, and
hivemind takes JSON-RPC at `/`. The overrides end up as `HAFAH_URL`, `HIVEMIND_URL`, ...
in `k6/config.js`, so running k6 by hand works the same way.

## Test data

Accounts come from a fixed list of 150 accounts in `k6/config.js` that exist in both the
5M-block CI dataset and on mainnet (`ACCOUNTS=a,b,c` overrides it). Block numbers are
drawn from 1 to the last block the app reports in `setup()`. hivemind picks a post from
the drawn account's recent posts; haf_block_explorer picks witnesses from its own
witness list.

## When a check fails on every call

The endpoint has drifted from the app's API. Each script's header names the source its
paths were checked against — for the REST apps, the OpenAPI spec the app serves at its
root (`/<app>-api/` through the stack). Compare the failing path and parameters with it.
