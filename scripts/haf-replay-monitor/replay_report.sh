#!/usr/bin/env bash
#
# replay_report.sh — Compact replay timing report for a HAF stack.
#
# Parses Docker container logs to extract phase timings for hived and
# each HAF application. For finished apps, shows total replay time.
# For in-progress apps, shows current block and elapsed time.
#
# Usage:
#   ./replay_report.sh <compose-dir>
#   ./replay_report.sh --host <ssh-host> <compose-dir>

HOST=""
COMPOSE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/s/^# \?//p' "$0"; exit 0 ;;
    *) COMPOSE_DIR="$1"; shift ;;
  esac
done

if [[ -z "$COMPOSE_DIR" ]]; then
  echo "Usage: $0 [--host <ssh-host>] <compose-dir>" >&2
  exit 1
fi

# Everything below this marker is the self-contained report that
# runs on the target host. We extract it and pipe it via ssh.
# MARKER:REPORT_START — do not remove

report() {
local COMPOSE_DIR="$1"
local NOW
NOW=$(date +%s)

fmt_duration() {
  local secs=${1%%.*}
  if (( secs < 0 )); then secs=$((-secs)); fi
  if (( secs >= 86400 )); then
    printf "%dd %dh %dm" $((secs/86400)) $((secs%86400/3600)) $((secs%3600/60))
  elif (( secs >= 3600 )); then
    printf "%dh %dm" $((secs/3600)) $((secs%3600/60))
  elif (( secs >= 60 )); then
    printf "%dm %ds" $((secs/60)) $((secs%60))
  else
    printf "%ds" "$secs"
  fi
}

fmt_number() { printf "%'d" "$1" 2>/dev/null || echo "$1"; }

# Find compose project
local PROJECT
PROJECT=$(docker ps --filter "label=com.docker.compose.project.working_dir=$COMPOSE_DIR" --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -n "$PROJECT" ]]; then
  PROJECT=$(docker inspect "$PROJECT" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: No running stack at $COMPOSE_DIR" >&2
  return 1
fi

echo "Replay Report: $(hostname -s) / $PROJECT  ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
echo ""
echo "HAF (hived)"
local HAF="${PROJECT}-haf-1"

# Use persisted hived logs (survive container restarts) — fall back to docker logs
local HAF_DATA_DIR
HAF_DATA_DIR=$(docker inspect "$HAF" --format '{{range .Mounts}}{{if eq .Destination "/home/hived/datadir"}}{{.Source}}{{end}}{{end}}' 2>/dev/null) || true
local HAF_PROFILE=""
if [[ -n "$HAF_DATA_DIR" ]] && [[ -d "$HAF_DATA_DIR/logs/hived/default" ]]; then
  # Grep all rotated log files (sorted by name = chronological)
  HAF_PROFILE=$(grep "PROFILE" "$HAF_DATA_DIR"/logs/hived/default/default.log* 2>/dev/null | sed 's/^[^:]*://' | sort) || true
fi
if [[ -z "$HAF_PROFILE" ]]; then
  # Fallback to docker logs
  HAF_PROFILE=$(docker logs "$HAF" 2>&1 | grep "PROFILE") || true
fi

if [[ -z "$HAF_PROFILE" ]]; then
  echo "  No PROFILE lines found"
else
  # Find the last full replay cycle: last REINDEX entry marks the start
  local last_reindex reindex_ts replay_profile
  last_reindex=$(echo "$HAF_PROFILE" | grep "Entered REINDEX sync from start state" | tail -1) || true
  if [[ -n "$last_reindex" ]]; then
    reindex_ts=$(echo "$last_reindex" | grep -oP '^\S+')
    # Filter to only lines from this replay cycle onwards
    replay_profile=$(echo "$HAF_PROFILE" | sed -n "/$reindex_ts/,\$p")
    printf "  %-30s %s\n" "Replay started:" "$reindex_ts"
  else
    replay_profile="$HAF_PROFILE"
  fi

  local p2p_line live_line entering_live idx_line ts secs block
  # Use first occurrence after REINDEX (the real replay), not restarts
  p2p_line=$(echo "$replay_profile" | grep "Entered P2P sync" | head -1) || true
  live_line=$(echo "$replay_profile" | grep "Entered LIVE sync" | head -1) || true
  entering_live=$(echo "$replay_profile" | grep "Entering LIVE sync" | head -1) || true
  idx_line=$(echo "$replay_profile" | grep "Restored HAF table indexes" | head -1) || true

  if [[ -n "$p2p_line" ]]; then
    ts=$(echo "$p2p_line" | grep -oP '^\S+')
    secs=$(echo "$p2p_line" | grep -oP ': \K\d+(?= s)' | tail -1)
    printf "  %-30s %s (after %s)\n" "P2P sync entered:" "$ts" "$(fmt_duration "${secs:-0}")"
  fi

  if [[ -n "$live_line" ]]; then
    ts=$(echo "$live_line" | grep -oP '^\S+')
    secs=$(echo "$live_line" | grep -oP ': \K\d+(?= s )' | tail -1)
    block=$(echo "$live_line" | grep -oP '\d+$')
    printf "  %-30s %s" "LIVE sync entered:" "$ts"
    if [[ -n "$secs" ]]; then printf " (after %s" "$(fmt_duration "$secs")"; fi
    if [[ -n "$block" ]]; then printf ", block %s" "$(fmt_number "$block")"; fi
    if [[ -n "$secs" ]]; then printf ")"; fi
    echo ""
    if [[ -n "$idx_line" ]]; then
      local idx_secs
      idx_secs=$(echo "$idx_line" | grep -oP '\d+(?=s$)') || true
      printf "  %-30s %s\n" "  Index restore:" "$(fmt_duration "${idx_secs:-0}")"
    fi
  elif [[ -n "$entering_live" ]]; then
    ts=$(echo "$entering_live" | grep -oP '^\S+')
    secs=$(echo "$entering_live" | grep -oP ': \K\d+(?= s)' | tail -1)
    printf "  %-30s %s (after %s) *** BUILDING INDEXES ***\n" "Entering LIVE:" "$ts" "$(fmt_duration "${secs:-0}")"
  else
    echo "  Status: still syncing"
  fi
fi

echo ""
echo "Applications"

container_elapsed() {
  local started
  started=$(docker inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null) || true
  if [[ -n "$started" ]]; then
    local ep
    ep=$(date -d "$started" +%s 2>/dev/null) || true
    if [[ -n "$ep" ]]; then
      fmt_duration $((NOW - ep))
      return
    fi
  fi
  echo "?"
}

# Standard HAF app
report_haf_app() {
  local name=$1 container="${PROJECT}-$2"

  if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
    echo "  $name: stopped"
    return
  fi

  # Get all STAGE_CHANGED lines (apps can bounce between MASSIVE and live)
  local stage_lines range_tail
  stage_lines=$(docker logs "$container" 2>&1 | grep "STAGE_CHANGED") || true
  range_tail=$(docker logs "$container" --tail 100 2>&1 | grep -E "processed block range|Attempting to process a block range" | tail -1) || true
  if [[ -n "$range_tail" ]]; then
    stage_lines="${stage_lines}"$'\n'"${range_tail}"
  fi

  if [[ -z "$stage_lines" ]]; then
    echo "  $name: no data"
    return
  fi

  # LIVE? Use the FIRST transition to live (the initial replay completion),
  # not the last — apps can bounce back to MASSIVE_PROCESSING briefly and
  # re-enter live with a misleadingly short duration.
  local live_line
  live_line=$(echo "$stage_lines" | grep -i "STAGE_CHANGED.*to 'live'" | head -1) || true
  if [[ -n "$live_line" ]]; then
    local dur block_num
    dur=$(echo "$live_line" | grep -oP "after \K[\d:]+" | head -1) || true
    block_num=$(echo "$live_line" | grep -oP "block: \K\d+" | head -1) || true
    echo "  $name: LIVE in ${dur:-?}, block $(fmt_number "${block_num:-0}")"
    return
  fi

  # Replaying
  local cur_block="" range_line
  range_line=$(echo "$stage_lines" | grep -oP 'block range: <\d+, \d+>' | tail -1) || true
  if [[ -n "$range_line" ]]; then
    cur_block=$(echo "$range_line" | grep -oP '\d+>' | tr -dc '0-9')
  fi

  echo "  $name: replaying $(container_elapsed "$container"), block $(fmt_number "${cur_block:-?}")"
}

# Hivemind
report_hivemind() {
  local name=$1 container="${PROJECT}-$2"

  if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
    echo "  $name: stopped"
    return
  fi

  # "Switched to" lines are rare (2-4 total) — scan full log but exit after finding live
  # "Got block" — only need the last one, use --tail
  local switches last_got
  switches=$(docker logs "$container" 2>&1 | grep -m 10 "Switched to") || true
  last_got=$(docker logs "$container" --tail 50 2>&1 | grep "Got block" | tail -1) || true

  # LIVE?
  local live_line
  live_line=$(echo "$switches" | grep 'Switched to `live` mode' | tail -1) || true
  if [[ -n "$live_line" ]]; then
    local dur block_num
    dur=$(echo "$live_line" | grep -oP 'processing time: \K[^|]+' | sed 's/ *$//') || true
    block_num=$(echo "$live_line" | grep -oP 'block: \K\d+' | head -1) || true
    echo "  $name: LIVE in ${dur:-?}, block $(fmt_number "${block_num:-0}")"
    return
  fi

  # Replaying
  local cur_block="" rate=""
  if [[ -n "$last_got" ]]; then
    cur_block=$(echo "$last_got" | grep -oP 'Got block \K\d+') || true
    rate=$(echo "$last_got" | grep -oP '\(\K\d+/s') || true
  fi

  echo "  $name: replaying $(container_elapsed "$container"), block $(fmt_number "${cur_block:-?}")${rate:+ ($rate)}"
}

report_hivemind  "Hivemind"           "hivemind-block-processing-1"
report_haf_app   "Block Explorer"     "block-explorer-block-processing-1"
report_haf_app   "Reputation Tracker" "reputation-tracker-block-processing-1"
report_haf_app   "NFT Tracker"        "nft-tracker-block-processing-1"
report_haf_app   "Hivesense Sync"     "hivesense-sync-1"

}
# END_REPORT

# Extract report function, pipe to remote
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

if [[ -n "$HOST" ]]; then
  sed -n '/^report() {/,/^# END_REPORT/p' "$SCRIPT_PATH" | {
    cat
    echo "report '$COMPOSE_DIR'"
  } | ssh -o ConnectTimeout=5 "$HOST" bash
else
  report "$COMPOSE_DIR"
fi
