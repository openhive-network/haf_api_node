#!/usr/bin/env bash
#
# Copy a HAF node's datasets to another host, one stream per dataset.
# See "Moving a node's datasets to another host" in README.md for the whole procedure.

set -e -o pipefail

print_help() {
  cat <<EOF
Usage:
  $0 send [options] snapshot-name destination
  $0 receive [--port=N] [--listen-address=addr] [--token=T] pool/dataset

send (on the source host) copies <ZPOOL>/<TOP_LEVEL_DATASET>@snapshot-name, which must have been
taken by snapshot_zfs_datasets.sh, to the destination:
  [user@]host:pool/dataset   over ssh (needs key-based login; remote zfs runs via sudo -n unless
                             the remote user is root; when run under sudo, ssh runs as \$SUDO_USER)
  tcp://host:port            to a 'receive' listener on the target (no ssh keys needed)
Each dataset goes as its own compressed stream, parents first, received unmounted (-u) with the
target's mountpoint inherited.  Datasets that already hold @snapshot-name on the target are skipped,
so re-running after a failure resumes with the first dataset not yet received.

send options:
  --env-file=file            read ZPOOL and TOP_LEVEL_DATASET from this file (default: .env)
  --zpool=pool, --top-level-dataset=dataset
                             name the source datasets directly instead
  --incremental-from=snap    send the changes since 'snap' (already received on the target) and
                             receive them with -F; datasets new since 'snap' are sent in full
  --check                    print the plan (streams, sizes, mount state, target state, space
                             verdict) and exit without sending anything
  --max-capacity=PCT         warn, and refuse to send without --force, if the target pool would end
                             up fuller than PCT percent (default 80)
  --buffer=auto|mbuffer|pv|none
                             buffer the stream on the sending side (auto: mbuffer, else pv)
  --swap-logs-with-dataset=ds
                             the snapshot was taken with this snapshot_zfs_datasets.sh option: send
                             logs and hivesense/ollama from the stand-in dataset's snapshots
  --allow-untagged-snapshot  send a snapshot that snapshot_zfs_datasets.sh did not tag (e.g. one taken
                             before it started tagging); you are vouching that it was taken stopped,
                             unmounted and synced
  --token=T                  (tcp://) the token printed by the receiver
  --connect-timeout=SECONDS  (tcp://) keep retrying the connection this long (default 3600)
  --force, -f                send even if the space check warns

receive (on the target host) listens for 'send ... tcp://' and receives into pool/dataset.  Each
connection is one request; one that closes without a request, or presents the wrong token, is
dropped without touching the pool, so probes or an early sender only cost the sender a retry (a
connection that stays open silently holds the listener until it closes).  It exits after the
sender reports that every dataset arrived.  The stream is not encrypted: use trusted networks only.
  --port=N                   listen port (default 7700)
  --listen-address=addr      listen on this address only
  --token=T                  token the sender must present (default: a random one, printed)
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

######### Helpers that run on the receiving host (locally, or through ssh) #########

# Prints "pool <name> <size> <allocated> <available>", then "have <rel>" for every dataset and snapshot
# under the target, <rel> being the name relative to the target ("." for the target itself).
_target_state() {
  local target="$1" pool="${1%%/*}" name rel
  # shellcheck disable=SC2046
  echo pool "$pool" $(zpool list -H -p -o size,allocated "$pool") $(zfs get -H -p -o value available "$pool")
  zfs list -H -o name -t filesystem,snapshot -r "$target" 2>/dev/null | while read -r name; do
    rel=${name#"$target"}
    case $rel in
      ""|@*) rel=".$rel" ;;
      *) rel=${rel#/} ;;
    esac
    echo "have $rel"
  done
}

# Receives one stream from stdin into <target>/<rel>.  Incremental streams roll the dataset back
# (-F), so refuse them for a dataset something is using: that is a live node, not a copy.
_recv_into() {
  local target="$1" rel="$2" kind="$3" ds="$1" mountpoint
  [ "$rel" = . ] || ds="$target/$rel"
  case $kind in
    full)
      zfs recv -u -x mountpoint "$ds"
      ;;
    incremental)
      if [ "$(zfs get -H -o value mounted "$ds")" = yes ]; then
        mountpoint=$(zfs get -H -o value mountpoint "$ds")
        if lsof -w +f -- "$mountpoint" >/dev/null 2>&1; then
          echo "$ds is mounted and in use; refusing to roll it back for an incremental receive" >&2
          return 3
        fi
      fi
      zfs recv -u -F -x mountpoint "$ds"
      ;;
    *)
      echo "unknown stream kind $kind" >&2
      return 2
      ;;
  esac
}

_valid_rel() {
  [ "$1" = . ] && return 0
  [[ "$1" =~ ^[A-Za-z0-9_.:-]+(/[A-Za-z0-9_.:-]+)*$ ]] || return 1
  case "/$1/" in */../*|*/./*) return 1 ;; esac
}

_valid_dataset() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]+(/[A-Za-z0-9_.:-]+)*$ ]]
}

human() {
  numfmt --to=iec-i --suffix=B "$1"
}

######### receive #########

receive_main() {
  local target="$1" token="$TOKEN" line magic peer_token cmd rel kind nc_in nc_out nc_pid
  [ -n "$target" ] || die "no target dataset given"
  _valid_dataset "$target" || die "invalid dataset name $target"
  zpool list "${target%%/*}" >/dev/null || die "pool ${target%%/*} does not exist"
  command -v nc >/dev/null || die "receive needs nc (netcat)"
  [ -n "$token" ] || token=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')

  echo "Receiving into $target on port $PORT${LISTEN_ADDRESS:+ (address $LISTEN_ADDRESS)}."
  echo "On the source host run:"
  echo "  sudo ./transfer_zfs_datasets.sh send --token=$token snapshot-name tcp://$(hostname -f):$PORT"

  # a sender that goes away mid-request must not kill the listener
  trap '' PIPE
  while true; do
    if [ -n "$LISTEN_ADDRESS" ]; then
      coproc NC { exec nc -l "$LISTEN_ADDRESS" "$PORT"; }
    else
      coproc NC { exec nc -l "$PORT"; }
    fi
    # shellcheck disable=SC2153  # set by coproc
    nc_pid=$NC_PID
    exec {nc_in}<&"${NC[0]}" {nc_out}>&"${NC[1]}"

    line=""
    IFS= read -r line <&"$nc_in" || true
    read -r magic peer_token cmd rel kind <<< "$line" || true
    if [ "$magic" != HAFZFS1 ] || [ "$peer_token" != "$token" ]; then
      [ -z "$line" ] || echo "$(date -u +%FT%TZ) ignored a connection without a valid header"
    else
      case $cmd in
        STATE)
          { _target_state "$target"; echo END; } >&"$nc_out" || true
          ;;
        STREAM)
          if ! _valid_rel "$rel"; then
            echo "ERR invalid dataset $rel" >&"$nc_out" || true
          else
            echo "$(date -u +%FT%TZ) receiving $kind stream for $rel"
            echo GO >&"$nc_out" || true
            if _recv_into "$target" "$rel" "$kind" <&"$nc_in"; then
              echo "$(date -u +%FT%TZ)   done"
              echo OK >&"$nc_out" || true
            else
              echo "$(date -u +%FT%TZ)   FAILED; waiting for the sender to retry"
              echo "ERR receive failed on the target, see its output" >&"$nc_out" || true
            fi
          fi
          ;;
        END)
          echo BYE >&"$nc_out" || true
          exec {nc_in}<&- {nc_out}>&-
          wait "$nc_pid" 2>/dev/null || true
          echo "Sender reports all datasets received."
          zfs list -r -o name,used,mounted,mountpoint "$target"
          return 0
          ;;
        *)
          echo "ERR unknown request" >&"$nc_out" || true
          ;;
      esac
    fi
    exec {nc_in}<&- {nc_out}>&-
    kill "$nc_pid" 2>/dev/null || true
    wait "$nc_pid" 2>/dev/null || true
  done
}

######### send #########

# One request over tcp:// on fd 3.  Retries the connection, so a receiver that is not
# listening yet (or is busy dropping a probe) only delays us.
_tcp_open() {
  local deadline=$((SECONDS + CONNECT_TIMEOUT))
  until { exec 3<>"/dev/tcp/$TCP_HOST/$TCP_PORT"; } 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || die "could not connect to $TCP_HOST:$TCP_PORT within ${CONNECT_TIMEOUT}s"
    sleep 5
  done
  printf 'HAFZFS1 %s %s\n' "$TOKEN" "$*" >&3
}

_tcp_close() {
  exec 3>&-
}

# Command string that runs one of the receiving-side helpers on the ssh destination.
_remote() {
  local fn="$1" script
  shift
  script="$(declare -f "$fn"); $fn$(printf ' %q' "$@")"
  printf '%s bash -c %q' "$REMOTE_SUDO" "$script"
}

_ssh() {
  if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
    sudo -u "$SUDO_USER" -H ssh -o BatchMode=yes "$@"
  else
    ssh -o BatchMode=yes "$@"
  fi
}

fetch_target_state() {
  local line
  if [ -n "$SSH_HOST" ]; then
    _ssh "$SSH_HOST" "$(_remote _target_state "$TARGET")"
  else
    _tcp_open STATE
    while IFS= read -r line <&3; do
      [ "$line" = END ] && break
      echo "$line"
    done
    _tcp_close
  fi
}

_buffer() {
  local size="$1"
  case $BUFFER in
    mbuffer) mbuffer -q -s 128k -m 1G ;;
    pv) pv -s "$size" ;;
    *) cat ;;
  esac
}

send_one() {
  local rel="$1" kind="$2" from="$3" snapshot="$4" size="$5" reply
  local -a send_cmd=(zfs send -L -e -c -p)
  [ "$kind" = incremental ] && send_cmd+=(-i "@$from")
  send_cmd+=("$snapshot")

  if [ -n "$SSH_HOST" ]; then
    "${send_cmd[@]}" | _buffer "$size" | _ssh "$SSH_HOST" "$(_remote _recv_into "$TARGET" "$rel" "$kind")"
  else
    _tcp_open STREAM "$rel" "$kind"
    IFS= read -r reply <&3 || reply="ERR connection closed"
    [ "$reply" = GO ] || { _tcp_close; die "receiver refused $rel: $reply"; }
    "${send_cmd[@]}" | _buffer "$size" >&3
    IFS= read -r reply <&3 || reply="ERR connection closed before the receiver confirmed"
    _tcp_close
    [ "$reply" = OK ] || die "receiving $rel failed: $reply"
  fi
}

send_main() {
  local snapshot_name="$1" destination="$2"
  local source_top state pool_name pool_size pool_alloc pool_avail rel ds snap from kind size note origin
  local total=0 count=0 errors=0 after_cap verdict entry
  local -a sources=() plan=()

  [ -n "$snapshot_name" ] || die "no snapshot name given"
  [ -n "$destination" ] || die "no destination given"
  case $destination in
    tcp://*:*)
      TCP_HOST=${destination#tcp://}
      TCP_PORT=${TCP_HOST##*:}
      TCP_HOST=${TCP_HOST%:*}
      [ -n "$TOKEN" ] || die "tcp:// needs the --token printed by the receiver"
      ;;
    *:*)
      SSH_HOST=${destination%%:*}
      TARGET=${destination#*:}
      _valid_dataset "$TARGET" || die "invalid target dataset $TARGET"
      ;;
    *)
      die "destination must be [user@]host:pool/dataset or tcp://host:port"
      ;;
  esac

  if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
    if [ -n "$ENV_FILE" ]; then
      echo "reading $ENV_FILE"
      # shellcheck disable=SC1090
      . "$ENV_FILE"
    elif [ -f .env ]; then
      echo "reading configuration from .env"
      # shellcheck disable=SC1091
      . ./.env
    else
      die "provide --env-file or both --zpool and --top-level-dataset"
    fi
  fi
  if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
    die "the environment file must define ZPOOL and TOP_LEVEL_DATASET"
  fi
  [ "$(id -u)" -eq 0 ] || die "this script must be run as root"
  source_top="$ZPOOL/$TOP_LEVEL_DATASET"
  zfs list "$source_top@$snapshot_name" >/dev/null 2>&1 || die "$source_top@$snapshot_name does not exist"

  case $BUFFER in
    auto)
      if command -v mbuffer >/dev/null; then BUFFER=mbuffer
      elif command -v pv >/dev/null; then BUFFER=pv
      else BUFFER=none
      fi
      ;;
    mbuffer|pv) command -v "$BUFFER" >/dev/null || die "$BUFFER is not installed" ;;
    none) ;;
    *) die "unknown --buffer=$BUFFER" ;;
  esac

  # Everything that can be wrong on the source is checked before the target is contacted.
  while read -r ds; do
    rel=${ds#"$source_top"}
    rel=${rel#/}
    rel=${rel:-.}
    snap="$ds@$snapshot_name"
    if [ -n "$SWAP_LOGS_DATASET" ]; then
      case $rel in
        logs|hivesense/ollama) snap="$SWAP_LOGS_DATASET/$rel@$snapshot_name" ;;
      esac
    fi
    if ! zfs list "$snap" >/dev/null 2>&1; then
      echo "ERROR: $snap does not exist" >&2
      errors=$((errors + 1))
    elif [ "$(zfs get -H -o value haf_api_node:taken_by "$snap")" != snapshot_zfs_datasets.sh ] && [ "$ALLOW_UNTAGGED" -eq 0 ]; then
      echo "ERROR: $snap was not taken by snapshot_zfs_datasets.sh, so shared_memory.bin may be stale" >&2
      errors=$((errors + 1))
    fi
    note=""
    if [ "$(zfs get -H -o value canmount "$ds")" = on ] && [ "$(zfs get -H -o value mounted "$ds")" != yes ]; then
      note="unmounted on the source;"
    fi
    origin=$(zfs get -H -o value origin "$ds")
    case $origin in
      -|"$source_top"/*) ;;
      *) note="$note clone of $origin (its stream does not need the origin);" ;;
    esac
    sources+=("$rel"$'\t'"$snap"$'\t'"$note")
  done < <(zfs list -r -H -o name -t filesystem "$source_top")
  [ "$errors" -eq 0 ] || die "$errors source snapshot(s) cannot be sent; take a new one with snapshot_zfs_datasets.sh"

  if [ -n "$SSH_HOST" ]; then
    REMOTE_SUDO=""
    [ "$(_ssh "$SSH_HOST" id -u)" = 0 ] || REMOTE_SUDO="sudo -n"
  fi
  state=$(fetch_target_state)
  read -r _ pool_name pool_size pool_alloc pool_avail <<< "$(grep '^pool ' <<< "$state")"
  [ -n "$pool_avail" ] || die "could not read the target pool's state"
  _target_has() { grep -qxF "have $1" <<< "$state"; }

  echo ""
  echo "Source: $source_top@$snapshot_name${INCREMENTAL_FROM:+ (incremental from @$INCREMENTAL_FROM)}"
  echo "Target: ${SSH_HOST:+$SSH_HOST:$TARGET}${TCP_HOST:+receiver at $TCP_HOST:$TCP_PORT}"
  echo ""
  printf '%-36s %-12s %10s  %s\n' DATASET STREAM SIZE NOTES
  for entry in "${sources[@]}"; do
    IFS=$'\t' read -r rel snap note <<< "$entry"
    from=""
    if _target_has "$rel@$snapshot_name"; then
      kind=skip
    elif [ -n "$INCREMENTAL_FROM" ] && _target_has "$rel@$INCREMENTAL_FROM"; then
      kind=incremental
      from=$INCREMENTAL_FROM
      if ! zfs list "${snap%@*}@$from" >/dev/null 2>&1; then
        printf '%-36s %-12s %10s  %s\n' "$rel" "-" "-" "ERROR: target has @$from but the source does not"
        errors=$((errors + 1))
        continue
      fi
    elif _target_has "$rel"; then
      printf '%-36s %-12s %10s  %s\n' "$rel" "-" "-" \
        "ERROR: exists on the target without @$snapshot_name${INCREMENTAL_FROM:+ or @$INCREMENTAL_FROM}"
      errors=$((errors + 1))
      continue
    else
      kind=full
    fi

    size=0
    if [ "$kind" != skip ]; then
      size=$(zfs send -n -P -L -e -c -p ${from:+-i "@$from"} "$snap" | awk '$1 == "size" { print $2 }')
      total=$((total + size))
      count=$((count + 1))
    else
      note="$note already received;"
    fi
    printf '%-36s %-12s %10s  %s\n' "$rel" "$kind" "$(human "$size")" "$note"
    plan+=("$rel $kind ${from:--} $snap $size")
  done

  after_cap=$(( (pool_alloc + total) * 100 / pool_size ))
  echo ""
  echo "To send: $count stream(s), $(human "$total") (compressed stream size, about what it occupies on disk)"
  echo "Target pool $pool_name: $(human "$pool_avail") available," \
    "$(( pool_alloc * 100 / pool_size ))% full now, about ${after_cap}% after the copy"
  if [ "$total" -ge "$pool_avail" ]; then
    verdict=fail
    echo "SPACE: FAIL - the copy does not fit alongside the data already on the target pool."
    echo "  Free space first.  Destroying the target's old dataset makes room but removes the rollback path,"
    echo "  so prefer another pool, or accept that a failed switch can only be fixed by re-copying."
  elif [ "$after_cap" -gt "$MAX_CAPACITY" ]; then
    verdict=warn
    echo "SPACE: WARNING - the copy fits alongside the live data, but leaves the pool ${after_cap}% full"
    echo "  (above $MAX_CAPACITY%); ZFS slows down noticeably past 80-90%.  Plan to destroy the old dataset"
    echo "  soon after the switch.  Pass --force to send anyway."
  else
    verdict=ok
    echo "SPACE: OK - the copy fits alongside the live data."
  fi

  [ "$errors" -eq 0 ] || die "$errors dataset(s) cannot be sent, see above"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    echo "--check: nothing sent."
    return 0
  fi
  [ "$verdict" != fail ] || die "not enough space on the target"
  [ "$verdict" != warn ] || [ "$FORCE" -eq 1 ] || die "space warning; re-run with --force to send anyway"

  for entry in "${plan[@]}"; do
    read -r rel kind from snap size <<< "$entry"
    [ "$kind" != skip ] || continue
    echo ""
    echo "$(date -u +%FT%TZ) sending $snap ($kind, $(human "$size"))"
    send_one "$rel" "$kind" "$from" "$snap" "$size"
  done

  if [ -n "$TCP_HOST" ]; then
    _tcp_open END
    IFS= read -r _ <&3 || true
    _tcp_close
  fi
  echo ""
  echo "$(date -u +%FT%TZ) all datasets of @$snapshot_name are on the target (received unmounted)."
}

######### main #########

if ! OPTIONS=$(getopt -o he:f --long help,env-file:,zpool:,top-level-dataset:,incremental-from:,check,max-capacity:,buffer:,swap-logs-with-dataset:,allow-untagged-snapshot,token:,connect-timeout:,force,port:,listen-address: -n "$0" -- "$@"); then
  print_help
  exit 1
fi

ENV_FILE=""
ZPOOL=""
TOP_LEVEL_DATASET=""
INCREMENTAL_FROM=""
CHECK_ONLY=0
MAX_CAPACITY=80
BUFFER=auto
SWAP_LOGS_DATASET=""
ALLOW_UNTAGGED=0
TOKEN=""
CONNECT_TIMEOUT=3600
FORCE=0
PORT=7700
LISTEN_ADDRESS=""
SSH_HOST=""
TCP_HOST=""
TCP_PORT=""
TARGET=""

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e) ENV_FILE="$2"; shift 2 ;;
    --zpool) ZPOOL="$2"; shift 2 ;;
    --top-level-dataset) TOP_LEVEL_DATASET="$2"; shift 2 ;;
    --incremental-from) INCREMENTAL_FROM="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --max-capacity) MAX_CAPACITY="$2"; shift 2 ;;
    --buffer) BUFFER="$2"; shift 2 ;;
    --swap-logs-with-dataset) SWAP_LOGS_DATASET="$2"; shift 2 ;;
    --allow-untagged-snapshot) ALLOW_UNTAGGED=1; shift ;;
    --token) TOKEN="$2"; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --listen-address) LISTEN_ADDRESS="$2"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    --) shift; break ;;
  esac
done

[[ "$MAX_CAPACITY" =~ ^[0-9]+$ ]] || die "--max-capacity must be a number"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--connect-timeout must be a number"

MODE="$1"
shift || true
case $MODE in
  send) send_main "$@" ;;
  receive)
    [ "$(id -u)" -eq 0 ] || die "this script must be run as root"
    receive_main "$@"
    ;;
  *) print_help; exit 1 ;;
esac
