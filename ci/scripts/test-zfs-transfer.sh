#!/usr/bin/env bash
#
# End-to-end test of transfer_zfs_datasets.sh over tcp:// on this host, between two throwaway
# file-backed pools: a source laid out by create_zfs_datasets.sh with blockchain cloned from a
# dataset outside the tree, snapshots taken by snapshot_zfs_datasets.sh, then --check, a full
# transfer behind a probe connection, a re-run that skips everything and an incremental catch-up
# whose first dataset connection is closed before the receiver replies (retried), after checking that a
# wrong token stops the sender at once and a listener that goes away makes it give up.
# Needs root, ZFS and nc; skips (exit 0) with the reason when the host lacks them.
# With XFER_SSH_HOST set to an ssh destination that reaches this same host (e.g. localhost,
# logged in with $SUDO_USER's keys), the full transfer and the catch-up are repeated over ssh.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${PORT:-17700}
HELPER_PORT=$((PORT + 1))
TOKEN=test-token

skip() {
  echo "SKIP zfs-transfer: $*"
  exit 0
}

[ "$(id -u)" -eq 0 ] || skip "needs root"
if ! command -v zpool >/dev/null || [ ! -e /dev/zfs ]; then
  skip "no ZFS on this host (zpool or /dev/zfs missing)"
fi
command -v nc >/dev/null || skip "nc (netcat) is not installed"

WORK=$(mktemp -d)
SRC=xfersrc$$
DST=xferdst$$
RECEIVER_PID=""
FLAKY_PID=""

cleanup() {
  set +e
  [ -z "$RECEIVER_PID" ] || { pkill -P "$RECEIVER_PID"; kill "$RECEIVER_PID"; } 2>/dev/null
  [ -z "$FLAKY_PID" ] || { pkill -P "$FLAKY_PID"; kill "$FLAKY_PID"; } 2>/dev/null
  zpool destroy -f "$SRC" 2>/dev/null
  zpool destroy -f "$DST" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

start_receiver() {
  "$REPO_DIR/transfer_zfs_datasets.sh" receive --port="${1:-$PORT}" --token="$TOKEN" "$DST/copy" > "$WORK/receiver.log" 2>&1 &
  RECEIVER_PID=$!
}

wait_receiver() {
  wait "$RECEIVER_PID" || fail "receiver exited with an error: $(cat "$WORK/receiver.log")"
  RECEIVER_PID=""
}

# Ends the receiver on port $1 the way a finished sender does.
end_receiver() {
  local fd
  exec {fd}<>"/dev/tcp/127.0.0.1/$1"
  echo "HAFZFS1 $TOKEN END" >&"$fd"
  IFS= read -r _ <&"$fd" || true
  exec {fd}>&-
  wait_receiver
}

# Stands in for the receiver on $PORT: answers one STATE request through the real receiver on
# $HELPER_PORT, then closes the next $1 STREAM connections without a reply and stops listening.
flaky_receiver() {
  local drops="$1" answered=0 line nc_in nc_out nc_pid up
  while [ "$answered" -eq 0 ] || [ "$drops" -gt 0 ]; do
    coproc NC { exec nc -l "$PORT"; }
    # shellcheck disable=SC2153  # set by coproc
    nc_pid=$NC_PID
    exec {nc_in}<&"${NC[0]}" {nc_out}>&"${NC[1]}"
    line=""
    IFS= read -r line <&"$nc_in" || true
    case $line in
      *" STATE")
        exec {up}<>"/dev/tcp/127.0.0.1/$HELPER_PORT"
        echo "$line" >&"$up"
        while IFS= read -r line <&"$up"; do
          echo "$line" >&"$nc_out"
          [ "$line" != END ] || break
        done
        exec {up}>&-
        answered=1
        ;;
      *" STREAM "*)
        echo "closed without a reply: $line"
        drops=$((drops - 1))
        ;;
    esac
    exec {nc_in}<&- {nc_out}>&-
    kill "$nc_pid" 2>/dev/null || true
    wait "$nc_pid" 2>/dev/null || true
  done
}

send() {
  "$REPO_DIR/transfer_zfs_datasets.sh" send --env-file="$WORK/src.env" --token="$TOKEN" --connect-timeout=60 "$@"
}

for pool in "$SRC" "$DST"; do
  truncate -s 1G "$WORK/$pool.img"
  zpool create -m "$WORK/mnt/$pool" "$pool" "$WORK/$pool.img"
done
cat > "$WORK/src.env" <<EOF
ZPOOL=$SRC
TOP_LEVEL_DATASET=haf-datadir
ZPOOL_MOUNT_POINT=$WORK/mnt/$SRC
EOF
DATADIR="$WORK/mnt/$SRC/haf-datadir"

cd "$REPO_DIR"
ZPOOL_MOUNT_POINT="$WORK/mnt/$SRC" ./create_zfs_datasets.sh --env-file="$WORK/src.env" --skip-empty-snapshot

# blockchain as a clone of a dataset outside the tree, as clone_zfs_datasets.sh leaves it
zfs create "$SRC/block_log_master"
head -c 8M /dev/urandom > "$WORK/mnt/$SRC/block_log_master/block_log"
zfs snapshot "$SRC/block_log_master@base"
zfs destroy "$SRC/haf-datadir/blockchain"
zfs clone -o compression=off "$SRC/block_log_master@base" "$SRC/haf-datadir/blockchain"
head -c 4M /dev/urandom > "$DATADIR/shared_memory/shared_memory.bin"
head -c 1M /dev/urandom > "$DATADIR/haf_db_store/pgdata/PG_VERSION"

zfs snapshot -r "$SRC/haf-datadir@by-hand"
send --check by-hand tcp://127.0.0.1:1 > "$WORK/untagged.log" 2>&1 && fail "--check accepted a snapshot not taken by snapshot_zfs_datasets.sh"
grep -q "was not taken by snapshot_zfs_datasets.sh" "$WORK/untagged.log" || fail "untagged snapshot not reported: $(cat "$WORK/untagged.log")"

./snapshot_zfs_datasets.sh --env-file="$WORK/src.env" --force s1

start_receiver
# a peer that connects and goes away must not consume the receiver
sleep 2
nc -z 127.0.0.1 "$PORT" || true

send --check s1 "tcp://127.0.0.1:$PORT" | tee "$WORK/check.log"
grep -q "clone of $SRC/block_log_master@base" "$WORK/check.log" || fail "--check does not report the clone"
grep -q "SPACE: OK" "$WORK/check.log" || fail "--check gave no OK space verdict"
zfs list "$DST/copy" >/dev/null 2>&1 && fail "--check received something"

send --max-capacity=0 s1 "tcp://127.0.0.1:$PORT" > "$WORK/full.log" 2>&1 && fail "send ignored the space warning"
grep -q "SPACE: WARNING" "$WORK/full.log" || fail "no space warning: $(cat "$WORK/full.log")"

send --buffer=none s1 "tcp://127.0.0.1:$PORT"
wait_receiver
if [ -n "${XFER_SSH_HOST:-}" ]; then
  send s1 "$XFER_SSH_HOST:$DST/copy-ssh"
  zfs list "$DST/copy-ssh/haf_db_store/pgdata/pg_wal@s1" >/dev/null || fail "the ssh transfer is incomplete"
fi

for ds in . blockchain shared_memory haf_db_store/pgdata haf_db_store/pgdata/pg_wal logs hivesense/ollama; do
  name="$DST/copy"
  [ "$ds" = . ] || name="$DST/copy/$ds"
  zfs list "$name@s1" >/dev/null || fail "$name@s1 was not received"
  [ "$(zfs get -H -o value mounted "$name")" = no ] || fail "$name is mounted after receive"
done
[ "$(zfs get -H -o value origin "$DST/copy/blockchain")" = - ] || fail "the received blockchain is still a clone"
[ "$(zfs get -H -o value compression "$DST/copy/blockchain")" = off ] || fail "blockchain lost compression=off"
[ "$(zfs get -H -o value canmount "$DST/copy/haf_db_store")" = off ] || fail "haf_db_store lost canmount=off"
[ "$(zfs get -H -o value mountpoint "$DST/copy")" = "$WORK/mnt/$DST/copy" ] || fail "the copy did not inherit the target's mountpoint"

start_receiver
send s1 "tcp://127.0.0.1:$PORT" | tee "$WORK/rerun.log"
wait_receiver
grep -q "To send: 0 stream" "$WORK/rerun.log" || fail "the re-run did not skip the received datasets"

zfs mount "$DST/copy"
zfs mount "$DST/copy/shared_memory"
head -c 4M /dev/urandom > "$DATADIR/shared_memory/shared_memory.bin"
touch "$DATADIR/blockchain/block_log"
./snapshot_zfs_datasets.sh --env-file="$WORK/src.env" --force s2

start_receiver "$HELPER_PORT"
until nc -z 127.0.0.1 "$HELPER_PORT"; do sleep 1; done

started=$SECONDS
send --token=wrong-token --incremental-from=s1 s2 "tcp://127.0.0.1:$HELPER_PORT" > "$WORK/wrong-token.log" 2>&1 \
  && fail "send accepted a receiver that refused its token"
grep -q "ERR wrong token" "$WORK/wrong-token.log" || fail "the wrong token was not reported: $(cat "$WORK/wrong-token.log")"
[ $((SECONDS - started)) -lt 30 ] || fail "a refused token was retried"

flaky_receiver 0 > "$WORK/flaky.log" &
FLAKY_PID=$!
send --connect-timeout=10 --incremental-from=s1 s2 "tcp://127.0.0.1:$PORT" > "$WORK/gone.log" 2>&1 \
  && fail "send succeeded without a listener"
grep -q "no reply to 'STREAM " "$WORK/gone.log" || fail "a vanished listener was not reported: $(cat "$WORK/gone.log")"
wait "$FLAKY_PID"

flaky_receiver 1 > "$WORK/flaky.log" &
FLAKY_PID=$!
send --incremental-from=s1 s2 "tcp://127.0.0.1:$PORT" > "$WORK/incremental.log" 2>&1 &
SEND_PID=$!
wait "$FLAKY_PID" || fail "the stand-in receiver failed: $(cat "$WORK/flaky.log")"
FLAKY_PID=""
end_receiver "$HELPER_PORT"
start_receiver
wait "$SEND_PID" || fail "send did not survive a connection closed before the reply: $(cat "$WORK/incremental.log")"
wait_receiver
cat "$WORK/incremental.log"
[ "$(grep -c "closed the STREAM connection before replying" "$WORK/incremental.log")" = 1 ] \
  || fail "expected exactly one retry of the closed STREAM connection"
grep -q "incremental" "$WORK/incremental.log" || fail "no incremental streams were planned"
if [ -n "${XFER_SSH_HOST:-}" ]; then
  send --incremental-from=s1 s2 "$XFER_SSH_HOST:$DST/copy-ssh"
  zfs list "$DST/copy-ssh/shared_memory@s2" >/dev/null || fail "the ssh catch-up did not arrive"
fi
zfs list "$DST/copy/shared_memory@s2" >/dev/null || fail "the incremental snapshot was not received"
zfs mount "$DST/copy/shared_memory" 2>/dev/null || true
cmp "$DATADIR/shared_memory/shared_memory.bin" "$WORK/mnt/$DST/copy/shared_memory/shared_memory.bin" \
  || fail "shared_memory.bin differs after the incremental receive"
cmp "$DATADIR/blockchain/block_log" "$WORK/mnt/$DST/copy/blockchain/block_log" 2>/dev/null \
  || { zfs mount "$DST/copy/blockchain" && cmp "$DATADIR/blockchain/block_log" "$WORK/mnt/$DST/copy/blockchain/block_log"; } \
  || fail "block_log differs"

echo "PASS zfs-transfer"
