#!/usr/bin/env bash
#
# Copy a HAF node's datasets to another host, one stream per dataset.
# See "Moving a node's datasets to another host" in README.md for the whole procedure.

set -e -o pipefail

print_help() {
  cat <<EOF
Usage:
  $0 send [options] snapshot-name destination
  $0 receive [--port=N] [--listen-address=addr] [--token=T] [--idle-timeout=S] pool/dataset

send (on the source host) copies <ZPOOL>/<TOP_LEVEL_DATASET>@snapshot-name, which must have been
taken by snapshot_zfs_datasets.sh, to the destination:
  [user@]host:pool/dataset   over ssh (needs key-based login; remote zfs runs via sudo -n unless
                             the remote user is root; when run under sudo, ssh runs as \$SUDO_USER)
  tcp://host:port            to a 'receive' listener on the target (no ssh keys needed)
Each dataset goes as its own compressed stream, parents first, received unmounted (-u) with the
target's mountpoint inherited and resumable (-s).  Datasets that already hold @snapshot-name on the
target are skipped and an interrupted stream resumes from the target's receive_resume_token, so
re-running the same command after a failure continues where it stopped.  The send ends by checking
that every dataset is on the target with @snapshot-name, and exits non-zero naming any that is not.

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
connection starts with a header line carrying the token: a state request, answered with the
target's datasets and resume tokens, or a stream, piped into zfs recv with no reply.  A connection
that closes without a header is dropped and one that presents the wrong token is refused, both
without touching the pool.  The sender learns how each stream went from the next state request,
which it repeats until it gets a whole answer, so probes, an early sender or the listener re-arming
between datasets only cost it a retry (a connection that stays open silently holds the listener
until it closes).  It exits after the sender reports that every dataset arrived; once a stream has
arrived it exits non-zero if the sender stays away for --idle-timeout.  The stream is not
encrypted: use trusted networks only.
  --port=N                   listen port (default 7700)
  --listen-address=addr      listen on this address only
  --token=T                  token the sender must present (default: a random one, printed)
  --idle-timeout=SECONDS     once a stream has arrived, give up (exit 1) when no request comes for
                             this long, and cut a stream that delivers nothing for this long
                             (default 3600; 0 waits forever)
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

######### Helpers that run on the receiving host (locally, or through ssh) #########

# Prints "pool <name> <size> <allocated> <available>", then "have <rel>" for every dataset and snapshot
# under the target, <rel> being the name relative to the target ("." for the target itself), and
# "resume <rel> <token>" for every dataset holding a partial receive that zfs send -t can resume.
_target_state() {
  local target="$1" pool="${1%%/*}" name token rel
  # shellcheck disable=SC2046
  echo pool "$pool" $(zpool list -H -p -o size,allocated "$pool") $(zfs get -H -p -o value available "$pool")
  zfs list -H -o name,receive_resume_token -t filesystem,snapshot -r "$target" 2>/dev/null | while IFS=$'\t' read -r name token; do
    rel=${name#"$target"}
    case $rel in
      ""|@*) rel=".$rel" ;;
      *) rel=${rel#/} ;;
    esac
    echo "have $rel"
    [ "$token" = - ] || echo "resume $rel $token"
  done
}

# Receives one stream from stdin into <target>/<rel>, keeping a partial receive resumable (-s).
# Incremental streams roll the dataset back (-F), so refuse them for a dataset something is using:
# that is a live node, not a copy.  A resumed stream continues a full receive into a dataset that
# has no snapshot yet, and an incremental one otherwise.
_recv_into() {
  local target="$1" rel="$2" kind="$3" ds="$1" mountpoint
  [ "$rel" = . ] || ds="$target/$rel"
  if [ "$kind" = resume ]; then
    kind=full
    [ -z "$(zfs list -H -o name -t snapshot -d 1 "$ds" 2>/dev/null)" ] || kind=incremental
  fi
  case $kind in
    full)
      zfs recv -s -u -x mountpoint "$ds"
      ;;
    incremental)
      if [ "$(zfs get -H -o value mounted "$ds")" = yes ]; then
        mountpoint=$(zfs get -H -o value mountpoint "$ds")
        if lsof -w +f -- "$mountpoint" >/dev/null 2>&1; then
          echo "$ds is mounted and in use; refusing to roll it back for an incremental receive" >&2
          return 3
        fi
      fi
      zfs recv -s -u -F -x mountpoint "$ds"
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

# Ends one listener connection.  Closing nc's stdin lets it copy the last reply to the socket and
# exit once the sender closes its side; killing it at once could drop that reply.  A peer that
# keeps the connection open is cut off after a few seconds so it cannot hold the listener.
_close_nc() {
  local nc_pid="$1" waited=0
  exec {nc_in}<&- {nc_out}>&-
  while kill -0 "$nc_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$nc_pid" 2>/dev/null || true
  wait "$nc_pid" 2>/dev/null || true
}

# Cuts the stream connection of nc $1 once nc has read nothing for --idle-timeout seconds: a sender
# host that vanished without closing the connection would otherwise hold zfs recv forever.  Cutting
# it makes the receive fail with its partial state kept.
_watch_stall() {
  local nc_pid="$1" step=10 idle=0 last="" now
  [ "$IDLE_TIMEOUT" -gt 0 ] || return 0
  [ "$IDLE_TIMEOUT" -ge "$step" ] || step=$IDLE_TIMEOUT
  while sleep "$step"; do
    now=$(awk '$1 == "rchar:" { print $2 }' "/proc/$nc_pid/io" 2>/dev/null) || return 0
    [ -n "$now" ] || return 0
    if [ "$now" != "$last" ]; then
      last=$now
      idle=0
      continue
    fi
    idle=$((idle + step))
    if [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
      echo "$(date -u +%FT%TZ)   nothing arrived for ${idle}s; cutting the connection"
      kill "$nc_pid" 2>/dev/null || true
      return 0
    fi
  done
}

# Pipes the rest of the stream connection on fd $nc_in into zfs recv and sets RESULT to
# "<id> ok" or "<id> failed <zfs recv's first error line>" for the sender's next state request.
_receive_stream() {
  local target="$1" rel="$2" kind="$3" id="$4" nc_pid="$5" ds="$1" err_file watch_pid reason token
  [ "$rel" = . ] || ds="$target/$rel"
  echo "$(date -u +%FT%TZ) receiving $kind stream for $rel"
  err_file=$(mktemp)
  _watch_stall "$nc_pid" &
  watch_pid=$!
  if _recv_into "$target" "$rel" "$kind" <&"$nc_in" 2> "$err_file"; then
    RESULT="$id ok"
    echo "$(date -u +%FT%TZ)   done"
  else
    reason=$(head -n 1 "$err_file")
    RESULT="$id failed ${reason:-zfs recv failed}"
    token=$(zfs get -H -o value receive_resume_token "$ds" 2>/dev/null || true)
    if [ -n "$token" ] && [ "$token" != - ]; then
      echo "$(date -u +%FT%TZ)   the stream ended before $rel was complete: $reason"
      echo "  The partial receive is kept; re-running the same send resumes it."
    else
      echo "$(date -u +%FT%TZ)   FAILED: $reason"
    fi
    if [ "$IDLE_TIMEOUT" -gt 0 ]; then
      echo "  Waiting for the sender to resume (giving up after ${IDLE_TIMEOUT}s without a request)."
    else
      echo "  Waiting for the sender to resume (--idle-timeout=0: waiting forever)."
    fi
  fi
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  rm -f "$err_file"
}

receive_main() {
  local target="$1" token="$TOKEN" line rc magic peer_token cmd rel kind id nc_in nc_out nc_pid
  local -a wait_limit=()
  [ -n "$target" ] || die "no target dataset given"
  _valid_dataset "$target" || die "invalid dataset name $target"
  zpool list "${target%%/*}" >/dev/null || die "pool ${target%%/*} does not exist"
  command -v nc >/dev/null || die "receive needs nc (netcat)"
  [ -n "$token" ] || token=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  RESULT=""

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
    rc=0
    IFS= read -r "${wait_limit[@]}" line <&"$nc_in" || rc=$?
    if [ "$rc" -gt 128 ]; then
      _close_nc "$nc_pid"
      echo "$(date -u +%FT%TZ) no request from the sender for ${IDLE_TIMEOUT}s, and it has not reported the end of the transfer."
      echo "What arrived stays on $target.  To finish, restart this receiver with --token=$token and re-run the same send."
      die "the sender went away before the transfer was complete"
    fi
    read -r magic peer_token cmd rel kind id <<< "$line" || true
    if [ "$magic" = HAFZFS1 ]; then
      echo "$(date -u +%FT%TZ) refused a sender running an older transfer_zfs_datasets.sh"
      echo "ERR the receiver runs a newer transfer_zfs_datasets.sh; update the sender's checkout" >&"$nc_out" || true
    elif [ "$magic" != HAFZFS2 ]; then
      [ -z "$line" ] || echo "$(date -u +%FT%TZ) ignored a connection without a valid header"
    elif [ "$peer_token" != "$token" ]; then
      # the sender stops at this reply, so tell it why it was refused
      echo "$(date -u +%FT%TZ) refused a sender with the wrong token"
      echo "ERR wrong token" >&"$nc_out" || true
    else
      case $cmd in
        STATE)
          { _target_state "$target"; [ -z "$RESULT" ] || echo "result $RESULT"; echo END; } >&"$nc_out" || true
          ;;
        STREAM)
          [ "$IDLE_TIMEOUT" -eq 0 ] || wait_limit=(-t "$IDLE_TIMEOUT")
          if ! [[ "$id" =~ ^[A-Za-z0-9-]+$ ]]; then
            echo "$(date -u +%FT%TZ) ignored a stream without a valid id"
          elif ! _valid_rel "$rel"; then
            RESULT="$id failed invalid dataset name $rel"
          elif [[ ! "$kind" =~ ^(full|incremental|resume)$ ]]; then
            RESULT="$id failed unknown stream kind $kind"
          else
            _receive_stream "$target" "$rel" "$kind" "$id" "$nc_pid"
          fi
          ;;
        END)
          echo BYE >&"$nc_out" || true
          _close_nc "$nc_pid"
          echo "Sender reports all datasets received."
          zfs list -r -o name,used,mounted,mountpoint "$target"
          return 0
          ;;
        *)
          echo "ERR unknown request" >&"$nc_out" || true
          ;;
      esac
    fi
    _close_nc "$nc_pid"
  done
}

######### send #########

# Opens fd 3 to the receiver, retrying a refused connect (a receiver not listening yet, or
# re-arming its listener after a stream) within --connect-timeout.
_tcp_connect() {
  local deadline=$((SECONDS + CONNECT_TIMEOUT))
  until { exec 3<>"/dev/tcp/$TCP_HOST/$TCP_PORT"; } 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || die "could not connect to the receiver at $TCP_HOST:$TCP_PORT within ${CONNECT_TIMEOUT}s"
    sleep 2
  done
}

_tcp_close() {
  exec 3>&-
}

# Prints the tcp receiver's target state.  The request only reads, so any connection that closes,
# resets or stalls before the closing END line is simply asked again, within --connect-timeout.
# Only the receiver's explicit refusal (ERR ...) stops the sender.
_tcp_state() {
  local deadline=$((SECONDS + CONNECT_TIMEOUT)) line reply
  while true; do
    if { exec 3<>"/dev/tcp/$TCP_HOST/$TCP_PORT"; } 2>/dev/null; then
      reply=""
      # the subshell takes the SIGPIPE of a connection already reset
      if ( printf 'HAFZFS2 %s STATE\n' "$TOKEN" >&3 ) 2>/dev/null; then
        while IFS= read -r -t 60 line <&3 2>/dev/null; do
          case $line in
            ERR*) _tcp_close; die "receiver refused the state request: $line" ;;
            END) _tcp_close; printf '%s' "$reply"; return 0 ;;
          esac
          reply+="$line"$'\n'
        done
      fi
      _tcp_close
    fi
    [ "$SECONDS" -lt "$deadline" ] \
      || die "no complete reply to STATE from $TCP_HOST:$TCP_PORT within ${CONNECT_TIMEOUT}s (is it a receiver of this version of transfer_zfs_datasets.sh?)"
    sleep 1
  done
}

# Reports to the receiver that every dataset arrived.  The receiver exits on END, so once END is
# sent nothing is retried: a lost BYE would only be retried against a listener that is gone.  Only
# a refused connect (the listener re-arming after the last state request) is retried, for a short
# bound.  Every dataset is already verified on the target, so a failure here is a warning.
_tcp_end() {
  local deadline=$((SECONDS + 30)) reply=""
  until { exec 3<>"/dev/tcp/$TCP_HOST/$TCP_PORT"; } 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "WARNING: could not reach the receiver at $TCP_HOST:$TCP_PORT to report the end; stop it by hand" >&2
      return 0
    fi
    sleep 1
  done
  if ( printf 'HAFZFS2 %s END\n' "$TOKEN" >&3 ) 2>/dev/null && IFS= read -r -t 30 reply <&3 2>/dev/null \
    && [ "$reply" = BYE ]; then
    _tcp_close
    return 0
  fi
  _tcp_close
  echo "WARNING: the receiver did not confirm the end${reply:+ (it replied: $reply)}; check that it exited" >&2
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
  if [ -n "$SSH_HOST" ]; then
    _ssh "$SSH_HOST" "$(_remote _target_state "$TARGET")"
  else
    _tcp_state
  fi
}

# The resume token that state $1 lists for dataset $2, if any.
_resume_token() {
  awk -v rel="$2" '$1 == "resume" && $2 == rel { print $3 }' <<< "$1"
}

# The snapshot, named as on this host, whose interrupted stream resume token $1 continues.
_token_snapshot() {
  zfs send -n -v -t "$1" 2>/dev/null | awk '$1 == "toname" { print $3; exit }' || true
}

_buffer() {
  local size="$1"
  case $BUFFER in
    mbuffer) mbuffer -q -s 128k -m 1G ;;
    pv) pv -s "$size" ;;
    *) cat ;;
  esac
}

# Pipes one stream to the target and returns the pipe's status.  Over tcp:// the connection carries
# a header line and then only the stream, with no reply: how it went is read from the target's state.
send_one() {
  local rel="$1" kind="$2" from="$3" snapshot="$4" size="$5" resume_token="$6" id="$7" status=0
  local -a send_cmd=(zfs send -L -e -c -p)
  if [ "$kind" = resume ]; then
    send_cmd=(zfs send -t "$resume_token")
  else
    [ "$kind" = incremental ] && send_cmd+=(-i "@$from")
    send_cmd+=("$snapshot")
  fi

  if [ -n "$SSH_HOST" ]; then
    "${send_cmd[@]}" | _buffer "$size" | _ssh "$SSH_HOST" "$(_remote _recv_into "$TARGET" "$rel" "$kind")" || status=$?
  else
    _tcp_connect
    # the subshell takes the SIGPIPE of a connection already reset
    if ( printf 'HAFZFS2 %s STREAM %s %s %s\n' "$TOKEN" "$rel" "$kind" "$id" >&3 ) 2>/dev/null; then
      "${send_cmd[@]}" | _buffer "$size" >&3 || status=$?
    else
      status=1
    fi
    _tcp_close
  fi
  return "$status"
}

# Sends <rel> and returns once the target holds it at <snapshot>, or stops naming it.  A tcp stream
# that the receiver never started receiving (its connection closed or reset before the receiver
# read the header, so the receiver reports no result for it) is sent again within --connect-timeout.
deliver() {
  local rel="$1" kind="$2" from="$3" snap="$4" size="$5" resume_token="$6"
  local deadline=$((SECONDS + CONNECT_TIMEOUT)) id state status reason msg
  while true; do
    id="$(date +%s)-$$-$RANDOM"
    status=0
    send_one "$rel" "$kind" "$from" "$snap" "$size" "$resume_token" "$id" || status=$?
    state=$(fetch_target_state)
    if grep -qxF "have $rel@${snap##*@}" <<< "$state"; then
      return 0
    fi
    if [ -z "$TCP_HOST" ] || grep -q "^result $id " <<< "$state" || [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    echo "$(date -u +%FT%TZ) the stream for $rel did not reach the receiver (the connection closed first); sending it again" >&2
    resume_token=$(_resume_token "$state" "$rel")
    [ -z "$resume_token" ] || kind=resume
    sleep 2
  done

  reason=$(sed -n "s/^result $id failed //p" <<< "$state")
  msg="receiving $rel failed"
  if [ -n "$reason" ]; then
    msg+=" on the target: $reason"
  elif [ -n "$TCP_HOST" ] && ! grep -q "^result $id " <<< "$state"; then
    msg+=": the receiver never started receiving it"
  elif [ "$status" -ne 0 ]; then
    msg+=": the stream exited with status $status"
  fi
  if [ -n "$(_resume_token "$state" "$rel")" ]; then
    msg+="; the target keeps the part that arrived, and re-running the same command (once the cause is fixed) resumes it"
  fi
  die "$msg"
}

send_main() {
  local snapshot_name="$1" destination="$2"
  local source_top state pool_name pool_size pool_alloc pool_avail rel ds snap from kind size note origin
  local resume_token resumed_snap total=0 count=0 errors=0 after_cap verdict entry
  local -a sources=() plan=() missing=()

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
    resume_token=$(_resume_token "$state" "$rel")
    if _target_has "$rel@$snapshot_name"; then
      kind=skip
    elif [ -n "$resume_token" ]; then
      resumed_snap=$(_token_snapshot "$resume_token")
      if [ "$resumed_snap" != "$snap" ]; then
        printf '%-36s %-12s %10s  %s\n' "$rel" "-" "-" \
          "ERROR: the target holds an interrupted receive of ${resumed_snap:-a snapshot this host lacks}; finish it, or discard it there with zfs recv -A"
        errors=$((errors + 1))
        continue
      fi
      kind=resume
      note="$note resumes an interrupted receive;"
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
    if [ "$kind" = resume ]; then
      size=$(zfs send -n -P -t "$resume_token" | awk '$1 == "size" { print $2 }')
    elif [ "$kind" != skip ]; then
      size=$(zfs send -n -P -L -e -c -p ${from:+-i "@$from"} "$snap" | awk '$1 == "size" { print $2 }')
    fi
    if [ "$kind" != skip ]; then
      total=$((total + size))
      count=$((count + 1))
    else
      note="$note already received;"
    fi
    printf '%-36s %-12s %10s  %s\n' "$rel" "$kind" "$(human "$size")" "$note"
    plan+=("$rel $kind ${from:--} $snap $size ${resume_token:--}")
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
    read -r rel kind from snap size resume_token <<< "$entry"
    [ "$kind" != skip ] || continue
    echo ""
    echo "$(date -u +%FT%TZ) sending $snap ($kind, $(human "$size"))"
    deliver "$rel" "$kind" "$from" "$snap" "$size" "$resume_token"
  done

  state=$(fetch_target_state)
  for entry in "${sources[@]}"; do
    rel=${entry%%$'\t'*}
    _target_has "$rel@$snapshot_name" || missing+=("$rel")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    for rel in "${missing[@]}"; do
      echo "MISSING on the target: $rel@$snapshot_name" >&2
    done
    die "${#missing[@]} dataset(s) of @$snapshot_name are not on the target"
  fi

  if [ -n "$TCP_HOST" ]; then
    _tcp_end
  fi
  echo ""
  echo "$(date -u +%FT%TZ) all datasets of @$snapshot_name are on the target (received unmounted)."
}

######### main #########

if ! OPTIONS=$(getopt -o he:f --long help,env-file:,zpool:,top-level-dataset:,incremental-from:,check,max-capacity:,buffer:,swap-logs-with-dataset:,allow-untagged-snapshot,token:,connect-timeout:,force,port:,listen-address:,idle-timeout: -n "$0" -- "$@"); then
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
IDLE_TIMEOUT=3600
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
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    --) shift; break ;;
  esac
done

[[ "$MAX_CAPACITY" =~ ^[0-9]+$ ]] || die "--max-capacity must be a number"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--connect-timeout must be a number"
[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || die "--idle-timeout must be a number"

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
