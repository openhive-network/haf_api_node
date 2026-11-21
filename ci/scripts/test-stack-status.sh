#!/usr/bin/env bash
#
# Test scripts/stack_status.sh's context -> processing container mapping against a stand-in
# docker (a running stack's containers, and a haf psql answering the script's queries).
# Checks: on a hafbe stack without the standalone balance tracker, the hafbe_bal row shows
# block-explorer-block-processing's status; on a standalone balance tracker stack, the
# btracker_app row shows balance-tracker-block-processing's; with both, each shows its own.
# Also checks that the compose files still process the contexts in those services, and that
# a stack running only third-party images still reaches the end of the report.
# No docker needed.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
STACK_DIR=/stack/haf_api_node

fail() {
  echo "FAIL: $*"
  exit 1
}

######### Compose files #########

# The commands of service $2 in compose file $1, one per line.
service_commands() {
  awk -v svc="  $2:" '
    $0 == svc { in_svc = 1; next }
    in_svc && /^  [^ ]/ { exit }
    in_svc && /^    command:/ { in_cmd = 1; next }
    in_svc && in_cmd && /^      - / { sub(/^      - /, ""); print; next }
    in_cmd { in_cmd = 0 }
  ' "$REPO_DIR/$1"
}

service_commands haf_block_explorer.yaml block-explorer-install-balance-tracker | grep -qx -- '--schema=hafbe_bal' ||
  fail "haf_block_explorer.yaml no longer installs hafbe_bal for block-explorer-block-processing"
service_commands haf_block_explorer.yaml block-explorer-block-processing | grep -qx 'process_blocks' ||
  fail "haf_block_explorer.yaml's block-explorer-block-processing no longer runs process_blocks"
service_commands balance_tracker.yaml balance-tracker-block-processing | grep -qx -- '--schema=btracker_app' ||
  fail "balance_tracker.yaml's balance-tracker-block-processing no longer processes btracker_app"
echo "ok    compose files: hafbe_bal in block-explorer-block-processing, btracker_app in balance-tracker-block-processing"

######### Stand-in docker #########

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# $STUB_DIR/containers: the running containers (name|status); $STUB_DIR/contexts: the HAF contexts;
# $STUB_DIR/images: the running containers' images (repo tag|created).
cat > "$WORK/bin/docker" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  ps)
    case "$*" in
      *working_dir=*) head -1 "$STUB_DIR/containers" | cut -d'|' -f1 ;;
      *name=^*)
        args=$*; name=${args#*name=^}; name=${name%%\$*}
        grep "^$name|" "$STUB_DIR/containers" | cut -d'|' -f2 ;;
      *'{{.Names}}|{{.Status}}'*) cat "$STUB_DIR/containers" ;;
      *'{{.Image}}'*) cut -d'|' -f1 "$STUB_DIR/images" ;;
      *'{{.Names}}'*) cut -d'|' -f1 "$STUB_DIR/containers" ;;
    esac ;;
  inspect)
    case "$*" in
      *com.docker.compose.project*) echo haf ;;
      *RepoTags*) cat "$STUB_DIR/images" ;;
      *StartedAt*) echo 2026-11-21T05:00:00Z ;;
    esac ;;
  exec)
    query=${*: -1}
    case "$query" in
      *'FROM hafd.blocks'*) echo '111852600|2026-11-21 09:00:00' ;;
      *consistent_block*) echo 111852590 ;;
      *EXISTS*)
        ctx=${query#*name = \'}; ctx=${ctx%%\'*}
        if grep -qx "$ctx" "$STUB_DIR/contexts"; then echo t; else echo f; fi ;;
      *app_get_current_block_num*) echo 111852537 ;;
    esac ;;
esac
EOF
chmod +x "$WORK/bin/docker"
echo 'registry.hive.blog/haf:0102968a|2026-11-20T00:00:00Z' > "$WORK/images"

# Runs stack_status.sh on the stand-in stack; $1: the running block-processing services.
report() {
  printf 'haf-haf-1|Up 4 hours (healthy)\n' > "$WORK/containers"
  local svc
  for svc in $1; do printf 'haf-%s-1|Up 4 hours (healthy)\n' "$svc" >> "$WORK/containers"; done
  STUB_DIR=$WORK PATH="$WORK/bin:$PATH" "$REPO_DIR/scripts/stack_status.sh" --state "$WORK/state" "$STACK_DIR" > "$WORK/report" 2>&1 ||
    { cat "$WORK/report"; fail "stack_status.sh exited non-zero"; }
  rm -f "$WORK/state"
}

# The report's rows for app context $1.
app_row() {
  awk -v ctx="($1):" '$NF == ctx && /^  [^ ]/ { p = 1; next } p && /^$/ { exit } p' "$WORK/report"
}

# expect_row CONTEXT CONTAINER: the row names CONTAINER and shows it running.
expect_row() {
  local row
  row=$(app_row "$1")
  grep -qx "    Container: $2" <<< "$row" || { cat "$WORK/report"; fail "$1 row does not name $2"; }
  grep -qx "    Status:    Up 4 hours (healthy)" <<< "$row" || { cat "$WORK/report"; fail "$1 row does not show $2 running"; }
  grep -qx "    Block:     111,852,537\|    Block:     111852537" <<< "$row" || { cat "$WORK/report"; fail "$1 row has no block"; }
}

expect_not_installed() {
  [ "$(app_row "$1")" = "    Not installed" ] || { cat "$WORK/report"; fail "$1 row is not 'Not installed'"; }
}

######### hafbe, no standalone balance tracker #########

printf 'hafbe_app\nhafbe_bal\nreptracker_app\n' > "$WORK/contexts"
report "block-explorer-block-processing reputation-tracker-block-processing"
expect_row hafbe_app haf-block-explorer-block-processing-1
expect_row hafbe_bal haf-block-explorer-block-processing-1
expect_row reptracker_app haf-reputation-tracker-block-processing-1
expect_not_installed btracker_app
grep -q "NOT RUNNING" "$WORK/report" && { cat "$WORK/report"; fail "hafbe stack reports a container NOT RUNNING"; }
echo "ok    hafbe: hafbe_bal shows block-explorer-block-processing"

######### standalone balance tracker #########

printf 'btracker_app\n' > "$WORK/contexts"
report "balance-tracker-block-processing"
expect_row btracker_app haf-balance-tracker-block-processing-1
expect_not_installed hafbe_bal
echo "ok    standalone: btracker_app shows balance-tracker-block-processing"

######### both #########

printf 'hafbe_app\nhafbe_bal\nbtracker_app\n' > "$WORK/contexts"
report "block-explorer-block-processing balance-tracker-block-processing"
expect_row hafbe_bal haf-block-explorer-block-processing-1
expect_row btracker_app haf-balance-tracker-block-processing-1
echo "ok    both: each balance tracker context shows its own container"

######### a stopped processing container #########

printf 'hafbe_app\nhafbe_bal\n' > "$WORK/contexts"
report ""
app_row hafbe_bal | grep -qx "    Status:    NOT RUNNING" || { cat "$WORK/report"; fail "a stopped block-explorer-block-processing is not NOT RUNNING"; }
echo "ok    stopped: hafbe_bal shows NOT RUNNING"

######### only third-party images #########

printf 'ankane/pghero:v3.6.1|2026-10-01T00:00:00Z\nvarnish:7.6|2026-10-02T00:00:00Z\n' > "$WORK/images"
printf 'hafbe_app\nhafbe_bal\n' > "$WORK/contexts"
report "block-explorer-block-processing"
grep -qx -- "--- End of report ---" "$WORK/report" || { cat "$WORK/report"; fail "third-party-only stack does not reach the end of the report"; }
grep -q "Version vs develop" "$WORK/report" && { cat "$WORK/report"; fail "third-party-only stack reports a version comparison"; }
echo "ok    third-party images only: the report completes"

echo "PASS stack_status"
