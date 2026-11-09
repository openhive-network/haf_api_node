# Load shedding and spillover

This stack protects the database from congestion collapse under overload
(e.g. a crawler driving unbounded concurrency into hivemind), and can
optionally divert the excess to secondary API stacks instead of dropping it.
There are two independent layers plus an optional third.

## Layer 1 — static per-server cap (always on, generous)

Every postgrest-backed HAProxy backend has a static per-server `maxconn`
(`HIVEMIND_SERVER_MAXCONN=64`, `HAFAH_SERVER_MAXCONN=48`, others 32) and a
short `timeout queue` (`API_QUEUE_TIMEOUT=5s`). Requests beyond the cap wait
briefly in HAProxy's queue and then get a fast 503, instead of piling into
the postgrest pool and collapsing the database. The caps are deliberately
generous (several times each app's `PGRST_DB_POOL`), so normal traffic is
unaffected. For an app under sustained load, lower its cap to about 1-2x its
pool (`*_PGRST_DB_POOL`) so the excess queues in HAProxy rather than inside
postgrest; `.env.example` explains the sizing, including pgbouncer's shared
`max_db_connections`. Neither the agent checks nor HAProxy's own server check
take a postgrest pool connection, so a saturated app stays UP.

**Opt out entirely:** set a backend's `*_SERVER_MAXCONN=0` (HAProxy = no
limit) to restore the old unbounded behavior where the stack simply gets
slow under load.

## Layer 2 — dynamic shedding (off by default)

The `haproxy-healthchecks` container runs `checks/shed_poller.sh`, a single
background loop that watches for real database saturation:

- **pg_stat_activity** (as `haf_admin`): the hivemind postgrest pool is
  backlogged — `>= SHED_OVERLOAD_ACTIVE` active queries with the oldest
  `>= SHED_OVERLOAD_AGE_S` seconds — or total non-idle backends
  `>= SHED_OVERLOAD_TOTAL_ACTIVE`.
- **pgbouncer `SHOW POOLS`** (as `stats`): any pool saturated server-side
  (`sv_active>0 && sv_idle==0`) or any client waiting.

With hysteresis (tighten after `SHED_CONFIRMATIONS` overloaded polls, loosen
after `SHED_COOLDOWN` quiet polls) it publishes a level 0/1/2 to
`/run/shed.level`. Each agent-check script reads that level and reports a
per-app `maxconn:` in its agent response — stepping the backend's effective
cap down `normal -> reduced -> floor` (e.g. hivemind `64 12 6`, floor never
0) and back up on recovery. The floor keeps the local stack serving its
fastest path even while shedding.

`SHED_ARMED=false` (default) is log-only: overload is still detected and
logged, but the published level stays 0 so nothing is actually shed. Arm it
(`SHED_ARMED=true`) only after reviewing the log-only decisions during a real
spike. All thresholds and the per-app `<APP>_SHED_MAXCONNS="normal reduced
floor"` triples are environment variables (see `.env.example`).

## Pool-metric caps (log-only by default)

Each postgrest-backed agent check also reads its app postgrest's admin
`/metrics` (port 3001, no pool connection) and sizes that backend's cap from
the live pool: `ceil(pgrst_db_pool_max × POOL_CAP_FACTOR)` (factor 1.5, never
below `pool_max + 1`). When `pgrst_db_pool_waiting > 0` or
`pgrst_db_pool_timeouts_total` rose since the last poll, for
`POOL_CAP_CONFIRMATIONS` consecutive polls, the cap steps down to `pool_max`;
it returns after `POOL_CAP_COOLDOWN` quiet polls. The hysteresis state lives
in `/run/poolcap/<app>` in the healthchecks container. If `/metrics` can't be
read, the agent uses the static `*_SERVER_MAXCONN` (fail-open). A pool resize
takes effect at the next poll after postgrest restarts, without an HAProxy
reload.

`POOL_CAP_MODE=log` (default) computes and logs the cap every poll but
advertises exactly what Layer 2 would. `on` advertises `maxconn:<cap>`, or
the lower of the cap and the shed-level value when `SHED_ARMED=true`. `off`
skips `/metrics`. HAProxy keeps the last agent-set maxconn, so after going
from `on` back to `log`/`off`, restart haproxy to restore the static caps.

`*_PGRST_DB_POOL_ACQUISITION_TIMEOUT` defaults to 4s, below
`API_QUEUE_TIMEOUT` (5s), so requests beyond the pool fail in HAProxy's queue
with a fast 503 rather than as a later postgrest 504.

Checking it on a running stack (hivesense as the example):

```bash
# the pool metrics and the cap the agent computed from them
docker compose exec haproxy-healthchecks wget -qO- http://hivesense-postgrest:3001/metrics | grep pgrst_db_pool
docker compose logs --since 1m haproxy-healthchecks | grep 'pool_cap: hivesense'
# the cap HAProxy applies (slim column); with POOL_CAP_MODE=on it follows the pool
docker compose exec haproxy sh -c 'echo "show stat" | socat stdio /run/haproxy/admin.sock' | grep '^hivesense,' | cut -d, -f1,2,7
# resize: HIVESENSE_PGRST_DB_POOL=8, `docker compose up -d hivesense-postgrest`; slim -> 12 within two agent intervals
# saturate: hold every pool slot (e.g. that many concurrent requests to an endpoint running pg_sleep);
#   after POOL_CAP_CONFIRMATIONS polls the log shows TIGHTEN and slim drops to pool_max, LOOSEN after the load stops
# fail-open: point HIVESENSE_METRICS_URL at a closed port (stopping postgrest would fail /live too) and
#   recreate haproxy-healthchecks; the log shows "metrics unreadable", slim is HIVESENSE_SERVER_MAXCONN, the server stays UP
```

## Crawler budget on hivesense

`frontend hivesense-in-7011` gives every request whose User-Agent matches
`HIVESENSE_CRAWLER_UA_REGEX` one shared request-rate counter; above
`HIVESENSE_CRAWLER_REQS_PER_10S` (default 30) they get `429` with
`Retry-After: 30`. `0` disables it. Crawler traffic to similar-posts asks for
unique posts no cache can absorb, so without this it can occupy the whole
hivesense pool. Check it with two bursts to an uncached endpoint:

```bash
for ua in AhrefsBot 'Mozilla/5.0 Firefox/120.0'; do
  for i in $(seq 40); do curl -s -o /dev/null -w '%{http_code}\n' -A "$ua" "https://<your node>/hivesense-api/<uncached path>"; done | sort | uniq -c
done   # the crawler burst gets 429s (with Retry-After: 30), the browser burst none
```

## Layer 3 — spillover to secondary backends (optional, multi-stack only)

If you run more than one API stack, you can send the *excess* to secondaries
instead of returning 503s. The mechanism reuses Layer 2 with no extra logic:

- The postgrest backends use `balance first`, which assigns each request to
  the first server (in declaration order) with a free connection slot,
  overflowing to the next only when the current one is at `maxconn`.
- When Layer 2 lowers the local server's effective `maxconn` under DB
  saturation, `balance first` automatically routes the overflow to the
  secondary servers. A 503 happens only when the local server **and every
  secondary** are simultaneously full.

`balance first` is behaviorally identical to `balance roundrobin` when a
backend has a single server, so single-stack deployments are unaffected and
ship no secondaries.

To configure secondaries, see `haproxy/30-proxies-spillover.cfg.example`. It
shows both patterns — an external public node over HTTPS (`ssl` + `sni`) and
a peer stack over the `exposed/` scheme (`170NN` API + `270NN` agent-check) —
declared in preference order after the local server. Because a peer reached
via `270NN` is health-checked by its own agent, `balance first` skips a peer
that is itself overloaded. A HAProxy backend can't be split across files, so
enable spillover by bind-mounting an edited copy of `30-proxies.cfg` (with
the secondary `server` lines added) over the stock one, exactly as the hbt4
deployment does with its `30-proxies-override.cfg`.
