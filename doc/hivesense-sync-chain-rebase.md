# Hivesense during a sync-chain rebase

hivesense's `docs/sync_chain_rebase.md` freezes the embedding generator with
`HIVESENSE_SYNC_ARGS=--stop-at-block=B`, and every node following the sync chain
drains to block B and stops there.

The hivesense agent check (`healthchecks/checks/hivesense.sh`, port 7011) treats
a frozen hivesense like any other stale one: once its last block is more than
60 s old it answers `down #hivesense block too old`, and HAProxy takes the
server out of rotation. This is by design: a hivesense that is behind the head
block serves stale search results.

An operator who decides that a node should keep serving the frozen embeddings
anyway disables the agent check for that node's hivesense server, inside its
haproxy container. Find the server name (`hivesense1` with the stock
`server-template`) with:

```bash
docker compose exec haproxy sh -c 'echo "show servers state hivesense" | socat stdio /run/haproxy/admin.sock'
```

then disable the agent check:

```bash
docker compose exec haproxy sh -c 'echo "disable agent hivesense/hivesense1" | socat stdio /run/haproxy/admin.sock'
```

and re-enable it once the node has caught up and is fresh again:

```bash
docker compose exec haproxy sh -c 'echo "enable agent hivesense/hivesense1" | socat stdio /run/haproxy/admin.sock'
```

This is a runtime-only, per-node decision: it is not stored in the repository or
`.env`, applies only to the node where it is run, and is lost when haproxy
restarts or is recreated, after which the 60 s rule applies again.
