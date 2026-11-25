#!/usr/bin/env bash
#
# Test scripts/replay_timing_report.sh against a stand-in docker serving captured container
# logs. Checks: mid-replay (HAF in REINDEX, no P2P or LIVE entry yet; apps in MASSIVE
# processing) the report completes and marks P2P and LIVE as not reached yet; with P2P entered
# but not LIVE, only LIVE is not reached; after a finished replay it shows both entries and
# the total replay time.
# Block numbers are matched with or without thousands separators, which fmt_number prints per
# the locale. No docker needed.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)

fail() {
  echo "FAIL: $*"
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/stack" "$WORK/logs"
touch "$WORK/stack/compose.yml"
echo 'PROJECT_NAME=haf' > "$WORK/stack/.env"

# $STUB_DIR/logs/<container>: each container's log; its presence makes the container exist.
cat > "$WORK/bin/docker" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  ps) ls "$STUB_DIR/logs" ;;
  logs) cat "$STUB_DIR/logs/${*: -1}" ;;
  inspect)
    case "$*" in
      *Created*) echo 2026-11-25T03:35:50.123456789Z ;;
      *Health*) echo starting ;;
    esac ;;
esac
EOF
chmod +x "$WORK/bin/docker"

# Captured from steem-20's perf-rebuild stack replaying at block 20.1M (2026-11-25).
cat > "$WORK/haf-replaying" << 'EOF'
shared_buffers = 60GB, from POSTGRESQL_SHARED_BUFFERS_GB
2026-11-25T03:35:57.606774 indexation_state.cpp:564      update_state         ] PROFILE: Entering REINDEX_WAIT sync: 0 s
2026-11-25T03:35:57.608925 indexation_state.cpp:572      update_state         ] PROFILE: Entered REINDEX_WAIT sync: 0 s
2026-11-25T03:35:57.618428 indexation_state.cpp:444      update_state         ] PROFILE: Entering REINDEX sync from start state, dropping constraints: 0 s
2026-11-25T03:35:57.662671 indexation_state.cpp:478      update_state         ] PROFILE: Entered REINDEX sync from start state: 0 s
2026-11-25T04:19:44.921223 block_num_rendezvous_trigger.cpp:52 report_complete_thre ] Dump whole block 20181000
2026-11-25T04:19:45.431420 block_num_rendezvous_trigger.cpp:52 report_complete_thre ] Dump whole block 20182000
EOF
cat > "$WORK/logs/haf-reputation-tracker-block-processing-1" << 'EOF'
2026-11-25T03:36:01.226Z WARNING:  PROFILE: 'reptracker_app' STAGE_CHANGED from 'N/A' to 'MASSIVE_PROCESSING' after N/A block: 1 fork: 2 head block: 954000 head fork: 2
2026-11-25T04:19:42.177Z blocks 17018001..17028000 (10000) processed in 5.11s (0.5 ms/block), 0 iteration(s)
EOF
cat > "$WORK/logs/haf-nft-tracker-block-processing-1" << 'EOF'
2026-11-25T03:36:01.205Z WARNING:  PROFILE: 'nfttracker_app' STAGE_CHANGED from 'N/A' to 'MASSIVE_PROCESSING' after N/A block: 1 fork: 2 head block: 952000 head fork: 2
2026-11-25T04:19:38.086Z NOTICE:  nfttracker processed block range: <20159001, 20167000> successfully in 0.000024 s
EOF
cat > "$WORK/logs/haf-haf-stats-block-processing-1" << 'EOF'
2026-11-25T03:36:01.311Z WARNING:  PROFILE: 'haf_stats' STAGE_CHANGED from 'N/A' to 'MASSIVE_PROCESSING' after N/A block: 1 fork: 2 head block: 956000 head fork: 2
2026-11-25T04:19:40.512Z blocks 19871001..19881000 (10000) processed in 4.87s (0.5 ms/block), 0 iteration(s)
EOF
cat > "$WORK/logs/haf-hivemind-block-processing-1" << 'EOF'
WARNING - hive.db.adapter:60 - [root] WARNING:  PROFILE: 'hivemind_app' STAGE_CHANGED from 'N/A' to 'MASSIVE_WITHOUT_INDEXES' after N/A block: 1 fork: 2 head block: 2284000 head fork: 2
INFO - hive.indexer.sync:197 - Switched to `MASSIVE_WITHOUT_INDEXES` mode | block: 10000 | processing time: 00s
INFO - hive.indexer.sync:690 - Next block range from hive.app_next_iteration is: <15969001:15979000>
EOF

P2P_LINE='2026-11-25T16:10:12.000000 indexation_state.cpp:478      update_state         ] PROFILE: Entered P2P sync from start state: 45255 s 101650000'
LIVE_LINE='2026-11-25T16:20:01.000000 indexation_state.cpp:478      update_state         ] PROFILE: Entered LIVE sync from start state: 45844 s 101659044'

# Runs replay_timing_report.sh on the stand-in stack, HAF's log being $1.
report() {
  cp "$1" "$WORK/logs/haf-haf-1"
  STUB_DIR=$WORK PATH="$WORK/bin:$PATH" "$REPO_DIR/scripts/replay_timing_report.sh" "$WORK/stack" 2>&1 |
    sed 's/\x1b\[[0-9;]*m//g' > "$WORK/report" ||
    { cat "$WORK/report"; fail "replay_timing_report.sh exited non-zero"; }
  grep -q "4. Summary" "$WORK/report" || { cat "$WORK/report"; fail "the report stops before its summary"; }
}

# expect REGEX: some line of the report matches REGEX.
expect() {
  grep -qE -- "$1" "$WORK/report" || { cat "$WORK/report"; fail "no line matches: $1"; }
}

reject() {
  grep -qE -- "$1" "$WORK/report" && { cat "$WORK/report"; fail "a line matches: $1"; }
  return 0
}

######### mid-replay #########

report "$WORK/haf-replaying"
expect '^REINDEX started +2026-11-25T03:35:57 '
expect '^P2P sync entered +not reached yet +[0-9dhms ]+ so far'
expect '^LIVE sync entered +not reached yet +[0-9dhms ]+ so far'
expect '^Total HAF Replay Time: not finished \([0-9dhms ]+ so far\)'
expect '^  Reputation Tracker +N/A .*PROCESSING$'
expect '^  NFT Tracker +N/A .*PROCESSING$'
expect '^  Hivemind .*PROCESSING'
expect '^  HAF +20,?182,?000 +- .*SYNCING'
expect '^  Reputation Tracker +17,?028,?000 +- .*SYNCING'
expect '^  NFT Tracker +20,?167,?000 +- .*SYNCING'
expect '^  HAF Stats +19,?881,?000 +- .*SYNCING'
reject '^  (Reputation|NFT) Tracker .*WAITING'
echo "ok    mid-replay: P2P and LIVE not reached yet, apps processing at their logged blocks"

######### P2P entered, LIVE not yet #########

{ cat "$WORK/haf-replaying"; echo "$P2P_LINE"; } > "$WORK/haf-p2p"
report "$WORK/haf-p2p"
expect '^P2P sync entered +2026-11-25T16:10:12 +12h 34m 15s'
expect '^LIVE sync entered +not reached yet +[0-9dhms ]+ so far'
reject '^P2P sync entered +not reached yet'
echo "ok    P2P entered: only LIVE not reached yet"

######### finished replay #########

# The stage lines of an app that went wait_for_haf -> MASSIVE -> live on an older image.
cat > "$WORK/logs/haf-reputation-tracker-block-processing-1" << 'EOF'
2026-11-25T03:36:01.226Z WARNING:  PROFILE: 'reptracker_app' STAGE_CHANGED from 'wait_for_haf' to 'MASSIVE_PROCESSING' after 12:44:04 block: 1 fork: 2 head block: 101659044 head fork: 2
2026-11-25T18:51:12.226Z WARNING:  PROFILE: 'reptracker_app' STAGE_CHANGED from 'MASSIVE_PROCESSING' to 'live' after 02:31:11 block: 101659500 fork: 2 head block: 101659500 head fork: 2
EOF
{ cat "$WORK/haf-p2p"; echo "$LIVE_LINE"; } > "$WORK/haf-live"
report "$WORK/haf-live"
expect '^P2P sync entered +2026-11-25T16:10:12 +12h 34m 15s'
expect '^LIVE sync entered +2026-11-25T16:20:01 +9m 49s \(P2P→LIVE\)'
expect '^Total HAF Replay Time: 12h 44m 04s$'
expect '^Block at LIVE entry: 101659044$'
reject 'not reached yet|not finished'
expect '^  Reputation Tracker +12:44:04 +02:31:11 +15h 15m 15s +101659500 +LIVE$'
echo "ok    finished: P2P and LIVE entries and the total replay time"

echo "PASS replay_timing_report"
