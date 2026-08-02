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
unaffected.

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
