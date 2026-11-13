# Hivesense during a sync-chain rebase

hivesense's `docs/sync_chain_rebase.md` freezes the embedding generator with
`HIVESENSE_SYNC_ARGS=--stop-at-block=B` for hours, while downstream syncers drain
to the frozen block and idle and search keeps serving the frozen embeddings.

**The hivesense agent check (`healthchecks/checks/hivesense.sh`, port 7011)
tolerates the freeze**: it keeps a frozen hivesense in HAProxy's rotation, while
a hivesense that is stuck still goes down once its last block is more than 60 s
old. Postgrest liveness and the HAF gate apply as always.

| Stack (`HIVESENSE_CONFIGURATION`) | Kept up when its last block is old, if | Agent answer |
|---|---|---|
| `sync` (hivesense-sync) | its `last_block_num` is at most 20 blocks (60 s) behind the `last_block_num` of `${HIVESENSE_SYNC_API}/sync-status` | `up #hivesense frozen at upstream block N` |
| `local` (block processor) | `HIVESENSE_SYNC_ARGS` has `--stop-at-block=B` and its `last_block_num` is `B` | `up #hivesense frozen at stop block B` |

With `POOL_CAP_MODE=on` the answer is `up maxconn:N #hivesense frozen ...`. The
note shows in HAProxy's stats ("last agent check") and logs, so a stale node
that is serving says why.

The upstream's `/sync-status` is fetched only when the local block is older than
60 s, bounded by `HTTP_CHECK_TIMEOUT`. If it can't be fetched, the 60 s rule
applies, so a downstream node goes down during a freeze if its upstream is
unreachable.

`haproxy-healthchecks` reads `HIVESENSE_CONFIGURATION`, `HIVESENSE_SYNC_API` and
`HIVESENSE_SYNC_ARGS` from `.env` (`haproxy.yaml`). After changing
`HIVESENSE_SYNC_ARGS` for the freeze or the cutover, recreate it along with the
block processor: `docker compose up -d` does both.
