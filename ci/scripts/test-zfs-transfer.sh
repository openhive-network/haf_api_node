#!/usr/bin/env bash
#
# End-to-end test of transfer_zfs_datasets.sh over tcp:// on this host, between two throwaway
# file-backed pools: a source laid out by create_zfs_datasets.sh with blockchain cloned from a
# dataset outside the tree, snapshots taken by snapshot_zfs_datasets.sh, then --check, a full
# transfer behind a probe connection, a re-run that skips everything and an incremental catch-up
# whose first dataset connection is closed before the receiver replies (retried), after checking that a
# wrong token stops the sender at once and a listener that goes away makes it give up, and a re-run
# whose END connection is closed without a reply (a warning, not a failure).  Then a send that
# stops at a dataset whose reply was lost without it arriving, and, with an nc that writes each OK
# reply late, a transfer whose receiver has to wait for nc to deliver it and one whose replies are
# all lost although the datasets arrived (warnings, not a failure).  Finally switch_zfs_datasets.sh
# takes the copy, with haf_db_store set to canmount=on as a drifted source sends it, through check,
# prepare (also with haf_db_store mounted over or under its children), boot-check (HAF stubbed, the
# rollback real) and swap, and pgdata/PG_VERSION and the tablespace's files must stay visible.
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

# An nc for the receiver (first on its PATH) that writes each OK reply to the socket $1 seconds
# late, as a loaded host can, and takes its helpers down when killed.
make_slow_nc() {
  mkdir -p "$WORK/slow-nc"
  cat > "$WORK/slow-nc/nc" <<SHIM
#!/usr/bin/env bash
exec {lines}< <(while IFS= read -r line; do [ "\$line" != OK ] || sleep $1; printf '%s\n' "\$line"; done)
delay_pid=\$!
$(command -v nc) "\$@" <&"\$lines" &
nc_pid=\$!
exec {lines}<&-
trap 'kill "\$nc_pid" "\$delay_pid" 2>/dev/null; exit 143' TERM
wait "\$nc_pid"
SHIM
  chmod +x "$WORK/slow-nc/nc"
}

start_receiver() {
  "$REPO_DIR/transfer_zfs_datasets.sh" receive --port="${1:-$PORT}" --token="$TOKEN" "$DST/copy" > "$WORK/receiver.log" 2>&1 &
  RECEIVER_PID=$!
}

wait_receiver() {
  wait "$RECEIVER_PID" || fail "receiver exited with an error: $(cat "$WORK/receiver.log")"
  RECEIVER_PID=""
}

# Opens fd $up to the receiver on port $1, which may still be re-arming its listener after the
# previous connection.
connect_receiver() {
  local tries=0
  until { exec {up}<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "the receiver on port $1 is not listening"
    sleep 0.2
  done
}

# Sends request $2 to the receiver on port $1 and sets REPLY_LINES to its reply, read up to and
# including a line equal to $3.  A connection made while the receiver's nc for the previous one is
# still exiting lands in that nc's backlog and is reset unanswered, so it is repeated.
request_receiver() {
  local tries=0 line up
  while true; do
    connect_receiver "$1"
    REPLY_LINES=""
    line=""
    # the subshell takes the SIGPIPE of a connection already reset
    if ( echo "$2" >&"$up" ) 2>/dev/null; then
      while IFS= read -r line <&"$up" 2>/dev/null; do
        REPLY_LINES+="$line"$'\n'
        [ "$line" != "$3" ] || break
      done
    fi
    exec {up}>&-
    [ "$line" != "$3" ] || return 0
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || fail "the receiver on port $1 did not answer '$2'"
  done
}

# Ends the receiver on port $1 the way a finished sender does.
end_receiver() {
  request_receiver "$1" "HAFZFS1 $TOKEN END" BYE
  wait_receiver
}

# Ends a stand-in's connection to nc $1.  With $2 = replied, nc first gets to deliver the reply and
# exit once the sender closes its side, as the receiver's _close_nc does: killing it at once can
# truncate the reply.  A request to drop is cut off at once.
end_stand_in_connection() {
  local nc_pid="$1" waited=0
  exec {nc_in}<&- {nc_out}>&-
  while [ "$2" = replied ] && kill -0 "$nc_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$nc_pid" 2>/dev/null || true
  wait "$nc_pid" 2>/dev/null || true
}

# Stands in for the receiver on $PORT: answers one STATE request through the real receiver on
# $HELPER_PORT, then closes the next $1 STREAM or END connections without a reply and stops listening.
flaky_receiver() {
  local drops="$1" answered=0 line nc_in nc_out nc_pid ending
  while [ "$answered" -eq 0 ] || [ "$drops" -gt 0 ]; do
    coproc NC { exec nc -l "$PORT"; }
    # shellcheck disable=SC2153  # set by coproc
    nc_pid=$NC_PID
    exec {nc_in}<&"${NC[0]}" {nc_out}>&"${NC[1]}"
    line=""
    ending=drop
    IFS= read -r line <&"$nc_in" || true
    case $line in
      *" STATE")
        request_receiver "$HELPER_PORT" "$line" END
        printf '%s' "$REPLY_LINES" >&"$nc_out"
        ending=replied
        answered=1
        ;;
      *" STREAM "*|*" END")
        echo "closed without a reply: $line"
        drops=$((drops - 1))
        ;;
    esac
    end_stand_in_connection "$nc_pid" "$ending"
  done
}

# Stands in for the receiver on $PORT: answers STATE requests through the real receiver on
# $HELPER_PORT, takes the first STREAM and discards it, closing without a reply, and stops
# listening after the second STATE request.
swallowing_receiver() {
  local states=0 line nc_in nc_out nc_pid ending
  while [ "$states" -lt 2 ]; do
    coproc NC { exec nc -l "$PORT"; }
    # shellcheck disable=SC2153  # set by coproc
    nc_pid=$NC_PID
    exec {nc_in}<&"${NC[0]}" {nc_out}>&"${NC[1]}"
    line=""
    ending=drop
    IFS= read -r line <&"$nc_in" || true
    case $line in
      *" STATE")
        request_receiver "$HELPER_PORT" "$line" END
        printf '%s' "$REPLY_LINES" >&"$nc_out"
        ending=replied
        states=$((states + 1))
        ;;
      *" STREAM "*)
        echo "swallowed: $line"
        echo GO >&"$nc_out"
        timeout 3 cat <&"$nc_in" > /dev/null || true
        ;;
    esac
    end_stand_in_connection "$nc_pid" "$ending"
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
grep -q "Sender reports all datasets received." "$WORK/receiver.log" || fail "the receiver did not see the end: $(cat "$WORK/receiver.log")"
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

start_receiver "$HELPER_PORT"
until nc -z 127.0.0.1 "$HELPER_PORT"; do sleep 1; done
flaky_receiver 1 > "$WORK/flaky.log" &
FLAKY_PID=$!
started=$SECONDS
send --incremental-from=s1 s2 "tcp://127.0.0.1:$PORT" > "$WORK/lost-bye.log" 2>&1 \
  || fail "send failed when the reply to END was lost: $(cat "$WORK/lost-bye.log")"
[ $((SECONDS - started)) -lt 30 ] || fail "send waited on the lost reply to END"
grep -q "WARNING: the receiver did not confirm the end" "$WORK/lost-bye.log" \
  || fail "the lost reply to END was not reported: $(cat "$WORK/lost-bye.log")"
grep -q "closed without a reply: .* END" "$WORK/flaky.log" || fail "the stand-in did not get END: $(cat "$WORK/flaky.log")"
wait "$FLAKY_PID" || fail "the stand-in receiver failed: $(cat "$WORK/flaky.log")"
FLAKY_PID=""
end_receiver "$HELPER_PORT"
zfs mount "$DST/copy/shared_memory" 2>/dev/null || true
cmp "$DATADIR/shared_memory/shared_memory.bin" "$WORK/mnt/$DST/copy/shared_memory/shared_memory.bin" \
  || fail "shared_memory.bin differs after the incremental receive"
cmp "$DATADIR/blockchain/block_log" "$WORK/mnt/$DST/copy/blockchain/block_log" 2>/dev/null \
  || { zfs mount "$DST/copy/blockchain" && cmp "$DATADIR/blockchain/block_log" "$WORK/mnt/$DST/copy/blockchain/block_log"; } \
  || fail "block_log differs"

./snapshot_zfs_datasets.sh --env-file="$WORK/src.env" --force s3
start_receiver "$HELPER_PORT"
until nc -z 127.0.0.1 "$HELPER_PORT"; do sleep 1; done
swallowing_receiver > "$WORK/swallow.log" &
FLAKY_PID=$!
send --incremental-from=s2 s3 "tcp://127.0.0.1:$PORT" > "$WORK/swallowed.log" 2>&1 \
  && fail "send went on past a dataset that was not received: $(cat "$WORK/swallowed.log")"
grep -q "receiving \. failed: .*does not hold @s3" "$WORK/swallowed.log" \
  || fail "the dataset that was not received was not named: $(cat "$WORK/swallowed.log")"
wait "$FLAKY_PID" || fail "the stand-in receiver failed: $(cat "$WORK/swallow.log")"
FLAKY_PID=""
end_receiver "$HELPER_PORT"
zfs list "$DST/copy@s3" >/dev/null 2>&1 && fail "the swallowed stream reached the target"

# each OK reaches the socket 2s late: the receiver has to let nc deliver it instead of killing it
make_slow_nc 2
PATH="$WORK/slow-nc:$PATH" start_receiver
send --incremental-from=s2 s3 "tcp://127.0.0.1:$PORT" > "$WORK/slow-reply.log" 2>&1 \
  || fail "send failed against a receiver whose nc is slow to reply: $(cat "$WORK/slow-reply.log")"
wait_receiver
grep -q "WARNING" "$WORK/slow-reply.log" && fail "a slow reply was lost: $(cat "$WORK/slow-reply.log")"
grep -q "Sender reports all datasets received." "$WORK/receiver.log" || fail "the receiver did not see the end: $(cat "$WORK/receiver.log")"
for ds in . blockchain shared_memory haf_db_store/pgdata haf_db_store/pgdata/pg_wal logs hivesense/ollama; do
  name="$DST/copy"
  [ "$ds" = . ] || name="$DST/copy/$ds"
  zfs list "$name@s3" >/dev/null || fail "$name@s3 was not received"
done

# nc outlasts the receiver's wait, so every OK is lost and the sender asks the target instead
./snapshot_zfs_datasets.sh --env-file="$WORK/src.env" --force s4
make_slow_nc 30
PATH="$WORK/slow-nc:$PATH" start_receiver
send --incremental-from=s3 s4 "tcp://127.0.0.1:$PORT" > "$WORK/lost-reply.log" 2>&1 \
  || fail "send stopped at a dataset whose reply was lost: $(cat "$WORK/lost-reply.log")"
wait_receiver
streams=$(grep -c " sending .*@s4 " "$WORK/lost-reply.log" || true)
[ "$streams" -gt 0 ] || fail "no streams of s4 were sent: $(cat "$WORK/lost-reply.log")"
[ "$(grep -c "WARNING: the receiver's reply for .* was lost, but the target holds" "$WORK/lost-reply.log")" = "$streams" ] \
  || fail "expected a lost-reply warning for each of the $streams streams: $(cat "$WORK/lost-reply.log")"
zfs list "$DST/copy/haf_db_store/pgdata/pg_wal@s4" >/dev/null || fail "the last dataset of s4 was not received"

######### switch_zfs_datasets.sh on a copy whose haf_db_store has canmount=on #########

COPY_DIR="$WORK/mnt/$DST/copy"
mkdir -p "$WORK/switch-bin"
# renders an empty stack; the boot-check HAF writes to the copy (undone by the rollback) and is healthy
cat > "$WORK/switch-bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *" config "*) echo '{"services": {}}' ;;
  *"boot-check up "*) echo synced > "$COPY_DIR/haf_db_store/pgdata/synced" ;;
  *" ps -q haf") echo 0123456789ab ;;
  "inspect "*Health*) echo healthy ;;
  "inspect "*Status*) echo running ;;
  "inspect "*ExitCode*) echo 0 ;;
esac
EOF
chmod +x "$WORK/switch-bin/docker"
cp "$WORK/src.env" "$WORK/live.env"
cat > "$WORK/copy.env" <<EOF
ZPOOL=$DST
TOP_LEVEL_DATASET=copy
ZPOOL_MOUNT_POINT=$WORK/mnt/$DST
EOF
switch() {
  PATH="$WORK/switch-bin:$PATH" ZPOOL_MOUNT_POINT="$WORK/mnt/$DST" \
    ./switch_zfs_datasets.sh --env-file="$WORK/live.env" --new-env="$WORK/copy.env" "$@"
}
children_visible() {
  [ -e "$COPY_DIR/haf_db_store/pgdata/PG_VERSION" ] || fail "$1: pgdata/PG_VERSION is hidden: $(zfs list -r -o name,canmount,mounted "$DST/copy")"
  [ -z "${2:-}" ] || [ -e "$COPY_DIR/haf_db_store/tablespace/marker" ] || fail "$1: the tablespace's files are hidden"
}
canmount_off() {
  [ "$(zfs get -H -o value canmount "$DST/copy/haf_db_store")" = off ] || fail "$1: haf_db_store has canmount=$(zfs get -H -o value canmount "$DST/copy/haf_db_store")"
}

zfs set canmount=on "$DST/copy/haf_db_store"
switch check > "$WORK/switch-check.log" || fail "check failed on the received copy: $(cat "$WORK/switch-check.log")"
grep -q "WARN  $DST/copy/haf_db_store .*the layout requires canmount=off" "$WORK/switch-check.log" \
  || fail "check did not report haf_db_store's canmount: $(cat "$WORK/switch-check.log")"

switch prepare > "$WORK/switch-prepare.log" || fail "prepare failed: $(cat "$WORK/switch-prepare.log")"
canmount_off "prepare"
children_visible "prepare"
echo data > "$COPY_DIR/haf_db_store/tablespace/marker"

# what a second prepare of the earlier script did: mount haf_db_store over its mounted children
zfs set canmount=on "$DST/copy/haf_db_store"
[ "$(zfs get -H -o value mounted "$DST/copy/haf_db_store")" = yes ] || zfs mount -O "$DST/copy/haf_db_store"
[ ! -e "$COPY_DIR/haf_db_store/pgdata/PG_VERSION" ] || fail "mounting haf_db_store did not cover pgdata"
switch check > "$WORK/switch-check.log" || true
grep -q "WARN  $DST/copy/haf_db_store is mounted, but the layout requires canmount=off" "$WORK/switch-check.log" \
  || fail "check did not warn about the mounted haf_db_store: $(cat "$WORK/switch-check.log")"
switch prepare > "$WORK/switch-prepare.log" || fail "prepare failed with haf_db_store mounted over its children: $(cat "$WORK/switch-prepare.log")"
grep -q "was mounted over its children" "$WORK/switch-prepare.log" || fail "prepare did not uncover the children: $(cat "$WORK/switch-prepare.log")"
canmount_off "prepare over a covering haf_db_store"
children_visible "prepare over a covering haf_db_store" tablespace
[ "$(zfs get -H -o value mounted "$DST/copy/haf_db_store")" = no ] || fail "prepare left haf_db_store mounted"

# haf_db_store mounted before its children holds them: prepare unmounts them first and remounts them
zfs set canmount=on "$DST/copy/haf_db_store"
for ds in pgdata/pg_wal pgdata tablespace; do zfs unmount "$DST/copy/haf_db_store/$ds"; done
for ds in "" /pgdata /pgdata/pg_wal /tablespace; do zfs mount -O "$DST/copy/haf_db_store$ds"; done
children_visible "haf_db_store mounted under its children" tablespace
switch prepare > "$WORK/switch-prepare.log" || fail "prepare failed with haf_db_store mounted under its children: $(cat "$WORK/switch-prepare.log")"
grep -qx "  zfs unmount $DST/copy/haf_db_store" "$WORK/switch-prepare.log" || fail "prepare did not unmount haf_db_store: $(cat "$WORK/switch-prepare.log")"
canmount_off "prepare over a haf_db_store holding its children"
children_visible "prepare over a haf_db_store holding its children" tablespace
[ "$(zfs get -H -o value mounted "$DST/copy/haf_db_store")" = no ] || fail "prepare left haf_db_store mounted"

switch prepare > "$WORK/switch-prepare.log" || fail "a repeated prepare failed: $(cat "$WORK/switch-prepare.log")"
children_visible "a repeated prepare" tablespace

switch boot-check > "$WORK/switch-boot.log" 2>&1 || fail "boot-check failed: $(cat "$WORK/switch-boot.log")"
grep -qF "Boot check passed." "$WORK/switch-boot.log" || fail "boot-check did not pass: $(cat "$WORK/switch-boot.log")"
[ ! -e "$COPY_DIR/haf_db_store/pgdata/synced" ] || fail "boot-check did not roll back what HAF wrote"
canmount_off "boot-check"
children_visible "boot-check" tablespace
switch check > "$WORK/switch-check.log" || fail "check failed after boot-check: $(cat "$WORK/switch-check.log")"
grep -qF "ok    all datasets of the copy are mounted" "$WORK/switch-check.log" || fail "check after boot-check: $(cat "$WORK/switch-check.log")"

switch --force swap > "$WORK/switch-swap.log" 2>&1 || fail "swap refused the boot-checked copy: $(cat "$WORK/switch-swap.log")"
grep -qF "Stack started on $DST/copy" "$WORK/switch-swap.log" || fail "swap did not start the stack: $(cat "$WORK/switch-swap.log")"
children_visible "swap" tablespace

echo "PASS zfs-transfer"
